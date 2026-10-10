import SwiftUI

// MARK: - BigNumber

/// Large white numeral with a small gray unit suffix: "78 %", "276 mi".
/// The size follows Dynamic Type (scaled from `size` relative to .largeTitle).
///
/// Bold and heavier weights render in the "Quiet instrument" hero style:
/// bold, expanded width, negative tracking, and (at hero sizes) a soft
/// white→white70% vertical gradient. Lighter weights stay regular width for
/// secondary numerals.
///
///     BigNumber("78", unit: "%", size: 84)
///     BigNumber("—", unit: "Wh/mi", size: 48)
struct BigNumber: View {
    var value: String
    var unit: String?
    var weight: Font.Weight
    var color: Color
    @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 48

    init(_ value: String, unit: String? = nil, size: CGFloat = 48,
         weight: Font.Weight = .heavy, color: Color = .voltaTextPrimary) {
        self.value = value
        self.unit = unit
        self.weight = weight
        self.color = color
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    /// Bold, heavy and black all map to the expanded hero treatment.
    private var isHero: Bool { weight == .heavy || weight == .bold || weight == .black }

    private var fill: AnyShapeStyle {
        if isHero && color == .voltaTextPrimary && scaledSize >= 40 {
            return AnyShapeStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(color)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: max(2, scaledSize * 0.06)) {
            Text(value)
                .font(.system(size: scaledSize, weight: isHero ? .bold : weight))
                .fontWidth(isHero ? .expanded : .standard)
                .tracking(isHero ? -scaledSize * 0.028 : -scaledSize * 0.01)
                .foregroundStyle(fill)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, scaledSize * (isHero ? 0.26 : 0.36)), weight: .medium))
                    .foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - GradientGauge

/// Thin luminous gauge: a faint full-width track, the filled portion drawn as
/// light (gradient + soft glow) up to the value, and an optional knob.
///
///     GradientGauge(value: 0.68)                                       // default cold→ok→hot
///     GradientGauge(value: 0.2, colors: GradientGauge.energy, knob: .ring)
///     GradientGauge(value: nil)                                        // empty gray track ("no data")
struct GradientGauge: View {
    enum Knob { case filled(Color), ring, none }

    /// 0...1, or nil for an empty track.
    var value: Double?
    var colors: [Color] = GradientGauge.temperature
    var knob: Knob = .filled(.voltaAmber)
    /// Optional secondary marker (e.g. outside temp on the climate card).
    var secondaryValue: Double? = nil
    var height: CGFloat = 3

    /// Cold (blue) → comfortable (mint) → hot (amber/red).
    static let temperature: [Color] = [.voltaBlue, .voltaMint, .voltaMint, .voltaAmber, .voltaRed]
    /// Energy / route data: mint → blue.
    static let energy: [Color] = [.voltaMint, .voltaBlue]
    static let daylight: [Color] = [Color(hex: 0x334155), .voltaAmber, .voltaAmber, Color(hex: 0xA855F7), Color(hex: 0x334155)]

    private let knobSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let line = min(height, 3.5)
            let gradient = LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .leading) {
                if let value {
                    // Whole scale, faint, so the lit part reads against context.
                    Capsule().fill(gradient).opacity(0.18).frame(height: line)
                    let lit = max(line, clamp(value) * w)
                    Group {
                        Capsule().fill(gradient).frame(width: w, height: line + 3)
                            .blur(radius: 4).opacity(0.55)
                        Capsule().fill(gradient).frame(width: w, height: line)
                    }
                    .frame(width: w, alignment: .leading)
                    .mask(alignment: .leading) { Rectangle().frame(width: lit) }
                } else {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: line)
                }
                if let secondaryValue {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                        .background(Circle().fill(Color.voltaCard))
                        .frame(width: 10, height: 10)
                        .offset(x: clamp(secondaryValue) * (w - 10))
                }
                if let value {
                    knobView
                        .offset(x: clamp(value) * (w - knobSize))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var knobView: some View {
        switch knob {
        case .filled(let color):
            Circle().fill(color)
                .frame(width: knobSize, height: knobSize)
                .overlay(Circle().strokeBorder(Color.voltaCard, lineWidth: 2.5))
                .shadow(color: color.opacity(0.7), radius: 5)
        case .ring:
            Circle().fill(Color.white)
                .frame(width: knobSize, height: knobSize)
                .overlay(Circle().strokeBorder(Color.voltaCard, lineWidth: 2.5))
                .shadow(color: .white.opacity(0.35), radius: 4)
        case .none:
            EmptyView()
        }
    }

    private func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
}

// MARK: - MetricCard

/// Dashboard tile: icon + small-caps title (+ optional trailing badge), a big
/// numeral with unit, an optional right-side accessory, and a gauge.
///
///     MetricCard(systemImage: "thermometer.medium", title: "Pack Temp",
///                value: "96", unit: "°F",
///                badge: .init(text: "WARM", color: .voltaAmber),
///                gauge: GradientGauge(value: 0.68), tint: .voltaAmber)
///
///     MetricCard(systemImage: "leaf", title: "30D Eff", value: "—", unit: "Wh/mi",
///                gauge: GradientGauge(value: nil)) {
///         // optional accessory shown to the right of the numeral
///     }
struct MetricCard<Accessory: View>: View {
    struct Badge {
        var text: String
        var color: Color = .voltaTextSecondary
        /// Show the badge in the header row (e.g. "OFF") rather than beside the numeral (e.g. "WARM").
        var inHeader: Bool = false
    }

