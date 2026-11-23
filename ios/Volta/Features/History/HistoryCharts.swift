import Charts
import SwiftUI

struct HistoryChartPoint: Identifiable, Hashable {
    var t: Date
    var value: Double
    var id: Date { t }
}

enum HistorySeries {
    /// Min/max-preserving downsample: splits the series into time-ordered
    /// buckets and keeps each bucket's lowest and highest point (plus the
    /// first and last point), so peaks and dips survive. O(n).
    static func downsample(_ points: [HistoryChartPoint], maxPoints: Int = 500) -> [HistoryChartPoint] {
        guard maxPoints >= 4, points.count > maxPoints else { return points }
        let interior = points.count - 2
        let buckets = (maxPoints - 2) / 2
        let size = Int((Double(interior) / Double(buckets)).rounded(.up))
        var keep: [Int] = [0]
        var start = 1
        while start < points.count - 1 {
            let end = min(start + size, points.count - 1)
            var lo = start, hi = start
            for i in start..<end {
                if points[i].value < points[lo].value { lo = i }
                if points[i].value > points[hi].value { hi = i }
            }
            keep.append(min(lo, hi))
            if lo != hi { keep.append(max(lo, hi)) }
            start = end
        }
        keep.append(points.count - 1)
        return keep.map { points[$0] }
    }

    /// Y domain including zero, padded 8% above the max.
    static func domain(_ points: [HistoryChartPoint]) -> ClosedRange<Double> {
        var lo = 0.0, hi = -Double.infinity
        for p in points {
            lo = min(lo, p.value)
            hi = max(hi, p.value)
        }
        if !hi.isFinite { hi = 1 }
        hi = max(hi, lo + 1)
        return lo...(hi + (hi - lo) * 0.08)
    }
}

/// Card wrapper: small-caps title, optional headline value, chart.
struct HistoryChartCard<Accessory: View, Plot: View>: View {
    var title: String
    var systemImage: String
    var value: String? = nil
    var unit: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var chart: Plot

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    HistorySectionLabel(title: title, systemImage: systemImage)
                        .fixedSize()
                    Spacer()
                    accessory
                }
                if let value {
                    HistoryValue(value: value, unit: unit, size: 26)
                }
                chart
            }
        }
    }
}

extension HistoryChartCard where Accessory == EmptyView {
    init(title: String, systemImage: String, value: String? = nil, unit: String? = nil, @ViewBuilder chart: () -> Plot) {
        self.init(title: title, systemImage: systemImage, value: value, unit: unit, accessory: { EmptyView() }, chart: chart)
    }
}

/// A chart that isn't drawn yet. While the detail request is in flight it is
/// a skeleton of a chart (gridlines and a trace); with a message it says why
/// there is no chart, with Try again when `retry` is set.
struct HistoryChartPlaceholder: View {
    var height: CGFloat = 150
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let message {
                RoundedRectangle(cornerRadius: 12).fill(HistoryTheme.track.opacity(0.5))
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(.center)
                    if let retry {
                        PillButton("Try again", systemImage: "arrow.clockwise", action: retry)
                    }
                }
                .padding()
            } else {
                HistoryChartSkeleton()
                    .voltaSkeleton(true)
            }
        }
        .frame(height: height)
    }
}

