import Foundation

public protocol TokenVault: Sendable {
    func read() throws -> String
    func write(_ value: String) throws
    func delete() throws
}
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
public struct URLTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TrackerError.connection }
        return (data, response.statusCode)
    }
}
public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var expiresAt: Date?
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt
    }
    public init(accessToken: String, refreshToken: String, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}
public actor CloudSession {
    public static let origin = URL(string: "https://libnutri.avx.so")!
    public static let issuer = URL(string: "https://libauth.avx.so")!
    public static let clientID = "nutrition-ios"
    public static let callback = "nutritiontracker://oauth/callback"
    private let vault: any TokenVault
    private let transport: any HTTPTransport
    private var tokens: OAuthTokens?
    private var refreshing: Task<OAuthTokens, any Error>?
    private var generation = UUID()
    public init(vault: any TokenVault, transport: any HTTPTransport = URLTransport()) {
        self.vault = vault
        self.transport = transport
        if let raw = try? vault.read(), let data = raw.data(using: .utf8) {
            tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
        }
    }
    public func operationID() -> UUID { generation }
    public func isCurrent(_ id: UUID) -> Bool { generation == id }
    public var signedIn: Bool { tokens != nil }
    private func exchange(_ fields: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: Self.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            .data(
                using: .utf8)
        let (data, status) = try await transport.send(request)
        guard status == 200 else {
            if status == 400 || status == 401 { throw TrackerError.signedOut }
            throw TrackerError.connection
        }
        var value = try JSONDecoder().decode(OAuthTokens.self, from: data)
        value.expiresAt = Date().addingTimeInterval(TimeInterval(value.expiresIn))
        return value
    }
    private func save(_ value: OAuthTokens) throws {
        try vault.write(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        tokens = value
    }
    public func authorize(code: String, verifier: String) async throws {
        generation = UUID()
        refreshing?.cancel()
        refreshing = nil
        let current = generation
        let value = try await exchange([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": Self.callback,
            "resource": Self.origin.absoluteString,
        ])
        guard current == generation else { throw CancellationError() }
        try save(value)
    }
    public func access(forceRefresh: Bool = false) async throws -> String {
        guard let old = tokens else { throw TrackerError.signedOut }
        if !forceRefresh, (old.expiresAt ?? .distantPast).timeIntervalSinceNow > 45 {
            return old.accessToken
        }
        let current = generation
        let task: Task<OAuthTokens, any Error>
        if let refreshing {
            task = refreshing
        } else {
            task = Task {
                try await self.exchange([
                    "grant_type": "refresh_token", "client_id": Self.clientID,
                    "refresh_token": old.refreshToken, "resource": Self.origin.absoluteString,
                ])
            }
            refreshing = task
        }
        do {
            let value = try await task.value
            guard current == generation else { throw CancellationError() }
            try save(value)
            refreshing = nil
            return value.accessToken
        } catch {
            guard current == generation else { throw CancellationError() }
            refreshing = nil
            if error as? TrackerError == .signedOut {
                tokens = nil
                try? vault.delete()
            }
            throw error
        }
    }
    public func signOut() async throws {
        let old = tokens
        generation = UUID()
        refreshing?.cancel()
        refreshing = nil
        tokens = nil
        try vault.delete()
        if let old {
            var request = URLRequest(url: Self.issuer.appendingPathComponent("oauth/revoke"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "client_id=\(Self.clientID)&token=\(old.refreshToken)".data(
                using: .utf8)
            _ = try? await transport.send(request)
        }
    }
}
public struct CloudSettings: Codable, Sendable {
    public var hasKey: Bool
    public var nutritionModel: String
    public var transcriptionModel: String
}
public struct SpendingReport: Codable, Sendable {
    public var analysis: String
    public var transcription: String
    public var total: String
    public var unknownCount: Int
    public var startedAt: Date
}
public struct OperationResponse: Codable, Sendable {
    public var operation: AttemptRecord
    public var entry: EntryRecord?
}
public struct EntryResponse: Codable, Sendable { public var entry: EntryRecord }
public struct Acknowledgement: Codable, Sendable {}
public struct CloudChanges: Codable, Sendable {
    public var cursor: String
    public var state: DatabaseSnapshot?
    public var settings: CloudSettings?
    public var spending: SpendingReport?
    public init(
        cursor: String, state: DatabaseSnapshot?, settings: CloudSettings? = nil,
        spending: SpendingReport? = nil
    ) {
        self.cursor = cursor
        self.state = state
        self.settings = settings
        self.spending = spending
    }
}
public protocol MealAPI: Sendable {
    func snapshot() async throws -> DatabaseSnapshot
    func changes(after: String?) async throws -> CloudChanges
    func create(_ entry: EntryRecord) async throws -> EntryRecord
    func entry(_ id: UUID) async throws -> EntryRecord
    func analyze(_ entry: EntryRecord, operationID: UUID, input: String) async throws
        -> OperationResponse
    func transcribe(_ entry: EntryRecord, operationID: UUID, audio: Data) async throws
        -> OperationResponse
    func retrySave(_ id: UUID) async throws -> OperationResponse
    func operation(_ id: UUID) async throws -> OperationResponse
    func cancel(_ id: UUID) async throws
    func draft(_ id: UUID, text: String) async throws
    func delete(_ entry: EntryRecord) async throws
    func deleteAll() async throws
}
extension MealAPI {
    public func changes(after: String?) async throws -> CloudChanges {
        throw TrackerError.configuration
    }
}
public struct CloudAPI: MealAPI, Sendable {
    public let session: CloudSession
    private let transport: any HTTPTransport
    public init(session: CloudSession, transport: any HTTPTransport = URLTransport()) {
        self.session = session
        self.transport = transport
    }
    private struct Empty: Encodable {}
    private struct Failure: Decodable { var error: String }
    public func request<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: B
    ) async throws -> T {
        var components = URLComponents(
            url: CloudSession.origin.appendingPathComponent("api/v1/" + path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            request.httpBody = try encoder.encode(body)
        }
        let operation = await session.operationID()
        for attempt in 0...1 {
            request.setValue(
                "Bearer " + (try await session.access(forceRefresh: attempt == 1)),
                forHTTPHeaderField: "Authorization")
            let (data, status) = try await transport.send(request)
            guard await session.isCurrent(operation) else { throw CancellationError() }
            try Task.checkCancellation()
            if status == 401 && attempt == 0 { continue }
            guard (200..<300).contains(status) else {
                throw TrackerError.remote(
                    (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "connection")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(T.self, from: data)
        }
        throw TrackerError.signedOut
    }
    public func profile() async throws -> CloudProfile { try await request("me", body: Empty()) }
    public func snapshot() async throws -> DatabaseSnapshot {
        try await request("state", body: Empty())
    }
    public func changes(after: String?) async throws -> CloudChanges {
        try await request(
            "changes", query: after.map { [URLQueryItem(name: "after", value: $0)] } ?? [],
            body: Empty())
    }
    public func create(_ entry: EntryRecord) async throws -> EntryRecord {
        struct Body: Encodable {
            var id: UUID
            var input: String?
            var inputSource: InputSource
            var day: ConsumptionDay
        }
        let value: EntryResponse = try await request(
            "entries", method: "POST",
            body: Body(
                id: entry.id, input: entry.originalInput.isEmpty ? nil : entry.originalInput,
                inputSource: entry.inputSource, day: entry.day))
        return value.entry
    }
    public func entry(_ id: UUID) async throws -> EntryRecord {
        let value: EntryResponse = try await request("entries/\(id)", body: Empty())
        return value.entry
    }
    public func analyze(_ entry: EntryRecord, operationID: UUID, input: String) async throws
        -> OperationResponse
    {
        struct Body: Encodable {
            var operationID: UUID
            var input: String
            var expectedVersion: Int
        }
        return try await request(
            "entries/\(entry.id)/analyze", method: "POST",
            body: Body(operationID: operationID, input: input, expectedVersion: entry.version))
    }
    public func transcribe(_ entry: EntryRecord, operationID: UUID, audio: Data) async throws
        -> OperationResponse
    {
        struct Body: Encodable {
            var operationID: UUID
            var audio: String
            var expectedVersion: Int
        }
        return try await request(
            "entries/\(entry.id)/transcribe", method: "POST",
            body: Body(
                operationID: operationID, audio: audio.base64EncodedString(),
                expectedVersion: entry.version
            ))
    }
    public func retrySave(_ id: UUID) async throws -> OperationResponse {
        try await request("operations/\(id)/retry-save", method: "POST", body: Empty())
    }
    public func operation(_ id: UUID) async throws -> OperationResponse {
        try await request("operations/\(id)", body: Empty())
    }
    public func cancel(_ id: UUID) async throws {
        let _: Acknowledgement = try await request(
            "operations/\(id)/cancel", method: "POST", body: Empty())
    }
    public func draft(_ id: UUID, text: String) async throws {
        struct Body: Encodable { var text: String }
        let _: EntryResponse = try await request(
            "entries/\(id)/draft", method: "PATCH", body: Body(text: text))
    }
    public func delete(_ entry: EntryRecord) async throws {
        struct Body: Encodable { var expectedVersion: Int }
        let _: Acknowledgement = try await request(
            "entries/\(entry.id)", method: "DELETE", body: Body(expectedVersion: entry.version))
    }
    public func deleteAll() async throws {
        struct Body: Encodable { var confirmation = "DELETE_ALL_DATA" }
        let _: Acknowledgement = try await request("data", method: "DELETE", body: Body())
    }
    public func settings() async throws -> CloudSettings {
        try await request("settings", body: Empty())
    }
    public func settings(key: String?, config: AIConfiguration) async throws -> CloudSettings {
        struct Body: Encodable {
            var apiKey: String?
            var nutritionModel: String
            var transcriptionModel: String
        }
        return try await request(
            "settings", method: "PATCH",
            body: Body(
                apiKey: key, nutritionModel: config.nutritionModel,
                transcriptionModel: config.transcriptionModel))
    }
    public func spending() async throws -> SpendingReport {
        try await request("spending", body: Empty())
    }
    public func importMeals(_ entries: [EntryRecord], spending: SpendLedger, importID: UUID)
        async throws
    {
        struct Body: Encodable {
            var id: UUID
            var entries: [EntryRecord]
            var spending: SpendLedger
        }
        let _: Acknowledgement = try await request(
            "import", method: "POST", body: Body(id: importID, entries: entries, spending: spending)
        )
    }
}

public struct CloudProfile: Codable, Sendable, Equatable {
    public let id: UUID
    public let username: String
    public let legacyImportAllowed: Bool
}