    var systemImage: String
    var title: String
    var value: String
    var unit: String?
    var badge: Badge?
    var headerAccessory: AnyView?
    var gauge: GradientGauge?
    var tint: Color?
    var accessory: Accessory

    init(systemImage: String, title: String, value: String, unit: String? = nil,
         badge: Badge? = nil, headerAccessory: AnyView? = nil,
         gauge: GradientGauge? = nil, tint: Color? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.unit = unit
        self.badge = badge
        self.headerAccessory = headerAccessory
        self.gauge = gauge
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VoltaSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint ?? Color.voltaTextSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let badge, badge.inHeader {
                    Text(badge.text)
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(badge.color == .voltaTextSecondary ? Color.voltaTextTertiary : badge.color)
                }
                if let headerAccessory { headerAccessory }
            }
            Spacer(minLength: VoltaSpacing.lg)
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value, unit: unit, size: 32)
                Spacer(minLength: 4)
                if let badge, !badge.inHeader {
                    HStack(spacing: 5) {
                        Circle().fill(badge.color).frame(width: 5, height: 5)
                            .shadow(color: badge.color.opacity(0.8), radius: 3)
                        Text(badge.text)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(badge.color)
                    }
                }
                accessory
            }
            if let gauge {
                gauge.padding(.top, VoltaSpacing.sm)
            }
        }
        .padding(VoltaSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .voltaCardBackground(tint: tint)
        .accessibilityElement(children: .combine)
    }
}

extension MetricCard where Accessory == EmptyView {
    init(systemImage: String, title: String, value: String, unit: String? = nil,
         badge: Badge? = nil, headerAccessory: AnyView? = nil,
         gauge: GradientGauge? = nil, tint: Color? = nil) {
        self.init(systemImage: systemImage, title: title, value: value, unit: unit,
                  badge: badge, headerAccessory: headerAccessory, gauge: gauge, tint: tint) { EmptyView() }
    }
}

/// Small centered stat: numeral over a small-caps caption ("0 / MI").
///
///     StatColumn(value: "12", caption: "mi")
struct StatColumn: View {
    var value: String
    var caption: String
    var body: some View {
        VStack(spacing: 6) {
            BigNumber(value, size: 30, weight: .bold)
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .textCase(.uppercase)
                .foregroundStyle(Color.voltaTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Metrics") {
    ScrollView {
        VStack(spacing: 16) {
            HStack { BigNumber("78", unit: "%", size: 84); Spacer(); BigNumber("276", unit: "mi", size: 30, weight: .semibold) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                MetricCard(systemImage: "minus.plus.batteryblock", title: "Pack Temp", value: "96", unit: "°F",
                           badge: .init(text: "WARM", color: .voltaAmber),
                           gauge: GradientGauge(value: 0.68), tint: .voltaAmber)
                MetricCard(systemImage: "leaf", title: "30D Eff", value: "—", unit: "Wh/mi",
                           gauge: GradientGauge(value: nil))
                MetricCard(systemImage: "fan", title: "Climate", value: "57", unit: "°F",
                           badge: .init(text: "OFF", inHeader: true),
                           gauge: GradientGauge(value: 0.28, knob: .ring, secondaryValue: 0.19), tint: .voltaGreen) {
                    Text("OUT 48°").font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                }
                MetricCard(systemImage: "cloud.sun", title: "Weather", value: "43", unit: "°F",
                           gauge: GradientGauge(value: 0.05, colors: GradientGauge.daylight, knob: .ring), tint: .voltaBlue) {
                    Image(systemName: "cloud.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                }
            }
            HStack { StatColumn(value: "0", caption: "MI"); StatColumn(value: "0", caption: "CHARGES"); StatColumn(value: "—", caption: "Wh/mi") }
        }
        .padding(VoltaSpacing.screen)
    }
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
