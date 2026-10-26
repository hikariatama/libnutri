import Foundation
import Testing

@testable import NutritionCore

final class Vault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func read() -> String { lock.withLock { value } }
    func write(_ value: String) { lock.withLock { self.value = value } }
    func delete() { lock.withLock { value = "" } }
}
actor Transport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url!.path == "/oauth/token" {
            return (
                Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":900}"#.utf8),
                200
            )
        }
        if request.url!.path == "/api/v1/changes" {
            return (Data(#"{"cursor":"current","state":null}"#.utf8), 200)
        }
        return (Data(#"{"error":"nutrition_out_of_range"}"#.utf8), 400)
    }
}
@Test func oauthAndMealPayloadPreserveInput() async throws {
    let transport = Transport()
    let vault = Vault()
    let session = CloudSession(vault: vault, transport: transport)
    try await session.authorize(code: "code+exact", verifier: "verifier")
    let api = CloudAPI(session: session, transport: transport)
    let entry = EntryRecord(
        input: "Два яйца", source: .text,
        day: ConsumptionDay(key: "2026-10-11", timeZoneID: "Asia/Ho_Chi_Minh"))
    let input = "  Я съел 100 г / two eggs\n "
    do {
        _ = try await api.analyze(entry, operationID: UUID(), input: input)
        Issue.record("Expected contextual server error")
    } catch { #expect(error as? TrackerError == .nutritionOutOfRange) }
    let sent = await transport.requests
    #expect(sent.count == 2)
    #expect(String(decoding: sent[0].httpBody!, as: UTF8.self).contains("code%2Bexact"))
    #expect(sent[1].url!.host == "libnutri.avx.so")
    #expect(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer access")
    let payload = try JSONSerialization.jsonObject(with: sent[1].httpBody!) as! [String: Any]
    #expect(payload["input"] as? String == input)
    #expect(payload["expectedVersion"] as? Int == 1)
    #expect(payload["model"] == nil)
    #expect(payload["messages"] == nil)
}
@Test func stableDaysAndRounding() {
    let date = Date(timeIntervalSince1970: 0)
    let day = ConsumptionDay(date: date, timeZone: TimeZone(secondsFromGMT: -3600)!)
    #expect(day.key == "1969-12-31")
    var state = DatabaseSnapshot()
    var e = EntryRecord(input: "one", source: .text, day: day)
    e.nutrition = Nutrition(calories: 100.4, protein: 1.23, fiber: 2.34)
    e.phase = .failed
    state.entries = [e, e]
    #expect(state.totals(for: day).calorieLabel == "201")
    #expect(state.totals(for: day).gramLabel(2.46) == "2.5")
}
@MainActor final class Memory: EntryPersistence {
    var value = DatabaseSnapshot()
    func load() throws -> DatabaseSnapshot { value }
    func save(_ snapshot: DatabaseSnapshot) throws { value = snapshot }
}
actor MealService: MealAPI {
    var value: EntryRecord
    var syncFailure: TrackerError?
    func failNextSync(_ error: TrackerError) { syncFailure = error }
    var syncDelay: Duration?
    func delayChanges(_ value: Duration) { syncDelay = value }
    var syncCalls = 0
    var syncResponses: [CloudChanges] = []
    func queueChanges(_ responses: [CloudChanges]) { syncResponses = responses }
    func changes(after: String?) async throws -> CloudChanges {
        syncCalls += 1
        if let error = syncFailure {
            syncFailure = nil
            throw error
        }
        if let syncDelay { try await Task.sleep(for: syncDelay) }
        if !syncResponses.isEmpty { return syncResponses.removeFirst() }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    var started = 0
    var loseFirstResponse: Bool
    var responses: [UUID: OperationResponse] = [:]
    init(_ value: EntryRecord, loseFirstResponse: Bool = false) {
        self.value = value
        self.loseFirstResponse = loseFirstResponse
    }
    func snapshot() async throws -> DatabaseSnapshot {
        var s = DatabaseSnapshot()
        s.entries = [value]
        return s
    }
    func create(_ entry: EntryRecord) async throws -> EntryRecord {
        value = entry
        return value
    }
    func entry(_ id: UUID) async throws -> EntryRecord { value }
    func analyze(_ entry: EntryRecord, operationID: UUID, input: String) async throws
        -> OperationResponse
    {
        started += 1
        var op = AttemptRecord(
            entryID: value.id, kind: .analysis, input: input, model: "server-model")
        op.id = operationID
        op.phase = .failed
        op.errorCategory = "nutrition_out_of_range"
        value.phase = .failed
        value.draftInput = input
        value.activeOperationID = nil
        value.version += 1
        if loseFirstResponse {
            loseFirstResponse = false
            op.phase = .succeeded
            op.errorCategory = nil
            value.originalInput = input
            value.draftInput = nil
            value.nutrition = Nutrition(calories: 250, protein: 10, fiber: 2)
            value.phase = .ready
            responses[operationID] = OperationResponse(operation: op, entry: value)
            throw TrackerError.connection
        }
        let result = OperationResponse(operation: op, entry: value)
        responses[operationID] = result
        return result
    }
    func transcribe(_ entry: EntryRecord, operationID: UUID, audio: Data) async throws
        -> OperationResponse
    { throw TrackerError.noSpeech }
    func retrySave(_ id: UUID) async throws -> OperationResponse { throw TrackerError.notFound }
    func operation(_ id: UUID) async throws -> OperationResponse {
        guard let response = responses[id] else { throw TrackerError.notFound }
        return response
    }
    func cancel(_ id: UUID) async throws {}
    func draft(_ id: UUID, text: String) async throws {}
    func delete(_ entry: EntryRecord) async throws {}
    func deleteAll() async throws {}
}
@Test @MainActor func failedReanalysisKeepsPriorNutritionAndDoubleTapDoesNotDuplicate() async throws
{
    let memory = Memory()
    var e = EntryRecord(input: "old", source: .text, day: ConsumptionDay(date: Date()))
    e.nutrition = Nutrition(calories: 204, protein: 5, fiber: 1)
    memory.value.entries = [e]
    let api = MealService(e)
    let engine = try MealEngine(persistence: memory, api: api)
    try engine.analyze(entryID: e.id, input: "new")
    try engine.analyze(entryID: e.id, input: "new")
    await engine.waitForIdle()
    #expect(await api.started == 1)
    #expect(engine.state.entries.count == 1)
    #expect(engine.state.entries[0].nutrition == e.nutrition)
    #expect(engine.state.entries[0].originalInput == "old")
    #expect(engine.state.entries[0].draftInput == "new")
    #expect(engine.issues[e.id] == .nutritionOutOfRange)
    try engine.analyze(entryID: e.id, input: "new")
    await engine.waitForIdle()
    #expect(await api.started == 2)
}

@Test @MainActor func lostResponseRecoversSameOperationWithoutAnotherCharge() async throws {
    let memory = Memory()
    var e = EntryRecord(input: "old", source: .text, day: ConsumptionDay(date: Date()))
    e.nutrition = Nutrition(calories: 204, protein: 5, fiber: 1)
    memory.value.entries = [e]
    let api = MealService(e, loseFirstResponse: true)
    let engine = try MealEngine(persistence: memory, api: api)
    try engine.analyze(entryID: e.id, input: "new")
    await engine.waitForIdle()
    #expect(engine.issues[e.id] == .connection)
    #expect(engine.state.entries[0].nutrition == e.nutrition)
    try engine.analyze(entryID: e.id, input: "new")
    await engine.waitForIdle()
    #expect(await api.started == 1)
    #expect(engine.state.entries[0].originalInput == "new")
    #expect(engine.state.entries[0].nutrition?.calories == 250)
    #expect(engine.issues[e.id] == nil)
    // A deliberate later reanalysis is a new operation, including identical text.
    try engine.analyze(entryID: e.id, input: "new")
    await engine.waitForIdle()
    #expect(await api.started == 2)
}

@Test @MainActor func longPollingAppliesAddEditDeleteAndKeepsComposer() async throws {
    let memory = Memory()
    memory.value.composer.text = "unfinished local text"
    var entry = EntryRecord(input: "one", source: .text, day: ConsumptionDay(date: Date()))
    entry.nutrition = Nutrition(calories: 100, protein: 5, fiber: 2)
    let api = MealService(entry)
    let engine = try MealEngine(persistence: memory, api: api)
    var added = DatabaseSnapshot()
    added.entries = [entry]
    entry.originalInput = "edited"
    entry.nutrition = Nutrition(calories: 200, protein: 10, fiber: 3)
    entry.version = 2
    var edited = DatabaseSnapshot()
    edited.entries = [entry]
    await api.queueChanges([
        CloudChanges(cursor: "a", state: added), CloudChanges(cursor: "b", state: edited),
        CloudChanges(cursor: "c", state: DatabaseSnapshot()),
    ])
    var received: [DatabaseSnapshot] = []
    engine.onCloudChange = { if let state = $0.state { received.append(state) } }
    engine.startSync()
    engine.startSync()
    for _ in 0..<200 {
        if received.count == 3 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(received.count == 3)
    #expect(received.first?.entries.first?.nutrition?.calories == 100)
    #expect(received.dropFirst().first?.entries.first?.originalInput == "edited")
    #expect(engine.state.entries.isEmpty)
    #expect(memory.value.composer.text == "unfinished local text")
    engine.stopSync()
    let calls = await api.syncCalls
    try await Task.sleep(for: .milliseconds(30))
    #expect(await api.syncCalls == calls)
}

@Test func longPollRequestUsesCursorAndOAuthAndLeavesRoomForServerWait() async throws {
    let transport = Transport()
    let session = CloudSession(vault: Vault(), transport: transport)
    try await session.authorize(code: "code", verifier: "verifier")
    let api = CloudAPI(session: session, transport: transport)
    let cursor = String(repeating: "a", count: 64)
    let response = try await api.changes(after: cursor)
    #expect(response.state == nil)
    let request = await transport.requests.last!
    #expect(request.url?.path == "/api/v1/changes")
    #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            == cursor)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.timeoutInterval > 25)
}

@Test @MainActor func staleLongPollCannotOverwriteLocalWriteAndStoppingPreventsApplication()
    async throws
{
    let memory = Memory()
    let entry = EntryRecord(input: "remote", source: .text, day: ConsumptionDay(date: Date()))
    let api = MealService(entry)
    let engine = try MealEngine(persistence: memory, api: api)
    var remote = DatabaseSnapshot()
    remote.entries = [entry]
    await api.delayChanges(.milliseconds(25))
    await api.queueChanges([
        CloudChanges(cursor: "old", state: remote),
        CloudChanges(cursor: "new", state: DatabaseSnapshot()),
    ])
    var received = 0
    engine.onCloudChange = { _ in received += 1 }
    engine.startSync()
    try await Task.sleep(for: .milliseconds(5))
    try engine.updateComposer("keep this draft")
    for _ in 0..<200 {
        if received == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(received == 1)
    #expect(engine.state.entries.isEmpty)
    #expect(engine.state.composer.text == "keep this draft")
    engine.stopSync()
    await api.queueChanges([CloudChanges(cursor: "late", state: remote)])
    engine.startSync()
    engine.stopSync()
    try await Task.sleep(for: .milliseconds(40))
    #expect(engine.state.entries.isEmpty)
    #expect(received == 1)
}

@Test @MainActor func transientSync404NeverPretendsMealWasDeletedAndRetries() async throws {
    let memory = Memory()
    let entry = EntryRecord(input: "saved", source: .text, day: ConsumptionDay(date: Date()))
    memory.value.entries = [entry]
    let api = MealService(entry)
    let engine = try MealEngine(persistence: memory, api: api)
    await api.failNextSync(.notFound)
    await api.queueChanges([CloudChanges(cursor: "recovered", state: memory.value)])
    var received = false
    engine.onCloudChange = { _ in received = true }
    engine.startSync()
    try await Task.sleep(for: .milliseconds(30))
    #expect(engine.globalIssue == nil)
    #expect(engine.state.entries == [entry])
    for _ in 0..<250 {
        if received { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(received)
    #expect(engine.globalIssue == nil)
    engine.stopSync()
}
