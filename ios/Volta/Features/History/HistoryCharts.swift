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

/// Smooth line + soft gradient area time-series used on detail screens.
/// Long series are downsampled and the Y domain is computed once in `init`,
/// not per mark.
struct HistoryLineChart: View {
    var points: [HistoryChartPoint]
    var color: Color
    var unit: String
    var height: CGFloat = 150
    var digits: Int = 0
    /// Draw a zero baseline (e.g. power with regen).
    var showsZero: Bool = false
    /// Optional left-to-right stroke gradient (e.g. green→blue for DC sessions).
    var gradient: [Color]? = nil
    private let domain: ClosedRange<Double>

    @State private var selected: Date?

    init(points: [HistoryChartPoint], color: Color, unit: String, yDomain: ClosedRange<Double>? = nil,
         height: CGFloat = 150, digits: Int = 0, showsZero: Bool = false, gradient: [Color]? = nil) {
        let plotted = HistorySeries.downsample(points)
        self.points = plotted
        self.color = color
        self.unit = unit
        self.height = height
        self.digits = digits
        self.showsZero = showsZero
        self.gradient = gradient
        if let yDomain {
            self.domain = yDomain
        } else {
            // Leave headroom above the peak so flat traces (steady AC sessions) don't sit on the top edge.
            let auto = HistorySeries.domain(plotted)
            let peak = plotted.map(\.value).max() ?? auto.upperBound
            let span = max(auto.upperBound - auto.lowerBound, 1)
            self.domain = auto.lowerBound...max(auto.upperBound, peak + span * 0.18)
        }
    }

    private var stroke: AnyShapeStyle {
        gradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(color)
    }

    private var selectedPoint: HistoryChartPoint? {
        guard let selected else { return nil }
        return points.min { abs($0.t.timeIntervalSince(selected)) < abs($1.t.timeIntervalSince(selected)) }
    }

    var body: some View {
        let base = domain.lowerBound
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.t), yStart: .value("Base", base), yEnd: .value(unit, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.09), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value(unit, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if showsZero, domain.lowerBound < 0 {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Selected", p.t))
                    .foregroundStyle(Color.white.opacity(0.25))
                PointMark(x: .value("Selected", p.t), y: .value(unit, p.value))
                    .foregroundStyle(color)
                    .symbolSize(70)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text("\(VoltaFormat.number(p.value, digits: digits)) \(unit)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                            Text(p.t.historyTime)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .voltaClock)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .frame(height: height)
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

/// Placeholder shown in chart cards while the detail request is in flight.
struct HistoryChartPlaceholder: View {
    var height: CGFloat = 150
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(HistoryTheme.track.opacity(0.5))
            if let message {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(.center)
                    if let retry {
                        PillButton("Retry", systemImage: "arrow.clockwise", action: retry)
                    }
                }
                .padding()
            } else {
                ProgressView().tint(HistoryTheme.secondary)
            }
        }
        .frame(height: height)
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
                                        .tracking(1.1)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
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

/// Detail-screen top bar: back button, centered title.
struct HistoryDetailHeader: View {
    var title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VoltaHeader(title) {
            GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
        } trailing: {
            Color.clear.frame(width: 48, height: 48)
        }
    }
}

// MARK: - Session screens (Charging / Idles) in the Drives language

/// The single expanded hero numeral with a quiet unit.
struct HistoryHeroNumeral: View {
    var value: String
    var unit: String?
    var size: CGFloat = 84

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: size, weight: .bold)).fontWidth(.expanded).tracking(size > 60 ? -2 : -1)
                .foregroundStyle(.white)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
            if let unit {
                Text(unit).font(.system(size: size > 60 ? 20 : 17, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    .fixedSize()
            }
        }
    }
}

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

/// Pinned day header for any session list: calendar badge, day, a quiet
/// summary on the right and a full-width hairline underneath.
struct SessionDayHeader: View {
    var day: Date
    var title: String
    var trailing: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .foregroundStyle(HistoryTheme.secondary)
                Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary).lineLimit(1)
            }
            .padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
                .padding(.horizontal, -HistoryTheme.gutter)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(HistoryTheme.background.padding(.horizontal, -HistoryTheme.gutter))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// Open 270° battery dial: faint arc up to the lower level, a solid arc
/// between the two levels, the end level in the middle.
struct SocDial: View {
    var from: Int?
    var to: Int?
    var size: CGFloat = 40
    var caption: String? = nil
    var colors: [Color] = [HistoryTheme.green, HistoryTheme.green]
    private var line: CGFloat { max(2.5, size * 0.055) }
    private func clamp(_ v: Int) -> Double { Double(min(100, max(0, v))) / 100 }

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let from, let to {
                let lo = clamp(min(from, to)), hi = clamp(max(from, to))
                Circle().trim(from: 0, to: 0.75 * lo)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0.75 * lo, to: 0.75 * min(max(hi, lo + 0.01), 1.01))
                    .stroke(AngularGradient(colors: to >= from ? colors : colors.reversed(), center: .center,
                                            startAngle: .degrees(270 * lo), endAngle: .degrees(270 * hi)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }
            VStack(spacing: size * 0.02) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(to.map(String.init) ?? "–")
                        .font(.system(size: size * (caption == nil ? 0.34 : 0.32), weight: .semibold, design: .rounded))
                    if to != nil, size >= 60 {
                        Text("%").font(.system(size: size * 0.15, weight: .semibold, design: .rounded)).foregroundStyle(HistoryTheme.secondary)
                    }
                }
                .monospacedDigit().foregroundStyle(.white)
                if let caption {
                    Text(caption).font(.system(size: max(8, size * 0.1), weight: .semibold)).tracking(1.2)
                        .textCase(.uppercase).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(from.flatMap { f in to.map { "Battery \(f)% to \($0)%" } } ?? "Battery levels unavailable")
    }
}

/// Open 270° dial split into weighted segments (e.g. home vs public energy).
struct SegmentDial: View {
    struct Segment: Identifiable {
        var label: String
        var value: Double
        var color: Color
        var id: String { label }
    }
    var segments: [Segment]
    var center: String
    var caption: String
    /// Full-arc value; nil means the segments fill the whole arc.
    var scale: Double? = nil
    var size: CGFloat = 86
    var accessibility: String
    private var line: CGFloat { max(2.5, size * 0.055) }

    var body: some View {
        let sum = segments.reduce(0) { $0 + max(0, $1.value) }
        let total = max(scale ?? sum, sum)
        let live = segments.filter { $0.value > 0 }
        let gap = live.count > 1 ? 0.035 : 0
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if total > 0 {
                ForEach(Array(arcs(live, total: total, gap: gap).enumerated()), id: \.offset) { _, arc in
                    Circle().trim(from: arc.start, to: arc.end)
                        .stroke(arc.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(135))
                }
            }
            VStack(spacing: size * 0.02) {
                Text(center).font(.system(size: size * 0.3, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text(caption).font(.system(size: max(8, size * 0.1), weight: .semibold)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
            }
            .padding(.horizontal, line * 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private func arcs(_ live: [Segment], total: Double, gap: Double) -> [(start: Double, end: Double, color: Color)] {
        let usable = 0.75 - gap * Double(max(0, live.count - 1))
        var cursor = 0.0
        return live.map { segment in
            let length = max(0.012, usable * segment.value / total)
            defer { cursor += length + gap }
            return (cursor, cursor + length, segment.color)
        }
    }
}
