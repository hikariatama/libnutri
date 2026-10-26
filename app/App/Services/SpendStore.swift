import Combine
import Foundation
import NutritionCore

@MainActor final class SpendStore: ObservableObject {
    @Published private(set) var ledger: SpendLedger
    @Published private(set) var errorMessage: String?
    @Published private(set) var report: SpendingReport?
    private var generation = UUID()
    private let url: URL
    init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        url = directory.appendingPathComponent("openrouter-spending.json")
        if FileManager.default.fileExists(atPath: url.path) {
            ledger = try JSONDecoder().decode(SpendLedger.self, from: Data(contentsOf: url))
        } else {
            ledger = SpendLedger()
        }
    }
    func record(_ charge: UsageCharge) {
        ledger.record(charge)
        do {
            try persist()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save spending history. Keep the app open and try again."
        }
    }
    func retrySaving() {
        do {
            try persist()
            errorMessage = nil
        } catch { errorMessage = "Couldn't save spending history. Try again." }
    }
    func reset() throws {
        let empty = SpendLedger()
        try JSONEncoder().encode(empty).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ledger = empty
        errorMessage = nil
    }
    func clearAccount() throws {
        generation = UUID()
        report = nil
        errorMessage = nil
        try reset()
    }
    func refresh(api: CloudAPI) async {
        let current = generation
        do {
            let value = try await api.spending()
            guard current == generation else { return }
            report = value
            errorMessage = nil
        } catch {
            if current == generation { errorMessage = TrackerError.normalize(error).message }
        }
    }
    func apply(_ report: SpendingReport) {
        self.report = report
        errorMessage = nil
    }
    func amount(_ kind: AttemptKind? = nil) -> Decimal {
        guard let report else { return 0 }
        return Decimal(
            string: kind == .analysis
                ? report.analysis : kind == .transcription ? report.transcription : report.total,
            locale: Locale(identifier: "en_US")) ?? 0
    }
    var unknownCount: Int { report?.unknownCount ?? 0 }
    var startedAt: Date { report?.startedAt ?? Date() }
    private func persist() throws {
        try JSONEncoder().encode(ledger).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
