import Foundation
import Testing

@testable import NutritionCore

@Suite struct MealDayTests {
    private func calendar(_ zone: String = "Asia/Ho_Chi_Minh") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func defaultDayChangesAtThreeAM() {
        let cal = calendar()
        let yesterday = date(12, 0, calendar: cal)
        let today = date(13, 0, calendar: cal)
        for now in [date(13, 0, calendar: cal), date(13, 2, 59, calendar: cal)] {
            #expect(MealDay.defaultSelection(now: now, calendar: cal) == yesterday)
        }
        for now in [date(13, 3, calendar: cal), date(13, 23, 59, calendar: cal)] {
            #expect(MealDay.defaultSelection(now: now, calendar: cal) == today)
        }
    }

    @Test func midnightChangesLabelWithoutChangingSelectedDay() {
        let cal = calendar()
        let selected = MealDay.defaultSelection(now: date(13, 23, 59, calendar: cal), calendar: cal)
        #expect(
            MealDay.relativeLabel(
                for: selected, now: date(13, 23, 59, calendar: cal), calendar: cal)
                == "Today")
        #expect(
            MealDay.relativeLabel(for: selected, now: date(14, 0, calendar: cal), calendar: cal)
                == "Yesterday")
        #expect(selected == date(13, 0, calendar: cal))
        #expect(
            MealDay.relativeLabel(for: selected, now: date(15, 0, calendar: cal), calendar: cal)
                == nil)
    }

    @Test func defaultDayUsesLocalCalendarAcrossDSTAndMonthBoundaries() {
        let cal = calendar("America/New_York")
        let now = cal.date(
            from: DateComponents(year: 2026, month: 11, day: 1, hour: 2, minute: 59))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        #expect(MealDay.defaultSelection(now: now, calendar: cal) == expected)
        #expect(MealDay.relativeLabel(for: expected, now: now, calendar: cal) == "Yesterday")
    }
}
