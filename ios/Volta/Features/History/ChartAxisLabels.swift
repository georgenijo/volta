import Charts
import SwiftUI

/// X-axis labels centred on their ticks. On this SDK Swift Charts places a
/// value label at the tick's trailing edge whatever anchor it is given, so
/// the comparison and tyre charts draw their own: the chart keeps grid lines
/// only, reserves `ChartAxisLabels.height` below itself, and overlays these.
struct ChartAxisLabels<X: Plottable>: View {
    static var height: CGFloat { 22 }

    var proxy: ChartProxy
    var ticks: [(value: X, text: String)]

    var body: some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let frame = geo[anchor]
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    if let x = proxy.position(forX: tick.value) {
                        Text(tick.text)
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(Color.voltaTextSecondary)
                            .fixedSize()
                            // Clear of the y-axis labels, the lowest of which
                            // is centred on the plot's bottom edge.
                            .position(x: frame.minX + x, y: frame.maxY + 14)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum ChartDateTicks {
    /// Calendar-aligned date ticks across `range`: local midnights every 1, 2,
    /// 7 or 14 days for spans up to about two months, otherwise the first of
    /// every 1, 2, 3, 6 or 12 months. The step is the smallest giving at most
    /// `maxCount` ticks. Labels are "Nov 5" for day steps and "Nov" for months,
    /// with the year on January (or on every tick for yearly steps).
    static func ticks(_ range: ClosedRange<Date>, calendar: Calendar, maxCount: Int = 5) -> [(value: Date, text: String)] {
        guard range.upperBound > range.lowerBound else { return [] }
        let start = calendar.startOfDay(for: range.lowerBound)
        let spanDays = range.upperBound.timeIntervalSince(range.lowerBound) / 86_400
        var format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        format.timeZone = calendar.timeZone
        if spanDays <= 62 {
            for step in [1, 2, 7, 14] {
                var dates: [Date] = []
                var day = start < range.lowerBound ? calendar.date(byAdding: .day, value: 1, to: start)! : start
                while day <= range.upperBound {
                    dates.append(day)
                    day = calendar.date(byAdding: .day, value: step, to: day)!
                }
                if dates.count <= maxCount || step == 14 { return dates.map { ($0, $0.formatted(format)) } }
            }
        }
        var monthFormat = Date.FormatStyle.dateTime.month(.abbreviated)
        monthFormat.timeZone = calendar.timeZone
        var yearFormat = Date.FormatStyle.dateTime.month(.abbreviated).year()
        yearFormat.timeZone = calendar.timeZone
        let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: range.lowerBound))!
        for step in [1, 2, 3, 6, 12] {
            var dates: [Date] = []
            var month = firstMonth
            while month <= range.upperBound {
                let index = calendar.component(.month, from: month) - 1
                if month >= range.lowerBound, index % step == 0 { dates.append(month) }
                month = calendar.date(byAdding: .month, value: 1, to: month)!
            }
            if dates.count <= maxCount || step == 12 {
                return dates.map { date in
                    let january = calendar.component(.month, from: date) == 1
                    return (date, date.formatted(step == 12 || january ? yearFormat : monthFormat))
                }
            }
        }
        return []
    }
}
