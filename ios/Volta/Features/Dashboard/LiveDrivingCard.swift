import SwiftUI

/// The Now card while the car drives: speed, the gear, and battery power on
/// a meter that runs left for regen and right for drive. Values that do not
/// hold now are dimmed and say how old they are (`LiveDriveDisplay`).
struct LiveDrivingCard: View {
    var status: VehicleStatus
    var style: NowCard.Style
    /// When this device received `status`; nil for saved or placeholder data.
    var fetchedAt: Date?
    @Environment(\.units) private var units

    var body: some View {
        // Ages the labels without a refresh: "Live" turns into "Updated 20 sec. ago".
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let display = LiveDriveDisplay.make(status, fetchedAt: fetchedAt, now: context.date)
            content(display, now: context.date)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LiveDriveText.accessibility(display, units: units, now: context.date))
                .accessibilityIdentifier("card.liveDriving")
        }
    }

    @ViewBuilder private func content(_ display: LiveDriveDisplay, now: Date) -> some View {
        switch style {
        case .compact:
            VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                header(display, now: now)
                HStack(alignment: .firstTextBaseline, spacing: VoltaSpacing.md) {
                    speed(display, now: now, size: 58)
                    Spacer(minLength: 0)
                    gear(display)
                }
                power(display, now: now)
            }
        case .standard:
            VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                header(display, now: now)
                HStack(alignment: .firstTextBaseline, spacing: VoltaSpacing.md) {
                    speed(display, now: now, size: 64)
                    Spacer(minLength: 0)
                    gear(display)
                }
                power(display, now: now)
            }
        case .wide:
            VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                header(display, now: now)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: VoltaSpacing.xl) {
                        HStack(alignment: .firstTextBaseline, spacing: VoltaSpacing.lg) {
                            speed(display, now: now, size: 64)
                            gear(display)
                        }
                        .fixedSize()
                        Rectangle().fill(Color.voltaHairline).frame(width: 1)
                        power(display, now: now).frame(maxWidth: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                        HStack(alignment: .firstTextBaseline) {
                            speed(display, now: now, size: 64)
                            Spacer(minLength: 0)
                            gear(display)
                        }
                        power(display, now: now)
                    }
                }
            }
        }
    }

    // MARK: Header

    private func header(_ display: LiveDriveDisplay, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Driving")
                .font(.system(.footnote, weight: .semibold))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(LiveDrivingCard.blueText)
            Spacer(minLength: VoltaSpacing.sm)
            FreshnessBadge(text: LiveDriveText.freshness(display.freshness, now: now), tone: FreshnessBadge.Tone(display.freshness))
        }
    }

    /// Blue light enough to read as small text on the card (6:1).
    static let blueText = NowCard.parkedText
    /// Status colours with no theme token: stale readings, and no readings at all.
    static let staleAmber = Color(hex: 0xFF9F0A)
    static let noDataGray = Color(hex: 0x8E8E93)

    /// The gear pill sits on the speed's baseline.
    private func gear(_ display: LiveDriveDisplay) -> some View {
        GearSelector(gear: display.gear, isLive: display.gearIsLive)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
    }

    // MARK: Speed

    /// The speed line and one caption line, the same height in every state:
    /// a hidden "188 mph" holds the line, and the caption line is always laid out.
    private func speed(_ display: LiveDriveDisplay, now: Date, size: CGFloat) -> some View {
        let unit = LiveDriveText.speedUnit(units)
        let note: String? = switch display.speed {
        case .live: nil
        case .stopped: "Resumes when moving"
        case .stale(_, let at): display.isStale ? nil : LiveDriveText.age(at, now: now)
        case .unknown: "Speed unavailable"
        }
        return VStack(alignment: .leading, spacing: 2) {
            // The placeholder alone sizes the line and sets its baseline; the
            // value is drawn over it, so no state can change the card's height.
            NowNumber(value: "188", unit: unit, size: size, color: .clear).hidden()
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {
                switch display.speed {
                case .live(let kph):
                    NowNumber(value: LiveDriveText.speed(kph: kph, units: units), unit: unit, size: size, color: .voltaTextPrimary)
                case .stale(let kph, _):
                    NowNumber(value: LiveDriveText.speed(kph: kph, units: units), unit: unit, size: size, color: .voltaTextTertiary)
                case .stopped:
                    Text("Stopped")
                        .font(.system(size: size * 0.62, weight: .heavy))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                case .unknown:
                    NowNumber(value: "—", unit: unit, size: size, color: .voltaTextTertiary)
                }
            }
            caption(note ?? " ").opacity(note == nil ? 0 : 1)
        }
    }

    // MARK: Power

    @ViewBuilder private func power(_ display: LiveDriveDisplay, now: Date) -> some View {
        let reading: (kw: Double, live: Bool)? = switch display.power {
        case .live(let kw): (kw, true)
        case .stale(let kw, _): (kw, false)
        case .awaitingMovement, .unknown: nil
        }
        let kind = reading.map { LiveDriveText.kind(kw: $0.kw) }
        // A stale fill keeps its colour, dimmed: the badge says how old it is.
        let tint: Color = (kind == .regen ? Color.voltaGreen : .voltaBlue).opacity(reading?.live == false ? 0.45 : 1)
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VoltaSpacing.sm) {
                Text(LiveDriveText.powerTitle(display.power))
                    .font(.system(.footnote, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(reading?.live == true && kind == .regen ? Color.voltaGreen : Color.voltaTextSecondary)
                Spacer(minLength: VoltaSpacing.sm)
                switch display.power {
                case .live(let kw):
                    powerValue(LiveDriveText.power(kw: kw), color: kind == .regen ? .voltaGreen : .voltaTextPrimary)
                case .stale(let kw, let at):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !display.isStale { caption(LiveDriveText.age(at, now: now)) }
                        powerValue(LiveDriveText.power(kw: kw), color: .voltaTextTertiary)
                    }
                case .awaitingMovement, .unknown:
                    powerValue("—", color: .voltaTextTertiary)
                }
            }
            PowerMeter(kw: reading?.kw, tint: tint)
                .frame(height: 10)
        }
    }

    private func powerValue(_ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(.title2, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("kW").font(.subheadline)
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.voltaTextSecondary)
            .lineLimit(1)
    }
}