/// The outline of a time-series chart: three gridlines, a gentle trace and
/// axis-label blocks, for `.voltaSkeleton`.
struct HistoryChartSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle().fill(HistoryTheme.track)
                            .frame(height: 1)
                            .offset(y: h * CGFloat(i) / 2)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * 0.7))
                        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.35),
                                   control1: CGPoint(x: w * 0.2, y: h * 0.7), control2: CGPoint(x: w * 0.3, y: h * 0.3))
                        p.addCurve(to: CGPoint(x: w, y: h * 0.5),
                                   control1: CGPoint(x: w * 0.7, y: h * 0.4), control2: CGPoint(x: w * 0.85, y: h * 0.6))
                    }
                    .stroke(HistoryTheme.track, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            HStack {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(HistoryTheme.track).frame(width: 26, height: 8)
                    if i < 3 { Spacer(minLength: 8) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Grid of stats separated by hairlines, inside one card.
struct HistoryStatGrid: View {
    struct Item: Identifiable {
        var label: String
        var value: String
        var unit: String? = nil
        var systemImage: String
        var id: String { label }
    }
    var items: [Item]
    var columns: Int = 3

    var body: some View {
        HistoryCard(padding: 0) {
            let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { HairlineDivider() }
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { i, item in
                            if i > 0 {
                                Rectangle().fill(HistoryTheme.hairline).frame(width: 1)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 5) {
                                    Image(systemName: item.systemImage)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(item.label).voltaLabelStyle()
                                        .lineLimit(1)
                                        // Three columns on the 382 pt outer display: shrink, don't truncate.
                                        .minimumScaleFactor(0.65)
                                }
                                .foregroundStyle(HistoryTheme.secondary)
                                HistoryValue(value: item.value, unit: item.unit, size: 20)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Rectangle().fill(HistoryTheme.hairline).frame(width: 1)
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Session screens (Charging / Idles) in the Drives language

/// Small notes under a hero (partial data, mixed currency).
struct HistoryHeroNotes: View {
    var notes: [String]
    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.self) { Text($0) }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The calendar days a day strip can honestly show: whole days inside the
/// requested range, inside what the loaded pages cover, at most `limit` of
/// them. Days outside are omitted, never drawn as zero.
struct HistoryDayWindow: Equatable {
    /// Local day starts, oldest first.
    var days: [Date]
    /// The last day shown is today (so it can be lit).
    var endsToday: Bool
    /// Names exactly the days shown, e.g. "Last 7 days" or "Mar 7 – Mar 20".
    var label: String

    /// A strip needs at least two days to read as a rhythm.
    var isDrawable: Bool { days.count >= 2 }

    /// - Parameters:
    ///   - range: The query the rows were loaded with.
    ///   - oldestLoaded: Start of the oldest loaded row.
    ///   - hasMore: A cursor remains, so older rows (including more on the
    ///     oldest loaded row's day) are not loaded yet.
    init(range: DateRange, oldestLoaded: Date?, hasMore: Bool, limit: Int = 14,
         now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        func nextDay(_ day: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        // `to` is exclusive; the last whole day ends just before it.
        let last = range.to.map { min(today, calendar.startOfDay(for: $0.addingTimeInterval(-1))) } ?? today
        var first = calendar.date(byAdding: .day, value: -(max(limit, 1) - 1), to: last) ?? last
        if let from = range.from {
            // A day the range starts partway through is only partly queried.
            let day = calendar.startOfDay(for: from)
            first = max(first, day == from ? day : nextDay(day))
        }
        if hasMore {
            // Unloaded pages hold older rows, and may hold more of the oldest loaded day.
            first = max(first, oldestLoaded.map { nextDay(calendar.startOfDay(for: $0)) } ?? nextDay(last))
        }
        var days: [Date] = []
        var day = first
        while day <= last {
            days.append(day)
            let next = nextDay(day)
            guard next > day else { break }
            day = next
        }
        self.days = days
        endsToday = days.last == today
        if endsToday {
            label = days.count == 1 ? "Today" : "Last \(days.count) days"
        } else if let start = days.first, let end = days.last {
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            label = start == end ? start.formatted(style) : "\(start.formatted(style)) – \(end.formatted(style))"
        } else {
            label = ""
        }
    }
}

/// One day in a day strip.
struct HistoryRhythmDay: Hashable {
    var day: Date
    var value: Double
    /// Draw this bar in the accent color (e.g. a DC fast day).
    var accent = false
    /// Today, drawn lit.
    var isToday = false

    /// One entry per day in `window`, oldest first; nothing outside it.
    static func series<T>(_ items: [T], date: (T) -> Date, value: (T) -> Double, accent: (T) -> Bool = { _ in false },
                          window: HistoryDayWindow, calendar: Calendar = .current) -> [HistoryRhythmDay] {
        let groups = Dictionary(grouping: items, by: { calendar.startOfDay(for: date($0)) })
        return window.days.map { day in
            let group = groups[day] ?? []
            return HistoryRhythmDay(day: day, value: group.reduce(0) { $0 + max(0, value($1)) }, accent: group.contains(where: accent),
                                    isToday: window.endsToday && day == window.days.last)
        }
    }
}
