import Foundation
import Testing

@testable import NutritionCore

actor AccountTransport: HTTPTransport {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var requestStarted = false
    private var tokenNumber = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url!.path == "/oauth/token" {
            tokenNumber += 1
            return (
                Data(
                    "{\"access_token\":\"access-\(tokenNumber)\",\"refresh_token\":\"refresh-\(tokenNumber)\",\"expires_in\":900}"
                        .utf8), 200
            )
        }
        if request.url!.path == "/api/v1/state" {
            requestStarted = true
            await withCheckedContinuation { waiting = $0 }
            return (
                Data(
                    #"{"entries":[],"attempts":[],"composer":{"text":"old account draft","source":"text","entryID":null}}"#
                        .utf8), 200
            )
        }
        return (Data("{}".utf8), 200)
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@Test func lateResponseFromSignedOutAccountCannotReachNewAccount() async throws {
    let transport = AccountTransport()
    let session = CloudSession(vault: Vault(), transport: transport)
    try await session.authorize(code: "account-a", verifier: "verifier")
    let api = CloudAPI(session: session, transport: transport)
    let pending = Task { try await api.snapshot() }
    while !(await transport.requestStarted) { await Task.yield() }
    try await session.signOut()
    try await session.authorize(code: "account-b", verifier: "verifier")
    await transport.release()
    do {
        _ = try await pending.value
        Issue.record("An old account response must be rejected")
    } catch { #expect(error is CancellationError) }
    #expect(await session.signedIn)
}

@Test @MainActor func accountResetClearsEntriesDraftsAttemptsAndPersistentCache() throws {
    let memory = Memory()
    let value = EntryRecord(
        input: "Private meal", source: .text,
        day: .init(key: "2026-10-19", timeZoneID: "Asia/Ho_Chi_Minh"))
    memory.value.entries = [value]
    memory.value.composer.text = "Private draft"
    let engine = try MealEngine(persistence: memory, api: MealService(value))
    try engine.resetAccount()
    #expect(engine.state.entries.isEmpty)
    #expect(engine.state.attempts.isEmpty)
    #expect(engine.state.composer.text.isEmpty)
    #expect(memory.value.entries.isEmpty)
    #expect(memory.value.composer.text.isEmpty)
}
