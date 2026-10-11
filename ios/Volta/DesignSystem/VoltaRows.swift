import SwiftUI

// MARK: - ListRow

/// Icon + title + subtitle + trailing content + optional chevron.
/// Wrap in a `NavigationLink` or `Button` for interaction (the row is plain).
///
///     ListRow(systemImage: "bolt", title: "Supercharger", subtitle: "Today · 42 kWh",
///             showsChevron: true) { Text("$12.40") }
///     ListRow(systemImage: "gearshape", title: "Settings")
struct ListRow<Trailing: View>: View {
    var systemImage: String?
    var iconColor: Color
    var title: String
    var subtitle: String?
    var subtitleColor: Color
    var showsChevron: Bool
    var trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 36

    init(systemImage: String? = nil, iconColor: Color = .voltaTextPrimary.opacity(0.85),
         title: String, subtitle: String? = nil, subtitleColor: Color = .voltaTextSecondary,
         showsChevron: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.showsChevron = showsChevron
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: VoltaSpacing.lg) {
            if let systemImage {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.regular)
                    .foregroundStyle(iconColor)
                    .frame(width: iconWidth * 0.86, height: iconWidth * 0.72)
                    .frame(width: iconWidth)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.voltaRowTitle)
                    .foregroundStyle(Color.voltaTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.voltaRowSubtitle)
                        .foregroundStyle(subtitleColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.voltaTextTertiary)
            }
        }
        .padding(.vertical, VoltaSpacing.md + 2)
        .contentShape(Rectangle())
    }
}

extension ListRow where Trailing == EmptyView {
    init(systemImage: String? = nil, iconColor: Color = .voltaTextPrimary.opacity(0.85),
         title: String, subtitle: String? = nil, subtitleColor: Color = .voltaTextSecondary,
         showsChevron: Bool = false) {
        self.init(systemImage: systemImage, iconColor: iconColor, title: title, subtitle: subtitle,
                  subtitleColor: subtitleColor, showsChevron: showsChevron) { EmptyView() }
    }
}

// MARK: - ToggleRow

/// ListRow with a status word and a green switch ("Locked ◉").
/// When `isOn` is true the icon, subtitle, and status text turn `onColor`.
///
///     ToggleRow(systemImage: "lock.fill", title: "Doors", subtitle: "Lock & unlock",
///               status: "Locked", isOn: $locked)
struct ToggleRow: View {
    var systemImage: String
    var title: String
    var subtitle: String?
    var status: String?
    @Binding var isOn: Bool
    var onColor: Color = .voltaGreen
    /// Visually de-emphasized and non-interactive (e.g. commands unavailable).
    var isEnabled: Bool = true

    var body: some View {
        ListRow(systemImage: systemImage,
                iconColor: isOn ? onColor : .voltaTextPrimary.opacity(0.85),
                title: title, subtitle: subtitle,
                subtitleColor: isOn ? onColor : .voltaTextSecondary) {
            if let status {
                Text(status)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(isOn ? onColor : Color.voltaTextSecondary)
            }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(onColor)
                .disabled(!isEnabled)
        }
    }
}

#Preview("Rows") {
    @Previewable @State var locked = true
    @Previewable @State var climate = false
    VStack(spacing: 0) {
        ToggleRow(systemImage: "lock.fill", title: "Doors", subtitle: "Lock & unlock", status: "Locked", isOn: $locked)
        HairlineDivider(leadingInset: 52)
        ToggleRow(systemImage: "fan", title: "Climate", subtitle: "Precondition the cabin", status: "Off", isOn: $climate)
        HairlineDivider(leadingInset: 52)
        ListRow(systemImage: "thermometer.medium", title: "Climate controls", subtitle: "Seats, defrost & more", showsChevron: true)
        HairlineDivider(leadingInset: 52)
        ListRow(systemImage: "car.side.front.open", title: "Frunk", subtitle: "Front trunk") {
            PillButton("Open") {}
        }
    }
    .padding(VoltaSpacing.screen)
    .frame(maxHeight: .infinity, alignment: .top)
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
