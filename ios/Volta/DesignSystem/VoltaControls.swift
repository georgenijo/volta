import SwiftUI

// Grouped control rows shared by Controls and the Dashboard: 56 pt rows in a
// card with hairline dividers, 36 pt visible buttons inside 44 pt hit
// regions, 44 pt stepper segments, and two-up rows that stack when narrow.

// MARK: - Group

/// "ACCESS" label over a card whose rows are separated by hairlines.
struct ControlGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm + 2) {
            if let title {
                Text(title)
                    .voltaLabelStyle()
                    .padding(.leading, VoltaSpacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { HairlineDivider() }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground(radius: VoltaRadius.card)
            .clipShape(.rect(cornerRadius: VoltaRadius.card, style: .continuous))
        }
    }
}

// MARK: - Row

/// Icon, title and state on the left; trailing controls on the right. At
/// accessibility text sizes, or when the row is too narrow, the trailing
/// controls move under the text so state never truncates.
struct ControlRow<Trailing: View>: View {
    var systemImage: String?
    var iconColor: Color = .voltaTextPrimary.opacity(0.85)
    var title: String
    var subtitle: String?
    var subtitleColor: Color = .voltaTextSecondary
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                    label
                    // Side by side, or one above another when they don't fit.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: VoltaSpacing.sm) { trailing }
                        VStack(alignment: .leading, spacing: VoltaSpacing.sm) { trailing }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: VoltaSpacing.sm) {
                        label
                        Spacer(minLength: 0)
                        trailing
                    }
                    VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                        label
                        HStack(spacing: VoltaSpacing.sm) { trailing }
                            .padding(.leading, systemImage == nil ? 0 : iconWidth + VoltaSpacing.md)
                    }
                }
            }
        }
        .padding(.horizontal, VoltaSpacing.lg)
        .padding(.vertical, VoltaSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: VoltaSpacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(minWidth: iconWidth)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Color.voltaTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ControlRow where Trailing == EmptyView {
    init(systemImage: String? = nil, iconColor: Color = .voltaTextPrimary.opacity(0.85), title: String,
         subtitle: String? = nil, subtitleColor: Color = .voltaTextSecondary) {
        self.init(systemImage: systemImage, iconColor: iconColor, title: title, subtitle: subtitle,
                  subtitleColor: subtitleColor) { EmptyView() }
    }
}

// MARK: - Button

/// A raised 36 pt button ("Open", "Vent", "Flash") inside a 44 pt hit region.
struct ControlButton: View {
    enum Style { case neutral, accent }
    var title: String
    var style: Style = .neutral
    var isBusy = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, style: Style = .neutral, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy { ProgressView().controlSize(.small).tint(.white) }
                Text(title).opacity(isBusy ? 0 : 1)
            }
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(Color.voltaTextPrimary)
            .lineLimit(1)
            .padding(.horizontal, VoltaSpacing.md + 2)
            .frame(minWidth: 64, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .accent ? Color.voltaBlueFill : Color.voltaRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
            // The visible button is 36 pt; the tap target is at least 44 pt.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(VoltaPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A full-width 52 pt action ("Stop Charging", "Start Climate").
struct ControlWideButton: View {
    var title: String
    var systemImage: String?
    var style: ControlButton.Style = .neutral
    var isBusy = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String? = nil, style: ControlButton.Style = .neutral,
         isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: VoltaSpacing.sm) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(Color.voltaTextPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, VoltaSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous)
                    .fill(style == .accent ? Color.voltaBlueFill : Color.voltaRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(VoltaPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Stepper

/// "−  80%  +" with 44 pt segments. VoiceOver reads it as one adjustable
/// element ("Charge limit, 80 percent").
struct ValueStepper: View {
    var label: String
    var value: String
    var accessibilityValue: String
    var canDecrease: Bool
    var canIncrease: Bool
    var decrease: () -> Void
    var increase: () -> Void
    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 0) {
            segment("minus", enabled: canDecrease, action: decrease)
            Text(value)
                .font(.system(.title3, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(canDecrease || canIncrease ? Color.voltaTextPrimary : Color.voltaTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: valueWidth)
            segment("plus", enabled: canIncrease, action: increase)
        }
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous)
                .fill(Color.voltaRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { increase() }
            case .decrement: if canDecrease { decrease() }
            @unknown default: break
            }
        }
    }

    private func segment(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary.opacity(enabled ? 1 : 0.35))
                .frame(minWidth: 48, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(VoltaPressStyle())
        .disabled(!enabled)
    }
}

// MARK: - Two-up

/// Two half-width rows side by side with a hairline between them, stacked
/// as full-width rows when they don't fit (a half-folded pane or large text).
struct TwoUpRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    leading.frame(maxWidth: .infinity)
                    Rectangle().fill(Color.voltaHairline).frame(width: 1)
                    trailing.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(spacing: 0) {
            leading
            HairlineDivider()
            trailing
        }
    }
}

/// A compact half of a two-up row: icon, title and one button.
struct HalfControl: View {
    var systemImage: String
    var title: String
    var button: String
    var accessibilityLabel: String
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // The button goes under the title, as in `ControlRow`.
            ControlRow(systemImage: systemImage, title: title) {
                ControlButton(button, action: action)
                    .accessibilityLabel(accessibilityLabel)
            }
        } else {
            inline
        }
    }

    private var inline: some View {
        HStack(spacing: VoltaSpacing.sm) {
            HStack(spacing: VoltaSpacing.md) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Color.voltaTextPrimary.opacity(0.85))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Color.voltaTextPrimary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            ControlButton(button, action: action)
                .accessibilityLabel(accessibilityLabel)
        }
        .padding(.horizontal, VoltaSpacing.lg)
        .padding(.vertical, VoltaSpacing.sm)
        .frame(minHeight: 56)
    }
}

#Preview("Controls kit") {
    ScrollView {
        VStack(spacing: 24) {
            ControlGroup(title: "Access") {
                ControlRow(systemImage: "lock.fill", title: "Doors", subtitle: "Locked") {
                    ControlButton("Unlock") {}
                }
                TwoUpRow {
                    HalfControl(systemImage: "car.side.front.open", title: "Frunk", button: "Open", accessibilityLabel: "Open frunk") {}
                } trailing: {
                    HalfControl(systemImage: "car.side.rear.open", title: "Trunk", button: "Open", accessibilityLabel: "Open trunk") {}
                }
                ControlRow(title: "Charge limit", subtitle: "72% now") {
                    ValueStepper(label: "Charge limit", value: "80%", accessibilityValue: "80 percent",
                                 canDecrease: true, canIncrease: true, decrease: {}, increase: {})
                }
            }
            ControlWideButton("Stop Charging") {}
        }
        .padding(20)
    }
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
