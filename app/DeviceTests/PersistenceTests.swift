import NutritionCore
import UIKit
import XCTest

@testable import NutritionTracker

@MainActor final class PersistenceTests: XCTestCase {
    func testRoundTripAndDelete() throws {
        let repository = try SwiftDataRepository(inMemory: true)
        var snapshot = DatabaseSnapshot()
        var entry = EntryRecord(
            input: "Два яйца and toast", source: .voice, day: ConsumptionDay(date: Date()))
        entry.nutrition = Nutrition(calories: 420, protein: 28, fiber: 8)
        entry.phase = .ready
        entry.draftInput = "edited text"
        snapshot.entries = [entry]
        snapshot.attempts = [
            AttemptRecord(
                entryID: entry.id, kind: .analysis, input: entry.originalInput, model: "test")
        ]
        snapshot.composer.text = "unfinished"
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load(), snapshot)
        try repository.save(DatabaseSnapshot())
        XCTAssertEqual(try repository.load(), DatabaseSnapshot())
    }
    func testHuninnIsRegistered() {
        XCTAssertNotNil(UIFont(name: "Huninn-Regular", size: 17))
    }
}
