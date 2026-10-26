import Foundation

public enum MealDay {
    public static func defaultSelection(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard calendar.component(.hour, from: now) < 3 else { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    public static func relativeLabel(for selection: Date, now: Date, calendar: Calendar = .current)
        -> String?
    {
        if calendar.isDate(selection, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(selection, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return nil
    }
}
