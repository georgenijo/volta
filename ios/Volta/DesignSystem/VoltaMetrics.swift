import SwiftUI

// MARK: - BigNumber

/// Large heavy white numeral with a small gray unit suffix: "78 %", "276 mi".
/// The size follows Dynamic Type (scaled from `size` relative to .largeTitle).
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: max(2, scaledSize * 0.06)) {
            Text(value)
                .font(.system(size: scaledSize, weight: weight))
                .tracking(-scaledSize * 0.03)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(12, scaledSize * 0.36), weight: .regular))
                    .foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - GradientGauge

/// Thin horizontal gauge track with a colored gradient and an optional knob.
///
///     GradientGauge(value: 0.68)                                       // default cold→ok→hot
///     GradientGauge(value: 0.2, colors: [.voltaBlue, .voltaGreen], knob: .ring)
///     GradientGauge(value: nil)                                        // empty gray track ("no data")
struct GradientGauge: View {
    enum Knob { case filled(Color), ring, none }

    /// 0...1, or nil for an empty track.
    var value: Double?
    var colors: [Color] = GradientGauge.temperature
    var knob: Knob = .filled(.voltaAmber)
    /// Optional secondary marker (e.g. outside temp on the climate card).
    var secondaryValue: Double? = nil
    var height: CGFloat = 4

    static let temperature: [Color] = [.voltaBlue, .voltaBlue, .voltaGreen, .voltaGreen, .voltaRed, .voltaRed]
    static let daylight: [Color] = [Color(hex: 0x334155), .voltaAmber, .voltaAmber, Color(hex: 0xA855F7), Color(hex: 0x334155)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(value == nil ? AnyShapeStyle(Color.white.opacity(0.10))
                                       : AnyShapeStyle(LinearGradient(colors: colors.map { $0.opacity(0.85) },
                                                                      startPoint: .leading, endPoint: .trailing)))
                    .frame(height: height)
                if let secondaryValue {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 2)
                        .background(Circle().fill(Color.voltaCard))
                        .frame(width: 12, height: 12)
                        .offset(x: clamp(secondaryValue) * (w - 12))
                }
                if let value {
                    knobView
                        .offset(x: clamp(value) * (w - 20))
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
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.voltaCard, lineWidth: 3))
        case .ring:
            Circle().fill(Color.white)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.voltaCard, lineWidth: 3))
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.voltaTextSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(.voltaCardTitle)
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let badge, badge.inHeader {
                    Text(badge.text).voltaLabelStyle(color: badge.color)
                }
                if let headerAccessory { headerAccessory }
            }
            Spacer(minLength: VoltaSpacing.lg)
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value, unit: unit, size: 36)
                Spacer(minLength: 4)
                if let badge, !badge.inHeader {
                    Text(badge.text)
                        .font(.footnote.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(badge.color)
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
        VStack(spacing: VoltaSpacing.sm) {
            BigNumber(value, size: 34, weight: .bold)
            Text(caption)
                .font(.caption)
                .tracking(1.5)
                .foregroundStyle(Color.voltaTextSecondary)
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
