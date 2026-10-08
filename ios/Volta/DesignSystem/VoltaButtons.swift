import SwiftUI

// MARK: - PillButton

/// Raised dark rounded button: compact ("Open", "Flash") or full-width ("Vent").
///
///     PillButton("Open") { ... }
///     PillButton("Close", size: .wide) { ... }
///     PillButton("Retry", systemImage: "arrow.clockwise", style: .accent) { ... }
struct PillButton: View {
    enum Size { case compact, wide }
    enum Style { case neutral, accent }

    var title: String
    var systemImage: String?
    var size: Size
    var style: Style
    var isBusy: Bool
    var action: () -> Void

    init(_ title: String, systemImage: String? = nil, size: Size = .compact,
         style: Style = .neutral, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.style = style
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(.callout, weight: .medium))
            .foregroundStyle(style == .accent ? Color.white : Color.voltaTextPrimary)
            .frame(minWidth: size == .compact ? 84 : nil, maxWidth: size == .wide ? .infinity : nil)
            .padding(.horizontal, VoltaSpacing.lg)
            .padding(.vertical, size == .wide ? 15 : 10)
            .background {
                RoundedRectangle(cornerRadius: size == .wide ? VoltaRadius.wideButton : VoltaRadius.control,
                                 style: .continuous)
                    .fill(style == .accent ? Color.voltaBlue : Color.voltaRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: size == .wide ? VoltaRadius.wideButton : VoltaRadius.control,
                                         style: .continuous)
                            .strokeBorder(Color.voltaHairline, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(VoltaPressStyle())
    }
}

/// Subtle press feedback (dim + slight scale) used by Volta buttons.
struct VoltaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - SegmentedRangePicker

/// Text segments where the selected one sits in a dark capsule ("TODAY  7D  30D").
///
///     SegmentedRangePicker(selection: $range)                       // SummaryRange
///     SegmentedRangePicker(selection: $bucket, options: MileageBucketSize.allCases) { $0.rawValue }
struct SegmentedRangePicker<Option: Hashable>: View {
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String
    @Namespace private var ns

    init(selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option).uppercased())
                        .font(.system(.footnote, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(selected ? Color.voltaTextPrimary : Color.voltaTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                Capsule().fill(Color.voltaRaised)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

extension SegmentedRangePicker where Option == SummaryRange {
    init(selection: Binding<SummaryRange>) {
        self.init(selection: selection, options: SummaryRange.allCases) { $0.voltaLabel }
    }
}

extension SummaryRange {
    /// "Today", "7D", "30D".
    var voltaLabel: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        }
    }
}

// MARK: - Glass

/// Circular Liquid Glass button with an SF Symbol and optional red badge dot.
///
///     GlassCircleButton(systemImage: "bell.fill", badge: true) { ... }
///     GlassCircleButton(systemImage: "xmark", size: 52) { dismiss() }
struct GlassCircleButton: View {
    var systemImage: String
    var size: CGFloat = 50
    var badge: Bool = false
    var tint: Color = .voltaTextPrimary
    var accessibilityLabel: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay(alignment: .topTrailing) {
            if badge {
                Circle().fill(Color.voltaRed.opacity(0.9))
                    .frame(width: size * 0.2, height: size * 0.2)
                    .offset(x: -size * 0.12, y: size * 0.1)
            }
        }
        .accessibilityLabel(accessibilityLabel ?? systemImage)
    }
}

/// Capsule Liquid Glass container for grouped header buttons
/// (e.g. "[cal] 30D  [filter]" or "[search] [map]").
///
///     GlassPill { Button { } label: { Image(systemName: "magnifyingglass") } ... }
struct GlassPill<Content: View>: View {
    var height: CGFloat = 50
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: VoltaSpacing.xl) { content }
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(Color.voltaTextPrimary)
            .buttonStyle(.plain)
            .padding(.horizontal, VoltaSpacing.lg + 2)
            .frame(height: height)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - VoltaHeader

/// Screen header: leading control(s), centered title, trailing control(s).
/// Matches the history screens ("[30D ≡]   Charging   [⌕ ▢]").
///
///     VoltaHeader("Charging") { GlassPill { ... } } trailing: { GlassCircleButton(...) }
struct VoltaHeader<Leading: View, Trailing: View>: View {
    var title: String
    var leading: Leading
    var trailing: Trailing

    init(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.voltaScreenTitle)
                .foregroundStyle(Color.voltaTextPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                leading
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, VoltaSpacing.screen - 4)
        .frame(minHeight: 56)
    }
}

extension VoltaHeader where Leading == EmptyView {
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, leading: { EmptyView() }, trailing: trailing)
    }
}

#Preview("Buttons") {
    @Previewable @State var range: SummaryRange = .today
    VStack(spacing: 24) {
        VoltaHeader("Charging") {
            GlassPill {
                Label("30D", systemImage: "calendar").labelStyle(.titleAndIcon)
                Image(systemName: "line.3.horizontal.decrease")
            }
        } trailing: {
            GlassPill {
                Image(systemName: "magnifyingglass")
                Image(systemName: "map")
            }
        }
        HStack {
            GlassCircleButton(systemImage: "car.fill") {}
            Spacer()
            GlassCircleButton(systemImage: "bell.fill", badge: true) {}
        }
        SegmentedRangePicker(selection: $range)
        HStack { PillButton("Open") {}; PillButton("Flash") {} }
        HStack { PillButton("Vent", size: .wide) {}; PillButton("Close", size: .wide) {} }
        PillButton("Retry", systemImage: "arrow.clockwise", style: .accent) {}
    }
    .padding(VoltaSpacing.screen)
    .frame(maxHeight: .infinity, alignment: .top)
    .voltaScreenBackground()
    .preferredColorScheme(.dark)
}
