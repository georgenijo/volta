import SwiftUI

/// "LAST 48H" rhythm: one thin capsule per hour, tallest for drives, then
/// charging, then online time; quiet hours are dots. Same idiom as the Drives
/// tab's DailyRhythm.
struct ActivityStrip: View {
    var segments: [TimelineSegment]
    var hours: Int = 48
    var now: Date = .now
    /// The timeline request failed. With no segments this shows "unavailable"
    /// rather than an empty (idle) strip.
    var failed = false

    private var unavailable: Bool { failed && segments.isEmpty }
    private static let height: CGFloat = 40

    static func color(for kind: TimelineKind) -> Color? {
        switch kind {
        case .drive: .voltaBlue
        case .charge: .voltaMint
        case .idle: Color.white.opacity(0.32)
        case .asleep, .offline: nil
        }
    }

    /// Visual priority when several kinds share an hour.
    private static func rank(_ kind: TimelineKind) -> Int {
        switch kind {
        case .drive: 3
        case .charge: 2
        case .idle: 1
        case .asleep, .offline: 0
        }
    }

    private static func peak(for kind: TimelineKind) -> CGFloat {
        switch kind {
        case .drive: height
        case .charge: height * 0.72
        default: height * 0.34
        }
    }

    struct Hour: Hashable {
        var kind: TimelineKind?
        /// Share of the hour covered by `kind`, 0...1.
        var coverage: Double
    }

    /// One entry per hour, oldest first: the highest-priority kind seen in it.
    static func hourly(_ segments: [TimelineSegment], hours: Int, now: Date) -> [Hour] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        return (0..<hours).map { i in
            let h0 = start.addingTimeInterval(Double(i) * 3600), h1 = h0.addingTimeInterval(3600)
            var best: Hour = .init(kind: nil, coverage: 0)
            for segment in segments where color(for: segment.kind) != nil {
                let overlap = min(segment.end, h1).timeIntervalSince(max(segment.start, h0))
                guard overlap > 0 else { continue }
                let coverage = min(overlap / 3600, 1)
                let current = best.kind.map(rank) ?? 0
                if rank(segment.kind) > current {
                    best = .init(kind: segment.kind, coverage: coverage)
                } else if segment.kind == best.kind {
                    best.coverage = min(best.coverage + coverage, 1)
                }
            }
            return best
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last \(hours)h").dashboardCaption(size: 11)
                Spacer()
                HStack(spacing: 12) {
                    legend("Drives", .voltaBlue)
                    legend("Charging", .voltaMint)
                    legend("Online", .white.opacity(0.4))
                }
            }
            strip
                .frame(height: Self.height, alignment: .bottom)
                .overlay {
                    if unavailable {
                        Label("Timeline unavailable", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.voltaTextSecondary)
                            .padding(.horizontal, VoltaSpacing.md)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.voltaBackground.opacity(0.9)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    }
                }
            axis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 3, height: 9)
            Text(title).dashboardCaption()
        }
    }

    private var strip: some View {
        let bars = Self.hourly(segments, hours: hours, now: now)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, hour in
                if index > 0 { Spacer(minLength: 1) }
                // Grow from the bottom on arrival; the current hour breathes while lit.
                bar(hour, isNow: index == bars.count - 1)
                    .voltaGrow(index: index / 3)
            }
        }
    }

    @ViewBuilder
    private func bar(_ hour: Hour, isNow: Bool) -> some View {
        if let kind = hour.kind, let color = Self.color(for: kind) {
            let peak = Self.peak(for: kind)
            let height = max(6, peak * (0.45 + 0.55 * hour.coverage))
            let lit = kind == .drive || kind == .charge
            Capsule()
                .fill(lit ? AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(color))
                .frame(width: 4, height: height)
                .shadow(color: lit ? color.opacity(0.55) : .clear, radius: 4)
                .voltaBreathingGlow(color: color, radius: 6, isActive: isNow && lit)
        } else {
            Circle().fill(Color.white.opacity(0.1)).frame(width: 3, height: 3)
                .frame(width: 4)
        }
    }

    private var axis: some View {
        HStack {
            Text("-\(hours)h")
            Spacer()
            Text("-\(hours / 2)h")
            Spacer()
            Text("Now")
        }
        .dashboardCaption()
    }

    private var accessibilitySummary: String {
        if unavailable { return "Last \(hours) hours: timeline unavailable" }
        let drives = segments.filter { $0.kind == .drive }.count
        let charges = segments.filter { $0.kind == .charge }.count
        return "Last \(hours) hours: \(drives) drives, \(charges) charging sessions"
    }
}

#Preview("Strip") {
    let now = Date.now
    let h: (Double) -> Date = { now.addingTimeInterval(-$0 * 3600) }
    VStack(spacing: 40) {
        ActivityStrip(segments: [
            .init(kind: .drive, start: h(40), end: h(39)),
            .init(kind: .charge, start: h(30), end: h(26)),
            .init(kind: .drive, start: h(12), end: h(11.5)),
            .init(kind: .idle, start: h(1), end: now),
        ], now: now)
        ActivityStrip(segments: [], now: now)
    }
    .padding(VoltaSpacing.screen)
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
