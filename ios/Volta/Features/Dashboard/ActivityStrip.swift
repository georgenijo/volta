import SwiftUI

/// "LAST 48H" strip: hourly ticks with drives (red), charging (green) and
/// online/idle (blue) segments, plus a -48H … NOW axis.
struct ActivityStrip: View {
    var segments: [TimelineSegment]
    var hours: Int = 48
    var now: Date = .now
    /// The timeline request failed. With no segments this shows "unavailable"
    /// rather than an empty (idle) strip.
    var failed = false

    private var unavailable: Bool { failed && segments.isEmpty }

    static func color(for kind: TimelineKind) -> Color? {
        switch kind {
        case .drive: .voltaRed
        case .charge: .voltaGreen
        case .idle: .voltaBlue
        case .asleep, .offline: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            HStack {
                Text("Last \(hours)h").voltaLabelStyle()
                Spacer()
                HStack(spacing: VoltaSpacing.md) {
                    legend("Drives", .voltaRed)
                    legend("Charging", .voltaGreen)
                    legend("Online", .voltaBlue)
                }
            }
            strip
                .frame(height: 34)
                .overlay {
                    if unavailable {
                        Label("Timeline unavailable", systemImage: "exclamationmark.triangle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.voltaTextSecondary)
                            .padding(.horizontal, VoltaSpacing.md)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.voltaBackground.opacity(0.85)))
                    }
                }
            axis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 6)
            Text(title)
                .font(.caption2)
                .tracking(0.8)
                .foregroundStyle(Color.voltaTextSecondary)
        }
    }

    private var strip: some View {
        Canvas { context, size in
            let start = now.addingTimeInterval(-Double(hours) * 3600)
            let total = now.timeIntervalSince(start)
            let rect = CGRect(origin: .zero, size: size)
            let clip = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
            context.clip(to: clip)
            context.fill(clip, with: .color(Color.white.opacity(0.035)))

            // Hour cells.
            let gap: CGFloat = 2
            let cell = (size.width - gap * CGFloat(hours - 1)) / CGFloat(hours)
            var cells = Path()
            for i in 0..<hours {
                cells.addRect(CGRect(x: CGFloat(i) * (cell + gap), y: 0, width: cell, height: size.height))
            }
            context.fill(cells, with: .color(Color.white.opacity(0.06)))

            // Segments, drawn as continuous bars, then masked to the cells.
            context.drawLayer { layer in
                layer.clip(to: cells)
                for segment in segments {
                    guard let color = Self.color(for: segment.kind) else { continue }
                    let s = max(segment.start, start), e = min(segment.end, now)
                    guard e > s else { continue }
                    let x0 = CGFloat(s.timeIntervalSince(start) / total) * size.width
                    let x1 = CGFloat(e.timeIntervalSince(start) / total) * size.width
                    let r = CGRect(x: x0, y: 0, width: max(x1 - x0, cell), height: size.height)
                    layer.fill(Path(r), with: .color(color.opacity(segment.kind == .idle ? 0.7 : 0.9)))
                }
            }
        }
    }

    private var axis: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                axisLabel("-\(hours)H").position(x: 0, y: 8).offset(x: 18)
                axisLabel("-\(hours / 2)H").position(x: w * 0.5, y: 8)
                axisLabel("-\(hours / 4)H").position(x: w * 0.75, y: 8)
                axisLabel("NOW").position(x: w, y: 8).offset(x: -16)
            }
        }
        .frame(height: 16)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .tracking(1.2)
            .foregroundStyle(Color.voltaTextSecondary)
            .fixedSize()
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