// MARK: - Parts

/// "● Live", "● 1m old", "Saved …" or "No data": the card's one freshness.
private struct FreshnessBadge: View {
    enum Tone {
        case live, stale, saved, none
        init(_ freshness: LiveDriveDisplay.Freshness) {
            switch freshness {
            case .live: self = .live
            case .lastReading, .notRefreshed: self = .stale
            case .saved: self = .saved
            case .unknown: self = .none
            }
        }
        var color: Color {
            switch self {
            case .live: .voltaGreen
            case .stale: LiveDrivingCard.staleAmber
            case .saved: .voltaTextSecondary
            case .none: LiveDrivingCard.noDataGray
            }
        }
    }

    var text: String
    var tone: Tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            switch tone {
            case .live:
                StatusDot(color: tone.color, size: 7)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = !reduceMotion }
                    .onChange(of: reduceMotion) { _, reduce in pulse = !reduce }
            case .stale:
                StatusDot(color: tone.color, size: 7)
            case .saved, .none:
                EmptyView()
            }
            Text(text)
                .font(.system(.footnote, weight: tone == .live || tone == .stale ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .accessibilityIdentifier("liveDriving.freshness")
    }
}

/// P R N D, the current gear filled. A gear that does not hold now is outlined.
struct GearSelector: View {
    var gear: LiveDrive.Gear?
    var isLive: Bool
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LiveDrive.Gear.allCases, id: \.self) { item in
                let selected = item == gear
                Text(item.rawValue)
                    .font(.system(size: cell * 0.56, weight: selected ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(selected ? (isLive ? Color.voltaTextPrimary : Color.voltaTextSecondary) : Color.voltaTextTertiary)
                    .frame(width: cell, height: cell)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isLive ? Color.voltaBlueFill : Color.clear)
                                .strokeBorder(isLive ? Color.clear : Color.voltaTextTertiary, lineWidth: 1)
                        }
                    }
            }
        }
        .padding(3)
        .background(Color.voltaControlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: gear)
        .accessibilityHidden(true)
    }
}

/// Battery power on one scale: zero a quarter of the way in, regen (to
/// −50 kW) to its left, drive (to 150 kW, past which it stays full) to its right. The same kilowatts
/// are the same length both ways; nil shows the empty track.
struct PowerMeter: View {
    var kw: Double?
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let regenSpan = 50.0
    static let driveSpan = 150.0
    static var zero: Double { regenSpan / (regenSpan + driveSpan) }

    /// The filled span as fractions of the track, from zero toward the reading.
    static func span(kw: Double) -> ClosedRange<Double> {
        let x = zero + max(-regenSpan, min(driveSpan, kw)) / (regenSpan + driveSpan)
        return min(x, zero)...max(x, zero)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.voltaRaised)
                if let kw {
                    let span = Self.span(kw: kw)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height * 0.6, (span.upperBound - span.lowerBound) * width))
                        .offset(x: kw < 0 ? span.lowerBound * width : Self.zero * width)
                        .shadow(color: tint.opacity(0.5), radius: 5)
                }
                Rectangle()
                    .fill(Color.voltaTextSecondary)
                    .frame(width: 2, height: height + 6)
                    .offset(x: Self.zero * width - 1)
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: kw)
        }
        .accessibilityHidden(true)
    }
}
