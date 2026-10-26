import Foundation
import NutritionCore
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var snapshot: DatabaseSnapshot
    @Published var selectedDate = MealDay.defaultSelection()
    @Published var configuration = AIConfiguration()
    @Published var showSettings = false
    @Published var composerError: String?
    @Published private(set) var composerText: String
    @Published var microphoneDenied = false
    @Published var recordingFailed = false
    @Published private(set) var recording = false
    @Published private(set) var startingRecording = false
    @Published private(set) var recordingStarted = Date()
    @Published private(set) var revision = 0
    @Published var successPulse = 0
    @Published var errorPulse = 0
    @Published private(set) var audioLevel: Double = 0
    @Published var showTextInput = false
    let engine: MealEngine
    let spending: SpendStore
    let credentials = KeychainStore()
    let session: CloudSession
    let api: CloudAPI
    let oauth = NativeOAuth()
    @Published private(set) var profile: CloudProfile?
    private var accountEpoch = UUID()
    @Published private(set) var signedIn = false
    @Published private(set) var signingIn = false
    @Published var authError: String?
    @Published private(set) var hasServerKey = false
    var needsImport: Bool {
        profile?.legacyImportAllowed == true && !defaults.bool(forKey: "cloudMigrationCompleted")
            && (!legacyEntries.isEmpty || !spending.ledger.charges.isEmpty)
    }
    @Published private(set) var legacyEntries: [EntryRecord] = []
    private let legacyURL: URL
    private let recorder = AudioRecorder()
    private var microphoneTask: Task<Void, Never>?
    private var stoppedForTranscription = false
    private var reportedIssues: [UUID: TrackerError] = [:]
    private var reportedGlobalIssue: TrackerError?
    private var foreground = true
    private let defaults: UserDefaults
    init(repository: any EntryPersistence, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let spending = try SpendStore()
        self.spending = spending
        session = CloudSession(vault: KeychainStore(account: "libnutri-oauth-session-v2"))
        api = CloudAPI(session: session)
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        legacyURL = directory.appendingPathComponent("nutri-local-migration.json")
        if !defaults.bool(forKey: "cloudMigrationPrepared") {
            let old = try repository.load()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(old.entries).write(
                to: legacyURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defaults.set(true, forKey: "cloudMigrationPrepared")
        }
        if !defaults.bool(forKey: "cloudMigrationCompleted"),
            let data = try? Data(contentsOf: legacyURL)
        {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            legacyEntries = (try? decoder.decode([EntryRecord].self, from: data)) ?? []
        }
        engine = try MealEngine(persistence: repository, api: api)
        snapshot = engine.state
        composerText = engine.state.composer.text
        configuration.nutritionModel =
            defaults.string(forKey: "nutritionModel") ?? configuration.nutritionModel
        configuration.transcriptionModel =
            defaults.string(forKey: "transcriptionModel") ?? configuration.transcriptionModel
        configuration.language = .automatic
        AudioRecorder.cleanOrphans()
        engine.onCloudChange = { [weak self] change in
            guard let self else { return }
            if let settings = change.settings {
                self.hasServerKey = settings.hasKey
                self.configuration.nutritionModel = settings.nutritionModel
                self.configuration.transcriptionModel = settings.transcriptionModel
            }
            if let report = change.spending { self.spending.apply(report) }
        }
        engine.onChange = { [weak self] in self?.refresh() }
        recorder.onInterruption = { [weak self] in self?.finishRecording() }
        recorder.onLevel = { [weak self] level in self?.audioLevel = level }
        Task { await reconnect() }
    }
    var day: ConsumptionDay { ConsumptionDay(date: selectedDate) }
    var totals: Nutrition { snapshot.totals(for: day) }
    var entries: [EntryRecord] {
        snapshot.entries.filter { $0.day.key == day.key }.sorted { $0.createdAt > $1.createdAt }
    }
    var composerEntry: EntryRecord? {
        snapshot.entries.first { $0.id == snapshot.composer.entryID }
    }
    var composerBusy: Bool {
        startingRecording || recording || snapshot.composer.entryID.map(engine.isBusy) == true
    }
    var issue: TrackerError? {
        snapshot.composer.entryID.flatMap { engine.issues[$0] } ?? engine.globalIssue
    }
    func entry(_ id: UUID) -> EntryRecord? { snapshot.entries.first { $0.id == id } }
    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        authError = nil
        accountEpoch = UUID()
        let epoch = accountEpoch
        Task {
            defer { signingIn = false }
            do {
                let grant = try await oauth.authorize()
                try await session.authorize(code: grant.code, verifier: grant.verifier)
                guard accountEpoch == epoch else { return }
                await reconnect()
            } catch {
                if error as? NativeOAuth.Failure != .cancelled {
                    authError = "Couldn't sign in. Try again and confirm with your passkey."
                }
            }
        }
    }
    func reconnect() async {
        let epoch = accountEpoch
        guard await session.signedIn else {
            signedIn = false
            return
        }
        do {
            let identity = try await api.profile()
            guard accountEpoch == epoch else { return }
            let cachedID = defaults.string(forKey: "cacheUserID")
            if cachedID != identity.id.uuidString {
                try engine.resetAccount()
                try spending.clearAccount()
                defaults.set(identity.id.uuidString, forKey: "cacheUserID")
            }
            profile = identity
            await engine.refresh()
            guard accountEpoch == epoch else { return }
            if engine.globalIssue == .signedOut {
                signedIn = false
                profile = nil
                return
            }
            await loadCloudSettings()
            guard accountEpoch == epoch else { return }
            await spending.refresh(api: api)
            guard accountEpoch == epoch else { return }
            signedIn = true
            authError = nil
            if foreground { engine.startSync() }
        } catch {
            guard accountEpoch == epoch else { return }
            if TrackerError.normalize(error) == .signedOut {
                signedIn = false
                profile = nil
            }
            authError = TrackerError.normalize(error).message
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active { Task { await reconnect() } } else { engine.stopSync() }
    }
    func loadCloudSettings() async {
        let epoch = accountEpoch
        do {
            let settings = try await api.settings()
            guard accountEpoch == epoch else { return }
            hasServerKey = settings.hasKey
            configuration.nutritionModel = settings.nutritionModel
            configuration.transcriptionModel = settings.transcriptionModel
        } catch { if accountEpoch == epoch { authError = TrackerError.normalize(error).message } }
    }
    func importLocalMeals() async throws {
        guard profile?.legacyImportAllowed == true else { throw TrackerError.permission }
        let id: UUID
        if let value = defaults.string(forKey: "cloudImportID"), let saved = UUID(uuidString: value)
        {
            id = saved
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: "cloudImportID")
        }
        // Stable IDs make migration safe to repeat after a lost response.
        try await api.importMeals(legacyEntries, spending: spending.ledger, importID: id)
        defaults.set(true, forKey: "cloudMigrationCompleted")
        legacyEntries = []
        await engine.refresh()
        await spending.refresh(api: api)
    }
    func signOut() async {
        accountEpoch = UUID()
        signedIn = false
        profile = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        recording = false
        startingRecording = false
        recorder.cleanup()
        showTextInput = false
        showSettings = false
        engine.stopLocal()
        do {
            try engine.resetAccount()
            try spending.clearAccount()
            defaults.removeObject(forKey: "cacheUserID")
            configuration = AIConfiguration()
            hasServerKey = false
            composerError = nil
            composerText = ""
            reportedIssues = [:]
            reportedGlobalIssue = nil
            try await session.signOut()
        } catch { authError = "Couldn't clear this device's session. Try signing out again." }
    }
    func refresh() {
        let old = snapshot
        snapshot = engine.state
        revision += 1
        if snapshot.composer != old.composer { composerText = snapshot.composer.text }
        if let id = snapshot.composer.entryID, let transcript = engine.unsavedTranscript(id) {
            composerText = transcript
        }
        if old.entries != snapshot.entries {
            let changed = snapshot.entries.contains { value in
                value.nutrition != nil
                    && old.entries.first(where: { $0.id == value.id })?.nutrition != value.nutrition
            }
            if changed {
                successPulse += 1
                composerError = nil
            }
        }
        if (engine.issues != reportedIssues && !engine.issues.isEmpty)
            || (engine.globalIssue != reportedGlobalIssue && engine.globalIssue != nil)
        {
            errorPulse += 1
        }
        if engine.issues.values.contains(.signedOut) || engine.globalIssue == .signedOut {
            signedIn = false
        }
        reportedIssues = engine.issues
        reportedGlobalIssue = engine.globalIssue
        if stoppedForTranscription, let id = snapshot.composer.entryID, !engine.isBusy(id) {
            stoppedForTranscription = false
            recorder.cleanup()
            audioLevel = 0
            if engine.issues[id] == nil || engine.hasPendingSave(id) { showTextInput = true }
        }
    }
    func setComposer(_ text: String) {
        composerText = text
        recordingFailed = false
        do {
            try engine.updateComposer(text)
            composerError = nil
        } catch { composerError = TrackerError.persistence.message }
    }
    func submit() {
        composerError = nil
        do {
            if let id = snapshot.composer.entryID, engine.hasPendingSave(id) {
                try engine.retrySaving(id)
            } else {
                try engine.updateComposer(composerText)
                try engine.submit(day: day)
            }
        } catch {
            composerError = TrackerError.normalize(error).message
            errorPulse += 1
        }
    }
    func reanalyze(_ id: UUID, input: String) throws {
        try engine.analyze(entryID: id, input: input)
    }
    func toggleMicrophone() {
        if recording {
            finishRecording()
            return
        }
        guard !composerBusy else { return }
        startingRecording = true
        composerError = nil
        microphoneDenied = false
        recordingFailed = false
        microphoneTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start()
                try Task.checkCancellation()
                self.startingRecording = false
                self.recording = true
                self.recordingStarted = Date()
            } catch {
                self.startingRecording = false
                self.recording = false
                self.recorder.cleanup()
                if Task.isCancelled { return }
                self.recordingFailed = true
                if let audioError = error as? AudioRecorder.AudioError, audioError == .permission {
                    self.microphoneDenied = true
                    self.composerError = "Microphone access is disabled."
                } else {
                    self.composerError = "Couldn't start recording. Try again."
                }
                self.errorPulse += 1
            }
        }
    }
    func finishRecording() {
        guard recording else { return }
        recording = false
        audioLevel = 0
        do {
            let audio = try recorder.stop()
            stoppedForTranscription = true
            try engine.transcribe(audio: audio, day: day)
        } catch {
            stoppedForTranscription = false
            recorder.cleanup()
            recordingFailed = true
            if (error as? AudioRecorder.AudioError) == .silent {
                composerError = TrackerError.noSpeech.message
            } else if error is AudioRecorder.AudioError
                || (error as NSError).domain == NSCocoaErrorDomain
            {
                composerError = "Couldn't read your recording. Try recording again."
            } else {
                composerError = TrackerError.normalize(error).message
            }
            errorPulse += 1
        }
    }
    func cancelComposer() {
        microphoneTask?.cancel()
        microphoneTask = nil
        startingRecording = false
        recording = false
        if let id = snapshot.composer.entryID { engine.cancel(id) }
        stoppedForTranscription = false
        recorder.cleanup()
        audioLevel = 0
    }
    func saveSettings(key: String, config: AIConfiguration) async throws {
        guard !config.nutritionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !config.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TrackerError.configuration }
        let result = try await api.settings(key: key.isEmpty ? nil : key, config: config)
        hasServerKey = result.hasKey
        if !key.isEmpty { try credentials.delete() }
        configuration = config
        configuration.language = .automatic
        defaults.set(config.nutritionModel, forKey: "nutritionModel")
        defaults.set(config.transcriptionModel, forKey: "transcriptionModel")
        defaults.removeObject(forKey: "speechLanguage")
    }
    func deleteAll() async throws {
        cancelComposer()
        try await engine.deleteAll()
        try credentials.delete()
        try? FileManager.default.removeItem(at: legacyURL)
        legacyEntries = []
        defaults.set(true, forKey: "cloudMigrationCompleted")
        hasServerKey = false
        try spending.reset()
        ["nutritionModel", "transcriptionModel", "speechLanguage"].forEach(
            defaults.removeObject(forKey:))
        configuration = AIConfiguration()
        recorder.cleanup()
        AudioRecorder.cleanOrphans()
        composerError = nil
        recordingFailed = false
        microphoneDenied = false
        successPulse += 1
    }
}
