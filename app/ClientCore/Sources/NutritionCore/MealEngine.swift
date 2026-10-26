import Foundation

@MainActor public protocol EntryPersistence: AnyObject {
    func load() throws -> DatabaseSnapshot
    func save(_ snapshot: DatabaseSnapshot) throws
}

@MainActor public final class MealEngine {
    public private(set) var state: DatabaseSnapshot
    public private(set) var issues: [UUID: TrackerError] = [:]
    public private(set) var waitingUntil: [UUID: Date] = [:]
    public private(set) var globalIssue: TrackerError?
    public var onChange: (() -> Void)?
    public var onCloudChange: ((CloudChanges) -> Void)?
    private var syncTask: Task<Void, Never>?
    private var syncID = UUID()
    private let persistence: any EntryPersistence
    private let api: any MealAPI
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationTasks: [UUID: Task<Void, any Error>] = [:]
    private var draftTasks: [UUID: Task<Void, Never>] = [:]
    private var live: [UUID: UUID] = [:]
    private var operationIDs: [UUID: UUID] = [:]
    private var pendingCache = false
    private var knownRemoteIDs = Set<UUID>()
    private var accountGeneration = UUID()
    private var refreshGeneration = UUID()
    public init(persistence: any EntryPersistence, api: any MealAPI) throws {
        self.persistence = persistence
        self.api = api
        state = try persistence.load()
    }
    private func publish() { onChange?() }
    private func cache() {
        refreshGeneration = UUID()
        do {
            try persistence.save(state)
            pendingCache = false
            globalIssue = nil
        } catch {
            pendingCache = true
            globalIssue = .persistence
        }
        publish()
    }
    private func replace(_ entry: EntryRecord) {
        if let i = state.entries.firstIndex(where: { $0.id == entry.id }) {
            state.entries[i] = entry
        } else {
            state.entries.append(entry)
        }
    }
    private func apply(_ response: OperationResponse) {
        if let e = response.entry { replace(e) }
        if let i = state.attempts.firstIndex(where: { $0.id == response.operation.id }) {
            state.attempts[i] = response.operation
        } else {
            state.attempts.append(response.operation)
        }
        waitingUntil[response.operation.entryID] = response.operation.waitingUntil
        cache()
    }
    public func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        do {
            let remote = try await api.snapshot()
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
            applySnapshot(remote)
        } catch {
            if refreshGeneration == generation {
                globalIssue = TrackerError.normalize(error)
                publish()
            }
        }
    }
    private func applySnapshot(_ remote: DatabaseSnapshot) {
        // The composer belongs to this device; meals belong to the server.
        var composer = state.composer
        let remoteIDs = Set(remote.entries.map(\.id))
        let removed = knownRemoteIDs.subtracting(remoteIDs)
        for id in removed {
            live[id] = nil
            operationIDs[id] = nil
            tasks[id]?.cancel()
            tasks[id] = nil
            draftTasks[id]?.cancel()
            draftTasks[id] = nil
            waitingUntil[id] = nil
            issues[id] = nil
            if composer.entryID == id { composer.entryID = nil }
        }
        knownRemoteIDs.formUnion(remoteIDs)
        let locallyPending = state.entries.filter { e in
            e.id == composer.entryID && !knownRemoteIDs.contains(e.id)
                && !remote.entries.contains(where: { $0.id == e.id }) && e.nutrition == nil
        }
        let drafts = state.entries.filter { draftTasks[$0.id] != nil }
        let localEntries = state.entries
        let localAttempts = state.attempts
        state.entries = remote.entries + locallyPending
        for i in state.entries.indices where live[state.entries[i].id] != nil {
            if let local = localEntries.first(where: { $0.id == state.entries[i].id }) {
                state.entries[i].activeOperationID = operationIDs[local.id]
                state.entries[i].phase = local.phase
                state.entries[i].draftInput = local.draftInput
            }
        }
        state.attempts =
            remote.attempts
            + localAttempts.filter { local in
                !removed.contains(local.entryID) && !remote.attempts.contains { $0.id == local.id }
            }
        state.composer = composer
        for draft in drafts {
            if let i = state.entries.firstIndex(where: { $0.id == draft.id }) {
                state.entries[i].draftInput = draft.draftInput
            }
        }
        cache()
        for entry in state.entries where entry.activeOperationID != nil && tasks[entry.id] == nil {
            resume(entry.id, operationID: entry.activeOperationID!)
        }
    }
    public func startSync() {
        guard syncTask == nil else { return }
        let id = UUID()
        syncID = id
        syncTask = Task { [weak self] in
            var cursor: String?
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.syncID == id else { return }
                let generation = self.refreshGeneration
                do {
                    let change = try await self.api.changes(after: cursor)
                    try Task.checkCancellation()
                    guard self.syncID == id else { return }
                    // A local write or a newer explicit refresh wins over an older response.
                    guard generation == self.refreshGeneration else {
                        cursor = nil
                        continue
                    }
                    cursor = change.cursor
                    failures = 0
                    if let remote = change.state {
                        self.applySnapshot(remote)
                        self.onCloudChange?(change)
                    }
                } catch {
                    if Task.isCancelled || self.syncID != id { return }
                    let issue = TrackerError.normalize(error)
                    if issue == .cancelled {
                        self.syncTask = nil
                        return
                    }
                    if issue == .signedOut {
                        self.globalIssue = issue
                        self.publish()
                        self.syncTask = nil
                        return
                    }
                    // A failed background refresh is not a failed meal operation.
                    // Keep the cache and retry silently instead of flashing composer errors.
                    failures += 1
                    cursor = nil
                    do {
                        try await Task.sleep(
                            for: .seconds(min(30, pow(2, Double(min(failures - 1, 5))))))
                    } catch { return }
                }
            }
        }
    }
    public func stopSync() {
        syncID = UUID()
        syncTask?.cancel()
        syncTask = nil
    }
    public func updateComposer(_ text: String, source: InputSource? = nil) throws {
        state.composer.text = text
        if let source { state.composer.source = source }
        if let id = state.composer.entryID, let i = state.entries.firstIndex(where: { $0.id == id })
        {
            state.entries[i].draftInput = text
        }
        cache()
        if pendingCache { throw TrackerError.persistence }
    }
    public func updateDraft(entryID: UUID, text: String) throws {
        guard !isBusy(entryID), let i = state.entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        if remotePendingSave(entryID) { cancel(entryID) }
        state.entries[i].draftInput = text
        issues[entryID] = nil
        cache()
        draftTasks[entryID]?.cancel()
        draftTasks[entryID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                if let cancellation = self.cancellationTasks[entryID] {
                    try await cancellation.value
                }
                try await self.api.draft(entryID, text: text)
                self.draftTasks[entryID] = nil
            } catch {
                if !Task.isCancelled {
                    self.issues[entryID] = TrackerError.normalize(error)
                    self.publish()
                }
            }
        }
        if pendingCache { throw TrackerError.persistence }
    }
    public func discardDraft(entryID: UUID) throws {
        cancel(entryID)
        draftTasks[entryID]?.cancel()
        draftTasks[entryID] = nil
        if let i = state.entries.firstIndex(where: { $0.id == entryID }) {
            let text = state.entries[i].originalInput
            state.entries[i].draftInput = nil
            Task { try? await api.draft(entryID, text: text) }
        }
        cache()
    }
    @discardableResult private func prepare(day: ConsumptionDay) -> UUID {
        if let id = state.composer.entryID, state.entries.contains(where: { $0.id == id }) {
            return id
        }
        let entry = EntryRecord(input: state.composer.text, source: state.composer.source, day: day)
        state.entries.append(entry)
        state.composer.entryID = entry.id
        cache()
        return entry.id
    }
    public func submit(day: ConsumptionDay) throws {
        guard !state.composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackerError.emptyInput
        }
        let id = prepare(day: day)
        try analyze(entryID: id, input: state.composer.text)
    }
    public func analyze(entryID: UUID, input: String) throws {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackerError.emptyInput
        }
        begin(entryID: entryID, input: input, audio: nil)
    }
    public func transcribe(audio: Data, day: ConsumptionDay) throws {
        if let id = state.composer.entryID, isBusy(id) { return }
        state.composer.source = .voice
        let id = prepare(day: day)
        begin(entryID: id, input: "", audio: audio)
    }
    private func begin(entryID: UUID, input: String, audio: Data?) {
        guard !isBusy(entryID), let old = state.entries.first(where: { $0.id == entryID }) else {
            return
        }
        draftTasks[entryID]?.cancel()
        draftTasks[entryID] = nil
        let kind: AttemptKind = audio == nil ? .analysis : .transcription
        let prior = old.activeOperationID.flatMap { id in state.attempts.first { $0.id == id } }
        let sameIntent =
            prior?.kind == kind && prior?.inputSnapshot == input
            && prior?.errorCategory != "persistence"
        let cancelID = sameIntent ? nil : old.activeOperationID
        let operationID = sameIntent ? old.activeOperationID! : UUID()
        let generation = UUID()
        if !sameIntent {
            var attempt = AttemptRecord(entryID: entryID, kind: kind, input: input, model: "server")
            attempt.id = operationID
            state.attempts.append(attempt)
        }
        live[entryID] = generation
        operationIDs[entryID] = operationID
        issues[entryID] = nil
        if let i = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[i].phase = audio == nil ? .analyzing : .transcribing
            state.entries[i].activeOperationID = operationID
            if audio == nil { state.entries[i].draftInput = input }
        }
        cache()
        tasks[entryID] = Task { [weak self] in
            guard let self else { return }
            do {
                if let cancellation = self.cancellationTasks[entryID] {
                    do {
                        try await cancellation.value
                        self.cancellationTasks[entryID] = nil
                    } catch {
                        self.cancellationTasks[entryID] = nil
                        throw error
                    }
                }
                if let cancelID { try await self.api.cancel(cancelID) }
                var existing: OperationResponse?
                do { existing = try await self.api.operation(operationID) } catch {
                    if TrackerError.normalize(error) != .notFound { throw error }
                }
                if existing == nil {
                    let entry: EntryRecord
                    do { entry = try await self.api.entry(entryID) } catch {
                        if TrackerError.normalize(error) == .notFound {
                            entry = try await self.api.create(old)
                        } else {
                            throw error
                        }
                    }
                    self.knownRemoteIDs.insert(entryID)
                    try Task.checkCancellation()
                    guard self.live[entryID] == generation else { return }
                    if let audio {
                        existing = try await self.api.transcribe(
                            entry, operationID: operationID, audio: audio)
                    } else {
                        existing = try await self.api.analyze(
                            entry, operationID: operationID, input: input)
                    }
                }
                if let existing {
                    try await self.poll(entryID, generation: generation, first: existing)
                }
            } catch {
                if self.live[entryID] == generation {
                    self.issues[entryID] = TrackerError.normalize(error)
                    if let i = self.state.entries.firstIndex(where: { $0.id == entryID }) {
                        self.state.entries[i].phase = .failed
                    }
                    // Keep operationID after transport failure: retry discovers the same server operation.
                    self.cache()
                }
            }
            if self.live[entryID] == generation {
                self.live[entryID] = nil
                self.operationIDs[entryID] = nil
                self.tasks[entryID] = nil
                self.waitingUntil[entryID] = nil
                self.publish()
            }
        }
    }
    private func resume(_ id: UUID, operationID: UUID) {
        let generation = UUID()
        live[id] = generation
        operationIDs[id] = operationID
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.poll(
                    id, generation: generation, first: try await self.api.operation(operationID))
            } catch {
                if self.live[id] == generation { self.issues[id] = TrackerError.normalize(error) }
            }
            if self.live[id] == generation {
                self.live[id] = nil
                self.operationIDs[id] = nil
                self.tasks[id] = nil
                self.publish()
            }
        }
    }
    private func poll(_ id: UUID, generation: UUID, first: OperationResponse) async throws {
        var response = first
        while true {
            try Task.checkCancellation()
            guard live[id] == generation else { return }
            apply(response)
            switch response.operation.phase {
            case .running, .waiting: break
            case .succeeded:
                issues[id] = nil
                if state.composer.entryID == id {
                    if response.operation.kind == .analysis {
                        state.composer = ComposerDraft()
                    } else {
                        state.composer.text =
                            response.operation.transcript ?? response.entry?.draftInput ?? ""
                        state.composer.source = .voice
                    }
                }
                cache()
                return
            case .failed, .interrupted:
                issues[id] = .remote(response.operation.errorCategory ?? "interrupted")
                cache()
                return
            case .cancelled:
                issues[id] = nil
                cache()
                return
            }
            try await Task.sleep(for: .milliseconds(800))
            response = try await api.operation(response.operation.id)
        }
    }
    public func isBusy(_ id: UUID) -> Bool { live[id] != nil }
    private func remotePendingSave(_ id: UUID) -> Bool {
        guard let op = state.entries.first(where: { $0.id == id })?.activeOperationID else {
            return false
        }
        return state.attempts.first(where: { $0.id == op })?.errorCategory == "persistence"
    }
    public func hasPendingSave(_ id: UUID) -> Bool { pendingCache || remotePendingSave(id) }
    public func unsavedTranscript(_ id: UUID) -> String? { nil }
    public func retrySaving(_ id: UUID) throws {
        if pendingCache {
            cache()
            if pendingCache { throw TrackerError.persistence }
            return
        }
        guard !isBusy(id), remotePendingSave(id),
            let op = state.entries.first(where: { $0.id == id })?.activeOperationID
        else { return }
        let generation = UUID()
        live[id] = generation
        operationIDs[id] = op
        issues[id] = nil
        publish()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.poll(
                    id, generation: generation, first: try await self.api.retrySave(op))
            } catch { self.issues[id] = TrackerError.normalize(error) }
            if self.live[id] == generation {
                self.live[id] = nil
                self.operationIDs[id] = nil
                self.tasks[id] = nil
                self.publish()
            }
        }
    }
    public func cancel(_ id: UUID) {
        guard
            let op = operationIDs[id]
                ?? state.entries.first(where: { $0.id == id })?.activeOperationID
        else { return }
        live[id] = nil
        operationIDs[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        waitingUntil[id] = nil
        if let i = state.entries.firstIndex(where: { $0.id == id }) {
            state.entries[i].activeOperationID = nil
            state.entries[i].phase = state.entries[i].nutrition == nil ? .interrupted : .ready
        }
        let api = self.api
        let cancellation = Task { try await api.cancel(op) }
        cancellationTasks[id] = cancellation
        let account = accountGeneration
        Task { [weak self] in
            do { try await cancellation.value } catch {
                guard self?.accountGeneration == account else { return }
                self?.issues[id] = TrackerError.normalize(error)
                self?.publish()
            }
        }
        cache()
    }
    public func delete(_ id: UUID) async throws {
        let account = accountGeneration
        draftTasks[id]?.cancel()
        draftTasks[id] = nil
        let latest = try await api.entry(id)
        guard accountGeneration == account else { throw CancellationError() }
        // Server invalidates the operation atomically before deleting the row.
        do { try await api.delete(latest) } catch {
            if TrackerError.normalize(error) != .notFound { throw error }
        }
        guard accountGeneration == account else { throw CancellationError() }
        live[id] = nil
        operationIDs[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        state.entries.removeAll { $0.id == id }
        state.attempts.removeAll { $0.entryID == id }
        issues[id] = nil
        if state.composer.entryID == id { state.composer = ComposerDraft() }
        cache()
    }
    public func deleteAll() async throws {
        let account = accountGeneration
        let wasSyncing = syncTask != nil
        try await api.deleteAll()
        guard accountGeneration == account else { throw CancellationError() }
        stopLocal()
        state = DatabaseSnapshot()
        issues = [:]
        globalIssue = nil
        cache()
        if wasSyncing { startSync() }
    }
    public func resetAccount() throws {
        stopLocal()
        let empty = DatabaseSnapshot()
        try persistence.save(empty)
        state = empty
        issues = [:]
        globalIssue = nil
        knownRemoteIDs = []
        pendingCache = false
        publish()
    }
    public func stopLocal() {
        accountGeneration = UUID()
        for task in cancellationTasks.values { task.cancel() }
        cancellationTasks = [:]
        stopSync()
        refreshGeneration = UUID()
        for task in tasks.values { task.cancel() }
        for task in draftTasks.values { task.cancel() }
        tasks = [:]
        draftTasks = [:]
        live = [:]
        operationIDs = [:]
        waitingUntil = [:]
    }
    public func waitForIdle() async { for task in tasks.values { await task.value } }
}
