import SwiftUI

// MARK: - Variant

/// What the car is doing now, which picks the Now card's content.
enum NowVariant: Equatable {
    case charging
    /// Plugged in, not charging (stopped or complete).
    case pluggedIn
    case parked
    case driving
    /// Asleep or offline: last seen, and Wake.
    case unreachable(VehicleState)

    static func of(_ status: VehicleStatus) -> NowVariant {
        if status.isCharging { return .charging }
        if LiveDriveDisplay.isDriving(status) { return .driving }
        // In Park while TeslaMate still has the drive open: parked.
        switch status.state {
        case .asleep, .offline: return .unreachable(status.state)
        default: break
        }
        switch status.chargingState {
        case .stopped?, .complete?: return .pluggedIn
        default: return .parked
        }
    }
}

/// Text the Now card and Controls share.
enum NowCardContent {
    /// "48m to 80%", from the car's own estimate.
    static func timeToLimit(_ status: VehicleStatus?) -> String? {
        guard let status, let minutes = status.minutesToFull else { return nil }
        let duration = VoltaFormat.duration(minutes: Double(minutes))
        return status.chargeLimit.map { "\(duration) to \($0)%" } ?? "\(duration) left"
    }

    /// "32 A · 241 V · +2.9 kWh added"
    static func electrical(_ status: VehicleStatus) -> String? {
        let parts = [status.chargerCurrentA.map { "\(VoltaFormat.number($0, digits: 0)) A" },
                     status.chargerVoltage.map { "\(VoltaFormat.number($0, digits: 0)) V" },
                     status.chargeEnergyAddedKwh.map { "+\(VoltaFormat.number($0, digits: 1)) kWh added" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func power(_ kw: Double?) -> String {
        kw.map { VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1) } ?? "—"
    }

    /// When the car stopped driving, from the 48 h timeline the Dashboard
    /// already loaded: the end of the latest drive, if nothing later is a drive
    /// or a charge in progress.
    static func parkedSince(_ timeline: [TimelineSegment], now: Date = .now) -> Date? {
        guard let lastDrive = timeline.filter({ $0.kind == .drive }).max(by: { $0.end < $1.end }),
              lastDrive.end <= now else { return nil }
        return lastDrive.end
    }
}

// MARK: - Card

/// The Dashboard's "Now" card. `style` follows the window: `.compact` on the
/// outer display and ordinary iPhones, `.standard` in the Dashboard's second
/// pane, `.wide` across the upright inner display.
struct NowCard: View {
    enum Style { case compact, standard, wide }

    var status: VehicleStatus
    var style: Style
    var context: VehicleCommandContext
    var powerCurve: [ChargeCurvePoint] = []
    var parkedSince: Date?
    /// When this device received `status`; nil for saved or placeholder data.
    var fetchedAt: Date?
    var openLiveCharge: () -> Void
    /// Sends a command (asking first where needed), or opens Controls when
    /// controls are not enabled for it.
    var perform: (VehicleCommand) -> Void
    var openControls: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        let variant = NowVariant.of(status)
        Group {
            switch variant {
            case .charging: charging
            case .pluggedIn: pluggedIn
            case .parked: parked
            case .driving: LiveDrivingCard(status: status, style: style, fetchedAt: fetchedAt)
            case .unreachable(let state): unreachable(state)
            }
        }
        .padding(style == .compact ? VoltaSpacing.lg + 2 : VoltaSpacing.xl - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background(accent: Self.accent(for: variant)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.now")
    }

    /// The card's colour says what the car is doing: green while energy goes
    /// in, blue while it sits parked and awake or drives (as the driving Live
    /// Activity). Other states stay neutral.
    static func accent(for variant: NowVariant) -> Color? {
        switch variant {
        case .charging: .voltaGreen
        case .parked, .driving: .voltaBlue
        case .pluggedIn, .unreachable: nil
        }
    }

    /// Blue that reads as small text on the card: 6.4:1 on the dark card,
    /// 6.7:1 on the light one.
    static let parkedText = Color(light: 0x1D4ED8, dark: 0x60A5FA)

    private func background(accent: Color?) -> some View {
        RoundedRectangle(cornerRadius: VoltaRadius.card + 4, style: .continuous)
            .fill(Color.voltaCard)
            .shadow(color: .voltaCardShadow, radius: 6, y: 2)
            .overlay {
                if let accent {
                    RoundedRectangle(cornerRadius: VoltaRadius.card + 4, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.12), .clear],
                                             startPoint: .topLeading, endPoint: .bottom))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: VoltaRadius.card + 4, style: .continuous)
                    .strokeBorder(accent?.opacity(0.35) ?? Color.voltaHairline, lineWidth: 1)
            }
    }

    // MARK: Charging

