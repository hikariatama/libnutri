import Foundation
import NutritionCore
import SwiftData

@Model final class FoodEntry {
    @Attribute(.unique) var id: UUID
    var originalInput: String
    var draftInput: String?
    var inputSource: String
    var calories: Double?
    var protein: Double?
    var fiber: Double?
    var consumptionDay: String
    var timeZoneID: String
    var consumedAt: Date
    var createdAt: Date
    var updatedAt: Date
    var state: String
    var activeOperationID: UUID?
    var version: Int = 1
    init(_ value: EntryRecord) {
        id = value.id
        originalInput = value.originalInput
        inputSource = value.inputSource.rawValue
        consumptionDay = value.day.key
        timeZoneID = value.day.timeZoneID
        consumedAt = value.consumedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        state = value.phase.rawValue
        apply(value)
    }
    func apply(_ value: EntryRecord) {
        originalInput = value.originalInput
        draftInput = value.draftInput
        inputSource = value.inputSource.rawValue
        calories = value.nutrition?.calories
        protein = value.nutrition?.protein
        fiber = value.nutrition?.fiber
        consumptionDay = value.day.key
        timeZoneID = value.day.timeZoneID
        consumedAt = value.consumedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        state = value.phase.rawValue
        activeOperationID = value.activeOperationID
        version = value.version
    }
    var record: EntryRecord {
        var result = EntryRecord(
            id: id, input: originalInput, source: InputSource(rawValue: inputSource) ?? .text,
            day: .init(key: consumptionDay, timeZoneID: timeZoneID), date: createdAt)
        result.draftInput = draftInput
        result.updatedAt = updatedAt
        result.consumedAt = consumedAt
        result.version = version
        result.phase = EntryPhase(rawValue: state) ?? .interrupted
        result.activeOperationID = activeOperationID
        if let calories, let protein, let fiber {
            result.nutrition = .init(calories: calories, protein: protein, fiber: fiber)
        }
        return result
    }
}

@Model final class RecognitionAttempt {
    @Attribute(.unique) var id: UUID
    var entryID: UUID
    var operationType: String
    var inputSnapshot: String
    var model: String
    var requestCount: Int
    var state: String
    var errorCategory: String?
    var createdAt: Date
    var updatedAt: Date
    var promptVersion: String
    init(_ value: AttemptRecord) {
        id = value.id
        entryID = value.entryID
        operationType = value.kind.rawValue
        inputSnapshot = value.inputSnapshot
        model = value.model
        requestCount = value.requestCount
        state = value.phase.rawValue
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        promptVersion = value.promptVersion
        apply(value)
    }
    func apply(_ value: AttemptRecord) {
        entryID = value.entryID
        operationType = value.kind.rawValue
        inputSnapshot = value.inputSnapshot
        model = value.model
        requestCount = value.requestCount
        state = value.phase.rawValue
        errorCategory = value.errorCategory
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        promptVersion = value.promptVersion
    }
    var record: AttemptRecord {
        var result = AttemptRecord(
            entryID: entryID, kind: AttemptKind(rawValue: operationType) ?? .analysis,
            input: inputSnapshot, model: model)
        result.id = id
        result.requestCount = requestCount
        result.phase = AttemptPhase(rawValue: state) ?? .interrupted
        result.errorCategory = errorCategory
        result.createdAt = createdAt
        result.updatedAt = updatedAt
        result.promptVersion = promptVersion
        return result
    }
}

@Model final class ComposerState {
    @Attribute(.unique) var id: String = "composer"
    var text: String = ""
    var source: String = "text"
    var entryID: UUID?
    init() {}
}

@MainActor final class SwiftDataRepository: EntryPersistence {
    let container: ModelContainer
    private let context: ModelContext
    init(inMemory: Bool = false) throws {
        let schema = Schema([FoodEntry.self, RecognitionAttempt.self, ComposerState.self])
        let configuration = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    func load() throws -> DatabaseSnapshot {
        var snapshot = DatabaseSnapshot()
        snapshot.entries = try context.fetch(FetchDescriptor<FoodEntry>()).map(\.record)
        snapshot.attempts = try context.fetch(FetchDescriptor<RecognitionAttempt>()).map(\.record)
        if let composer = try context.fetch(FetchDescriptor<ComposerState>()).first {
            snapshot.composer.text = composer.text
            snapshot.composer.source = InputSource(rawValue: composer.source) ?? .text
            snapshot.composer.entryID = composer.entryID
        }
        return snapshot
    }
    func save(_ snapshot: DatabaseSnapshot) throws {
        do {
            let entries = try context.fetch(FetchDescriptor<FoodEntry>())
            let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            let wanted = Set(snapshot.entries.map(\.id))
            for entry in entries where !wanted.contains(entry.id) { context.delete(entry) }
            for value in snapshot.entries {
                if let existing = index[value.id] {
                    existing.apply(value)
                } else {
                    context.insert(FoodEntry(value))
                }
            }
            let attempts = try context.fetch(FetchDescriptor<RecognitionAttempt>())
            let attemptIndex = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
            let wantedAttempts = Set(snapshot.attempts.map(\.id))
            for attempt in attempts where !wantedAttempts.contains(attempt.id) {
                context.delete(attempt)
            }
            for value in snapshot.attempts {
                if let existing = attemptIndex[value.id] {
                    existing.apply(value)
                } else {
                    context.insert(RecognitionAttempt(value))
                }
            }
            let composer: ComposerState
            if let existing = try context.fetch(FetchDescriptor<ComposerState>()).first {
                composer = existing
            } else {
                composer = ComposerState()
                context.insert(composer)
            }
            composer.text = snapshot.composer.text
            composer.source = snapshot.composer.source.rawValue
            composer.entryID = snapshot.composer.entryID
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
