import SwiftUI

/// Private building blocks for Screens C (More, Settings, Analytics).
/// Namespaced so they never collide with `DesignSystem/` types; swap call
/// sites to DesignSystem components as they stabilize.
enum ScreenKit {
    static let background = Color.voltaBackground
    static let card = Color.voltaCard
    static let hairline = Color.voltaHairline
    static let secondary = Color.voltaTextSecondary
    static let tertiary = Color.voltaTextTertiary
    static let blue = Color.voltaBlue
    static let green = Color.voltaGreen
    static let amber = Color.voltaAmber
    static let red = Color.voltaRed
    /// Softer green used for VEHICLE-section icons, as in the references.
    static let mint = Color(red: 0x4A / 255, green: 0xC2 / 255, blue: 0x86 / 255)
    static let horizontalPadding = VoltaSpacing.screen
    static let bottomBarClearance = VoltaSpacing.tabBarClearance

    // MARK: Section header — "• AREAS" with a hairline underneath.

    struct SectionHeader: View {
        var title: String
        var dot: Color? = nil
        /// Optional accessibility identifier placed on the title text (a leaf).
        var identifier: String? = nil
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(ScreenKit.secondary)
                        .accessibilityIdentifier(identifier ?? "")
                }
                Rectangle().fill(ScreenKit.hairline).frame(height: 1)
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 28)
            .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Rows

    /// More-style row: icon, title, optional trailing value, chevron, divider.
    struct NavRow: View {
        var symbol: String
        var tint: Color
        var title: String
        var trailing: String? = nil
        var showsDivider = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 30)
                    Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                    }
                    Chevron()
                }
                .padding(.vertical, 20)
                .contentShape(Rectangle())
                if showsDivider { Rectangle().fill(ScreenKit.hairline).frame(height: 1) }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
        }
    }

    /// Settings-style row: icon, SMALL-CAPS title, gray subtitle, trailing badge, chevron.
    struct CapsRow: View {
        var symbol: String
        var tint: Color = ScreenKit.blue
        var title: String
        var subtitle: String
        var trailing: String? = nil
        var trailingTint: Color = .white
        var showsChevron = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title.uppercased())
                            .font(.system(size: 14, weight: .semibold)).tracking(2)
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(ScreenKit.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing.uppercased())
                            .font(.system(size: 14, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(trailingTint)
                    }
                    if showsChevron { Chevron() }
                }
                .padding(.vertical, 22)
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .contentShape(Rectangle())
                Rectangle().fill(ScreenKit.hairline).frame(height: 1)
            }
        }
    }

    struct Chevron: View {
        var body: some View {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ScreenKit.secondary)
        }
    }

    /// Key/value row used inside detail cards.
    struct ValueRow<Trailing: View>: View {
        var title: String
        var subtitle: String? = nil
        var showsDivider = true
        @ViewBuilder var trailing: Trailing
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                if showsDivider { Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, 16) }
            }
        }
    }

    // MARK: Containers

    /// Card with zero padding meant to hold `ValueRow`s.
    struct GroupCard<Content: View>: View {
        var title: String? = nil
        var footer: String? = nil
        @ViewBuilder var content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let title { SectionLabel(title).padding(.horizontal, 4) }
                VStack(spacing: 0) { content }
                    .voltaCardBackground()
                if let footer {
                    Text(footer).font(.system(size: 12)).foregroundStyle(ScreenKit.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// DesignSystem BigNumber that shrinks rather than wraps in tight tiles.
    struct Numeral: View {
        var value: String
        var unit: String? = nil
        var size: CGFloat = 34
        var body: some View {
            BigNumber(value, unit: unit, size: size)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    /// DesignSystem SegmentedRangePicker on a capsule track.
    struct Segmented<Value: Hashable>: View {
        var options: [(Value, String)]
        @Binding var selection: Value
        var body: some View {
            HStack {
                Spacer(minLength: 0)
                SegmentedRangePicker(selection: $selection, options: options.map(\.0)) { value in
                    options.first(where: { $0.0 == value })?.1 ?? ""
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(Color.voltaCard, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.voltaHairline, lineWidth: 1))
        }
    }

    /// Compact metric tile: label, numeral, unit, optional caption.
    struct Metric: View {
        var label: String
        var value: String
        var unit: String? = nil
        var caption: String? = nil
        var symbol: String? = nil
        var body: some View {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(ScreenKit.secondary)
                        }
                        Text(label).voltaLabelStyle()
                    }
                    Numeral(value: value, unit: unit, size: 28)
                    if let caption {
                        Text(caption).font(.system(size: 12)).foregroundStyle(ScreenKit.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// Thin capsule progress bar.
    struct ProgressBar: View {
        var fraction: Double
        var tint: Color = ScreenKit.blue
        var height: CGFloat = 6
        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint)
                        .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                        .shadow(color: tint.opacity(0.5), radius: 6)
                }
            }
            .frame(height: height)
        }
    }

}

// MARK: - Screen scaffolding

extension View {
    /// Dark background, hidden system bar, VoltaHeader with a glass back button.
    func screenKitPage(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        modifier(ScreenKitPage(title: title, trailing: trailing()))
    }
}

private struct ScreenKitPage<Trailing: View>: ViewModifier {
    var title: String
    var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                VoltaHeader(title) {
                    GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "Back") { dismiss() }
                } trailing: {
                    trailing
                }
                .padding(.bottom, VoltaSpacing.sm)
                .background {
                    LinearGradient(colors: [Color.voltaBackground, Color.voltaBackground.opacity(0.92), Color.voltaBackground.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .voltaScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Load state for screens that fetch once per vehicle.
enum Loadable<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? { if case .loaded(let v) = self { v } else { nil } }
}

/// Renders a `Loadable` with consistent loading and error chrome.
struct LoadableContent<Value: Sendable, Content: View>: View {
    var state: Loadable<Value>
    var retry: () async -> Void
    @ViewBuilder var content: (Value) -> Content
    var body: some View {
        switch state {
        case .loading:
            ProgressView().tint(ScreenKit.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 120)
        case .failed(let message):
            VStack(spacing: 16) {
                EmptyState(systemImage: "exclamationmark.icloud", title: "Couldn't load", message: message)
                Button("Try again") { Task { await retry() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ScreenKit.blue)
            }
        case .loaded(let value):
            content(value)
        }
    }
}