    @ViewBuilder private var charging: some View {
        switch style {
        case .compact:
            VStack(alignment: .leading, spacing: VoltaSpacing.md + 2) {
                header("Charging", trailing: NowCardContent.timeToLimit(status), green: true)
                Button(action: openLiveCharge) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center) {
                            powerReading(size: 46)
                            Spacer(minLength: VoltaSpacing.md)
                            electricalStack(alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: VoltaSpacing.xs) {
                            powerReading(size: 46)
                            electricalStack(alignment: .leading)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(VoltaPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(liveChargeAccessibility)
                .accessibilityHint("Opens the live charging session")
                .accessibilityIdentifier("button.liveCharge")
                limitAndStop
            }
        case .standard:
            VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                chargingReadout
                limitAndStop
            }
        case .wide:
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: VoltaSpacing.xl) {
                    chargingReadout.frame(maxWidth: .infinity)
                    Rectangle().fill(Color.voltaHairline).frame(width: 1)
                    VStack(spacing: VoltaSpacing.md) {
                        limitRow
                        stopCharging
                    }
                    .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                    chargingReadout
                    limitRow
                    stopCharging
                }
            }
        }
    }

    /// Label, power with its sparkline, and the electrical line; the power
    /// area opens the live charging sheet.
    private var chargingReadout: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            header("Charging", trailing: NowCardContent.timeToLimit(status), green: true)
            Button(action: openLiveCharge) {
                VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                    // The sparkline drops under the reading when both don't fit.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: VoltaSpacing.lg) {
                            powerReading(size: 52).fixedSize()
                            Spacer(minLength: 0)
                            sparkline.frame(minWidth: 80, maxWidth: 150)
                        }
                        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                            powerReading(size: 52)
                            sparkline.frame(maxWidth: .infinity)
                        }
                    }
                    if let line = NowCardContent.electrical(status) {
                        Text(line).font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(VoltaPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(liveChargeAccessibility)
            .accessibilityHint("Opens the live charging session")
            .accessibilityIdentifier("button.liveCharge")
        }
    }

    private var sparkline: some View {
        PowerSparkline(points: powerCurve)
            .frame(height: 50)
            .accessibilityHidden(true)
    }

    private var liveChargeAccessibility: String {
        ["Charging at \(NowCardContent.power(status.chargerPowerKw)) kilowatts",
         NowCardContent.timeToLimit(status), NowCardContent.electrical(status)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func powerReading(size: CGFloat) -> some View {
        NowNumber(value: NowCardContent.power(status.chargerPowerKw), unit: "kW", size: size, color: .voltaGreen)
    }

    private func electricalStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            let electrical = [status.chargerCurrentA.map { "\(VoltaFormat.number($0, digits: 0)) A" },
                              status.chargerVoltage.map { "\(VoltaFormat.number($0, digits: 0)) V" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !electrical.isEmpty { Text(electrical) }
            if let added = status.chargeEnergyAddedKwh {
                Text("+\(VoltaFormat.number(added, digits: 1)) kWh added")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.voltaTextSecondary)
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
    }

    private var limitRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Charge limit").font(.body).foregroundStyle(Color.voltaTextPrimary)
                Spacer(minLength: VoltaSpacing.md)
                ChargeLimitStepper(context: context)
            }
            VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                Text("Charge limit").font(.body).foregroundStyle(Color.voltaTextPrimary)
                ChargeLimitStepper(context: context)
            }
        }
    }

    /// The compact card's stepper with its label above it.
    private var labelledLimit: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.xs) {
            Text("Charge limit").font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                .accessibilityHidden(true)
            ChargeLimitStepper(context: context)
        }
        .fixedSize()
    }

    private var stopCharging: some View {
        commandButton("Stop Charging", .chargeStop)
    }

    /// The labelled stepper with Stop Charging beside it, or under it when
    /// they don't fit.
    private var limitAndStop: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: VoltaSpacing.md) {
                labelledLimit
                stopCharging
            }
            VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                labelledLimit
                stopCharging
            }
        }
    }

    // MARK: Plugged in

    private var pluggedIn: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
            header("Plugged in",
                   trailing: status.chargingState == .complete ? "Charge complete" : "Not charging", green: false)
            limitRow
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VoltaSpacing.md) { pluggedInActions }
                VStack(spacing: VoltaSpacing.md) { pluggedInActions }
            }
        }
    }

    @ViewBuilder private var pluggedInActions: some View {
        commandButton("Start Charging", .chargeStart, style: .accent)
        ForEach(ControlsView.chargePortCommands(doorOpen: status.chargePortDoorOpen), id: \.self) { command in
            commandButton(command == .openChargePort ? "Open Port" : "Close Port", command)
        }
    }

    // MARK: Parked

    @ViewBuilder private var parked: some View {
        if style == .compact {
            VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                parkedHeader
                // In one column the metric tiles are a screen below, so the
                // card carries the two temperatures itself.
                HStack(spacing: VoltaSpacing.xl) {
                    temperature("Cabin", status.insideTempC)
                    temperature("Outside", status.outsideTempC)
                    Spacer(minLength: 0)
                }
                climateAction(hugsTitle: false)
            }
        } else {
            // Beside or above the metric tiles the card is one row: how long
            // the car has sat, and the climate button at its own width.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VoltaSpacing.md) {
                    parkedDuration
                    Spacer(minLength: VoltaSpacing.sm)
                    climateAction(hugsTitle: true)
                }
                VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                    parkedHeader
                    climateAction(hugsTitle: false)
                }
            }
        }
    }

    private var parkedHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            header("Parked", trailing: parkedSince.map { "for \(Self.elapsed(from: $0, to: context.date))" },
                   green: false, color: Self.parkedText)
        }
    }

    /// "PARKED" over "for 1h 28m".
    private var parkedDuration: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: VoltaSpacing.xs) {
                headerTitle("Parked", green: false, color: Self.parkedText)
                if let parkedSince {
                    Text("for \(Self.elapsed(from: parkedSince, to: context.date))")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private func climateAction(hugsTitle: Bool) -> some View {
        switch status.climateOn {
        case true?: commandButton("Stop Climate", .climateOff, hugsTitle: hugsTitle)
        case false?: commandButton("Start Climate", .climateOn, hugsTitle: hugsTitle)
        case nil:
            ControlWideButton("Climate controls", systemImage: "fan", hugsTitle: hugsTitle, action: openControls)
                .accessibilityHint("Climate state unknown. Opens Controls")
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        VoltaFormat.duration(minutes: max(1, now.timeIntervalSince(start) / 60))
    }

    private func temperature(_ title: String, _ celsius: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(Color.voltaTextSecondary)
            NowNumber(value: celsius.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—",
                      unit: units.temperatureUnit, size: 30, color: .voltaTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Asleep or offline

    private func unreachable(_ state: VehicleState) -> some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                header(state.displayName,
                       trailing: "Last seen \(VoltaFormat.relativeDate(status.updatedAt, now: context.date))", green: false)
            }
            Text(state == .asleep
                 ? "Waking the car uses its battery and may take a minute."
                 : "The car is not connected. A wake request may not reach it.")
                .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            commandButton("Wake", .wakeUp)
        }
    }

    // MARK: Parts

    private func header(_ title: String, trailing: String?, green: Bool, color: Color? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                headerTitle(title, green: green, color: color)
                Spacer(minLength: VoltaSpacing.sm)
                if let trailing { headerTrailing(trailing) }
            }
            VStack(alignment: .leading, spacing: VoltaSpacing.xs) {
                headerTitle(title, green: green, color: color)
                if let trailing { headerTrailing(trailing) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func headerTitle(_ title: String, green: Bool, color: Color? = nil) -> some View {
        Text(title)
            .font(.system(.footnote, weight: .semibold))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(color ?? (green ? Color.voltaGreen : Color.voltaTextSecondary))
    }

    private func headerTrailing(_ text: String) -> some View {
        Text(text).font(.system(.body, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
    }

    private func commandButton(_ title: String, _ command: VehicleCommand,
                               style: ControlButton.Style = .neutral, hugsTitle: Bool = false) -> some View {
        let supported = context.supports(command)
        return ControlWideButton(title, style: style, isBusy: context.isSending(command),
                                 hugsTitle: hugsTitle) { perform(command) }
            .disabled(supported && !context.canStart(command))
            .accessibilityHint(supported ? "" : "Opens Controls")
    }
}

/// A large numeral with a unit, scaled with Dynamic Type.
struct NowNumber: View {
    var value: String
    var unit: String
    var color: Color
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 48
    @ScaledMetric(relativeTo: .title3) private var unitSize: CGFloat = 20

    init(value: String, unit: String, size: CGFloat, color: Color) {
        self.value = value
        self.unit = unit
        self.color = color
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
        _unitSize = ScaledMetric(wrappedValue: max(15, size * 0.42), relativeTo: .title3)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.02)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: unitSize, weight: .regular))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

/// The session's charging power as a small line with a soft fill, ending in a dot.
struct PowerSparkline: View {
    var points: [ChargeCurvePoint]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2, let first = points.first?.t, let last = points.last?.t,
                  last > first else { return }
            let span = last.timeIntervalSince(first)
            let peak = max(points.map(\.value).max() ?? 1, 0.1) * 1.1
            func point(_ p: ChargeCurvePoint) -> CGPoint {
                CGPoint(x: CGFloat(p.t.timeIntervalSince(first) / span) * (size.width - 6) + 1,
                        y: size.height - CGFloat(p.value / peak) * (size.height - 6) - 1)
            }
            for segment in Dictionary(grouping: points, by: \.segment).values {
                let ordered = segment.sorted { $0.t < $1.t }
                guard ordered.count >= 2 else { continue }
                var line = Path()
                line.addLines(ordered.map(point))
                var fill = line
                fill.addLine(to: CGPoint(x: point(ordered.last!).x, y: size.height))
                fill.addLine(to: CGPoint(x: point(ordered.first!).x, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Color.voltaGreen.opacity(0.28), Color.voltaGreen.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(.voltaGreen),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let end = points.max(by: { $0.t < $1.t }) {
                let p = point(end)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.voltaInk))
            }
        }
    }
}
