import Foundation

/// Date range chosen in the header pill.
enum HistoryRange: Hashable, Sendable {
    case today, sevenDays, thirtyDays, ninetyDays, all
    case custom(from: Date, to: Date)

    static let presets: [HistoryRange] = [.today, .sevenDays, .thirtyDays, .ninetyDays, .all]

    var label: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        case .ninetyDays: "90D"
        case .all: "All"
        case .custom(let from, let to):
            from.formatted(.dateTime.month(.abbreviated).day()) + "–" + to.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var menuTitle: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        case .all: "All time"
        case .custom: "Custom range"
        }
    }

    /// Phrase used in empty states: "No charges in 30 days".
    var emptyPhrase: String? {
        switch self {
        case .today: "today"
        case .sevenDays: "in 7 days"
        case .thirtyDays: "in 30 days"
        case .ninetyDays: "in 90 days"
        case .all: nil
        case .custom: "in this range"
        }
    }

    /// Short label for the period totals ("30D", "ALL TIME").
    var periodLabel: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        case .all: "All time"
        case .custom: label
        }
    }

    func dateRange(now: Date = .now, calendar: Calendar = .current) -> DateRange {
        switch self {
        case .today: DateRange(from: calendar.startOfDay(for: now), to: nil)
        case .sevenDays: DateRange(from: now.addingTimeInterval(-7 * 86_400), to: nil)
        case .thirtyDays: DateRange(from: now.addingTimeInterval(-30 * 86_400), to: nil)
        case .ninetyDays: DateRange(from: now.addingTimeInterval(-90 * 86_400), to: nil)
        case .all: DateRange(from: nil, to: nil)
        case .custom(let from, let to):
            DateRange(from: calendar.startOfDay(for: from),
                      to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)))
        }
    }
}

/// Day bucketing for the grouped lists (newest first, as the API returns).
struct DayGroup<Item: Identifiable & Hashable>: Identifiable, Hashable {
    var day: Date
    var items: [Item]
    var id: Date { day }

    var title: String { title(now: .now) }

    func title(now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "EEE MMM d yyyy")
        return formatter.string(from: day)
    }

    static func group(_ items: [Item], by date: (Item) -> Date, calendar: Calendar = .current) -> [DayGroup] {
        Dictionary(grouping: items, by: { calendar.startOfDay(for: date($0)) })
            .map { DayGroup(day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }
}

extension Date {
    var historyTime: String { historyTime(timeZone: .autoupdatingCurrent) }

    /// 24-hour clock time shared by every history list and detail.
    func historyTime(timeZone: TimeZone) -> String { VoltaFormat.clock(self, timeZone: timeZone) }
}
