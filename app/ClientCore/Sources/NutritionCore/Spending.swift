import Foundation

public struct UsageCharge: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: AttemptKind
    public var costUSD: Decimal?
    public var date: Date
    public init(id: String, kind: AttemptKind, costUSD: Decimal?, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.costUSD = costUSD
        self.date = date
    }

}

public struct SpendLedger: Codable, Equatable, Sendable {
    public private(set) var charges: [String: UsageCharge] = [:]
    public var startedAt = Date()
    public init() {}
    public mutating func record(_ charge: UsageCharge) {
        // A later receipt can resolve an unknown cost; duplicate receipts never double count.
        if charges[charge.id]?.costUSD != nil { return }
        charges[charge.id] = charge
    }
    public func total(_ kind: AttemptKind? = nil) -> Decimal {
        charges.values.filter { kind == nil || $0.kind == kind }.compactMap(\.costUSD).reduce(0, +)
    }
    public var unknownCount: Int { charges.values.filter { $0.costUSD == nil }.count }
    public static func label(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
