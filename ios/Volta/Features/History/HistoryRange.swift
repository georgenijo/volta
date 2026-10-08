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

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return sameYear
            ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func group(_ items: [Item], by date: (Item) -> Date) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].items.append(item)
            } else {
                groups.append(DayGroup(day: day, items: [item]))
            }
        }
        return groups
    }
}

extension Date {
    var historyTime: String { formatted(date: .omitted, time: .shortened) }
}
