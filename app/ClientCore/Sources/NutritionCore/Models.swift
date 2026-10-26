import Foundation

public struct Nutrition: Codable, Equatable, Sendable {
    public var calories: Double
    public var protein: Double
    public var fiber: Double
    public init(calories: Double, protein: Double, fiber: Double) {
        self.calories = calories
        self.protein = protein
        self.fiber = fiber
    }
    public static let zero = Nutrition(calories: 0, protein: 0, fiber: 0)
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            calories: lhs.calories + rhs.calories, protein: lhs.protein + rhs.protein,
            fiber: lhs.fiber + rhs.fiber)
    }
    public var calorieLabel: String {
        calories.formatted(
            .number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
    }
    public func gramLabel(_ value: Double) -> String {
        value.formatted(
            .number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...1)))
    }
}

public struct ConsumptionDay: Codable, Equatable, Sendable {
    public var key: String
    public var timeZoneID: String
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        timeZoneID = timeZone.identifier
    }
    public init(key: String, timeZoneID: String) {
        self.key = key
        self.timeZoneID = timeZoneID
    }
}

public enum InputSource: String, Codable, Sendable { case text, voice }
public enum EntryPhase: String, Codable, Sendable {
    case pending, transcribing, analyzing, saving, ready, failed, interrupted
}
public enum AttemptKind: String, Codable, Sendable { case transcription, analysis }
public enum AttemptPhase: String, Codable, Sendable {
    case running, waiting, succeeded, failed, cancelled, interrupted
}

public struct EntryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var originalInput: String
    public var draftInput: String?
    public var inputSource: InputSource
    public var nutrition: Nutrition?
    public var day: ConsumptionDay
    public var consumedAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: EntryPhase
    public var activeOperationID: UUID?
    public var version: Int = 1
    public init(
        id: UUID = UUID(), input: String, source: InputSource, day: ConsumptionDay,
        date: Date = Date()
    ) {
        self.id = id
        originalInput = input
        inputSource = source
        nutrition = nil
        self.day = day
        consumedAt = date
        createdAt = date
        updatedAt = date
        phase = .pending
    }
}

public struct AttemptRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var entryID: UUID
    public var kind: AttemptKind
    public var inputSnapshot: String
    public var model: String
    public var requestCount = 0
    public var phase: AttemptPhase = .running
    public var errorCategory: String?
    public var createdAt = Date()
    public var updatedAt = Date()
    public var waitingUntil: Date?
    public var transcript: String?
    public var promptVersion = "nutrition-v1"
    public init(entryID: UUID, kind: AttemptKind, input: String, model: String) {
        self.entryID = entryID
        self.kind = kind
        inputSnapshot = input
        self.model = model
    }
}

public struct ComposerDraft: Codable, Equatable, Sendable {
    public var text = ""
    public var source: InputSource = .text
    public var entryID: UUID?
    public init() {}
}

public struct DatabaseSnapshot: Codable, Equatable, Sendable {
    public var entries: [EntryRecord] = []
    public var attempts: [AttemptRecord] = []
    public var composer = ComposerDraft()
    public init() {}
    public func totals(for day: ConsumptionDay) -> Nutrition {
        entries.filter { $0.day.key == day.key }.compactMap(\.nutrition).reduce(.zero, +)
    }
}

public enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case automatic, russian, english
    public var code: String? {
        switch self {
        case .automatic: nil
        case .russian: "ru"
        case .english: "en"
        }
    }
    public var label: String { rawValue.capitalized }
}

public struct AIConfiguration: Sendable, Equatable {
    public var transcriptionModel = "openai/whisper-large-v3-turbo"
    public var nutritionModel = "google/gemini-2.5-flash-lite"
    public var language: SpeechLanguage = .automatic
    public var timeout: TimeInterval = 75
    public var calorieLimit: Double = 3000
    public var proteinLimit: Double = 150
    public var fiberLimit: Double = 150
    public init() {}
}
