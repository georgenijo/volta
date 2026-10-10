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
    /// Soft mint for vehicle-section glyphs and positive accents.
    static let mint = Color.voltaMint
    static let horizontalPadding = VoltaSpacing.screen
    static let bottomBarClearance = VoltaSpacing.tabBarClearance
    /// Inset inside lit list cards.
    static let rowInset: CGFloat = 16
    /// Divider inset that starts at the row text, past the glyph tile.
    static let glyphDividerInset: CGFloat = 16 + 32 + 14 // rowInset + Glyph.size + 14

    // MARK: Section header — "• AREAS" caption above a lit card.

    struct SectionHeader: View {
        var title: String
        var dot: Color? = nil
        /// Optional accessibility identifier placed on the title text (a leaf).
        var identifier: String? = nil
        var trailing: String? = nil
        var body: some View {
            HStack(spacing: 8) {
                if let dot {
                    Circle().fill(dot).frame(width: 5, height: 5)
                        .shadow(color: dot.opacity(0.9), radius: 3)
                }
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(ScreenKit.tertiary)
                    .accessibilityIdentifier(identifier ?? "")
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(ScreenKit.tertiary)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding + 4)
            .padding(.top, 28)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Glyph

    /// Small tinted glyph on a faint tinted tile with a lit edge.
    struct Glyph: View {
        nonisolated static let size: CGFloat = 32
        var symbol: String
        var tint: Color
        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.size, height: Self.size)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        }
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: Rows

    /// More-style row for lit list cards: glyph tile, title, optional trailing value, chevron, divider.
    struct NavRow: View {
        var symbol: String
        var tint: Color
        var title: String
        var trailing: String? = nil
        var showsDivider = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Glyph(symbol: symbol, tint: tint)
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(ScreenKit.secondary)
                    }
                    Chevron()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, ScreenKit.rowInset)
                .contentShape(Rectangle())
                if showsDivider {
                    Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, ScreenKit.glyphDividerInset)
                }
            }
        }
    }

    /// Settings-style row for lit list cards: glyph tile, title, gray subtitle,
    /// trailing value (tinted, with a lit dot when not white), chevron.
    struct CapsRow: View {
        var symbol: String
        var tint: Color = ScreenKit.blue
        var title: String
        var subtitle: String
        var trailing: String? = nil
        var trailingTint: Color = .white
        var showsChevron = true
        var showsDivider = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Glyph(symbol: symbol, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ScreenKit.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        HStack(spacing: 6) {
                            if trailingTint != .white {
                                Circle().fill(trailingTint).frame(width: 5, height: 5)
                                    .shadow(color: trailingTint.opacity(0.9), radius: 3)
                            }
                            Text(trailing)
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(trailingTint == .white ? ScreenKit.secondary : trailingTint)
                        }
                        .fixedSize()
                    }
                    if showsChevron { Chevron() }
                }
                .padding(.vertical, 13)
                .padding(.horizontal, ScreenKit.rowInset)
                .contentShape(Rectangle())
                if showsDivider {
                    Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, ScreenKit.glyphDividerInset)
                }
            }
        }
    }

    struct Chevron: View {
        var body: some View {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScreenKit.tertiary)
        }
    }

    /// Lit card holding a run of `NavRow`/`CapsRow`s, inset to the screen gutter.
    struct ListCard<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View {
            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .voltaCardBackground(radius: 22)
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, ScreenKit.horizontalPadding)
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
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.vertical, 15)
                .padding(.horizontal, ScreenKit.rowInset)
                .contentShape(Rectangle())
                if showsDivider { Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, ScreenKit.rowInset) }
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
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(ScreenKit.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) { content }
                    .padding(.vertical, 2)
                    .voltaCardBackground(radius: 22)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                if let footer {
                    Text(footer).font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
            .padding(3)
            .background(Color.white.opacity(0.035), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
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
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(ScreenKit.secondary)
                        }
                        Text(label)
                            .font(.system(size: 10, weight: .semibold)).tracking(1.3).textCase(.uppercase)
                            .foregroundStyle(ScreenKit.tertiary).lineLimit(1)
                    }
                    Numeral(value: value, unit: unit, size: 26)
                    if let caption {
                        Text(caption).font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary).lineLimit(1)
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
                let width = max(height, proxy.size.width * min(1, max(0, fraction)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(tint).frame(width: width).blur(radius: 4).opacity(0.5)
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.65), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width)
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
                .voltaTopScrim()
            }
            .background(alignment: .top) { ScreenKit.TopGlow() }
            .voltaScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension ScreenKit {
    /// Top-right radial glow (blue 16% + mint 4%) shared with the Drives screen.
    struct TopGlow: View {
        var body: some View {
            VoltaTopGlow.gradient
                .frame(height: VoltaTopGlow.height)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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

