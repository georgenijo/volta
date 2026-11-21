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
    static let horizontalPadding = VoltaSpacing.screen
    static let bottomBarClearance = VoltaSpacing.tabBarClearance

    // MARK: Section header — "Areas" with a hairline underneath.

    struct SectionHeader: View {
        var title: String
        /// Optional accessibility identifier placed on the title text (a leaf).
        var identifier: String? = nil
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .voltaLabelStyle()
                    .accessibilityIdentifier(identifier ?? "")
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
        var subtitle: String? = nil
        var trailing: String? = nil
        var showsDivider = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(.title3, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(.body, weight: .medium)).foregroundStyle(.voltaTextPrimary)
                        if let subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(ScreenKit.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.subheadline).foregroundStyle(ScreenKit.secondary)
                    }
                    Chevron()
                }
                .padding(.vertical, 16)
                .contentShape(Rectangle())
                if showsDivider { Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, 46) }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
        }
    }

    /// Settings-style row: icon, title, grey subtitle, trailing value, chevron.
    struct CapsRow: View {
        var symbol: String
        var tint: Color = ScreenKit.blue
        var title: String
        var subtitle: String
        var trailing: String? = nil
        var trailingTint: Color = ScreenKit.secondary
        var showsChevron = true
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(.title3, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.voltaTextPrimary)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(ScreenKit.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.subheadline)
                            .foregroundStyle(trailingTint)
                    }
                    if showsChevron { Chevron() }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .contentShape(Rectangle())
                Rectangle().fill(ScreenKit.hairline).frame(height: 1).padding(.leading, ScreenKit.horizontalPadding + 46)
            }
        }
    }

    struct Chevron: View {
        var body: some View {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ScreenKit.tertiary)
                .accessibilityHidden(true)
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
                        Text(title).font(.system(.callout, weight: .medium)).foregroundStyle(.voltaTextPrimary)
                        if let subtitle {
                            Text(subtitle).font(.footnote).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
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
                    Text(footer).font(.caption).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// DesignSystem BigNumber that shrinks rather than wraps in tight tiles.
    /// For a value that updates in place; its digits roll on change.
    struct Numeral: View {
        var value: String
        var unit: String? = nil
        var size: CGFloat = 34
        var weight: Font.Weight = .heavy
        var body: some View {
            BigNumber(value, unit: unit, size: size, weight: weight)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    /// A headline figure that rolls up from zero as it appears, then rolls to
    /// each new value. Nil is an em dash, never zero.
    ///
    ///     ScreenKit.RollingNumeral(value: 1234, digits: 0, unit: "mi", size: 52)
    struct RollingNumeral: View {
        var value: Double?
        var digits: Int = 0
        var unit: String? = nil
        var size: CGFloat = 34
        var weight: Font.Weight = .heavy
        /// Text before the number, such as "≥ " or "+".
        var prefix: String = ""
        var color: Color = .voltaTextPrimary
        @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 34

        init(value: Double?, digits: Int = 0, unit: String? = nil, size: CGFloat = 34,
             weight: Font.Weight = .heavy, prefix: String = "", color: Color = .voltaTextPrimary) {
            self.value = value
            self.digits = digits
            self.unit = unit
            self.size = size
            self.weight = weight
            self.prefix = prefix
            self.color = color
            _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
        }

        var body: some View {
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: max(2, scaledSize * 0.06)) {
                    RollingNumber(value: value) { prefix + VoltaFormat.number($0, digits: digits) }
                        .font(.system(size: scaledSize, weight: weight))
                        .tracking(-scaledSize * 0.03)
                        .foregroundStyle(color)
                    if let unit {
                        Text(unit)
                            .font(.system(size: max(12, scaledSize * 0.36), weight: .regular))
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .accessibilityElement(children: .combine)
            } else {
                Numeral(value: "—", unit: unit, size: size, weight: weight)
            }
        }
    }

    /// Text segments on a capsule track; the selected one sits in a raised
    /// capsule. Labels are written in sentence case ("30 days") and shown as
    /// written. A change of selection gives the selection haptic.
    struct Segmented<Value: Hashable>: View {
        var options: [(Value, String)]
        @Binding var selection: Value
        @Namespace private var ns
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    let selected = option.0 == selection
                    Button {
                        withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) { selection = option.0 }
                    } label: {
                        Text(option.1)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(selected ? Color.voltaTextPrimary : ScreenKit.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background {
                                if selected {
                                    Capsule().fill(Color.voltaRaised)
                                        .matchedGeometryEffect(id: "selection", in: ns)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.voltaCard, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.voltaHairline, lineWidth: 1))
            .voltaFeedback(.selection, trigger: selection)
        }
    }

    /// One reading inside a `MetricGroup`: label, value and unit, optional
    /// caption. Smaller than a card's headline, so the card keeps one big reading.
    struct Metric: View {
        var label: String
        var value: String
        var unit: String? = nil
        var caption: String? = nil
        var captionColor: Color = ScreenKit.secondary
        var symbol: String? = nil
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(ScreenKit.tertiary)
                            .accessibilityHidden(true)
                    }
                    Text(label).voltaLabelStyle()
                }
                Numeral(value: value, unit: unit, size: 24, weight: .bold)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(captionColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Secondary readings together in one card, two to a row, instead of a
    /// grid of identical tiles. An optional title names what they share.
    ///
    ///     ScreenKit.MetricGroup(title: "Energy and cost") { Metric(...); Metric(...) }
    struct MetricGroup<Content: View>: View {
        var title: String? = nil
        @ViewBuilder var content: Content
        var body: some View {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    if let title { SectionLabel(title) }
                    LazyVGrid(columns: ScreenKit.metricColumns, alignment: .leading, spacing: 18) { content }
                }
            }
        }
    }

}

// MARK: - Screen scaffolding

extension View {
    /// Dark background and system navigation: the system back button, and the
    /// title in the navigation bar while bars are horizontal. When iPhone Duo
    /// puts the bars on the side the title moves into the content, because a
    /// title would keep a horizontal bar alive. `screen` is the title's
    /// `screen.<name>` identifier for UI tests.
    func screenKitPage(_ title: String, screen: String? = nil) -> some View {
        modifier(ScreenKitPage(title: title, identifier: screen.map { "screen.\($0)" }))
    }
}

private struct ScreenKitPage: ViewModifier {
    var title: String
    var identifier: String?
    @Environment(\.barsOnSide) private var barsOnSide

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                if barsOnSide { ScreenKit.ContentTitle(title: title, identifier: identifier) }
            }
            .voltaScreenBackground()
            .navigationTitle(barsOnSide ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            // Keeps the dark backdrop visible under the bar; the system's scroll
            // edge effect still keeps the back button legible over content.
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if !barsOnSide {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.voltaScreenTitle)
                            .foregroundStyle(Color.voltaTextPrimary)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(identifier ?? "")
                    }
                }
            }
    }
}

extension ScreenKit {
    /// A page title drawn in the content, for windows whose bars are on the side.
    struct ContentTitle: View {
        var title: String
        var identifier: String?
        var body: some View {
            Text(title)
                .font(.voltaScreenTitle)
                .foregroundStyle(Color.voltaTextPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier ?? "")
                .frame(maxWidth: .infinity)
                .padding(.top, VoltaSpacing.sm)
                .padding(.bottom, VoltaSpacing.sm + 4)
                // Solid behind the title so scrolled content never shows
                // through it, then a short fade into the content.
                .background {
                    VStack(spacing: 0) {
                        Color.voltaBackground
                        LinearGradient(colors: [Color.voltaBackground, Color.voltaBackground.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                    }
                    .padding(.bottom, -14)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
        }
    }

    /// Body of a More page: one scrolling column capped at a readable width,
    /// or, when the page is regular width and wider than tall, two panes that
    /// scroll on their own. On iPhone Duo the panes stay clear of the fold and
    /// take one side each when the device is partly folded.
    ///
    /// `splits` false keeps one column, for loading, error and empty states.
    /// `scroll` is the `scroll.<name>` identifier, placed on the single column
    /// or on the primary pane.
    struct Page<Primary: View, Secondary: View>: View {
        var scroll: String? = nil
        var splits = true
        var spacing: CGFloat = 18
        @ViewBuilder var primary: Primary
        @ViewBuilder var secondary: Secondary

        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @State private var isWide = false

        var body: some View {
            Group {
                if splits && horizontalSizeClass == .regular && isWide {
                    VoltaPanes {
                        pane(identifier: scroll) { primary }
                    } secondary: {
                        pane(identifier: nil) { secondary }
                    }
                    .environment(\.inScreenKitPane, true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: spacing) {
                            primary
                            secondary
                        }
                        .modifier(PageInsets())
                    }
                    .accessibilityIdentifier(scroll.map { "scroll.\($0)" } ?? "")
                }
            }
            .onGeometryChange(for: Bool.self) { ScreenKit.isWide($0.size) } action: { isWide = $0 }
        }

        private func pane(identifier: String?, @ViewBuilder _ content: () -> some View) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) { content() }
                    .modifier(PageInsets())
            }
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier(identifier.map { "scroll.\($0)" } ?? "")
        }
    }

    /// True for a page wide enough to hold two panes of phone-width content.
    static func isWide(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= 640
    }

    /// Standard page padding plus the readable-width cap.
    struct PageInsets: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, ScreenKit.bottomBarClearance)
                .voltaReadableWidth()
        }
    }

    /// Two-column grid for metric tiles. An even count divides cleanly when
    /// the page sits on both sides of iPhone Duo's fold.
    static let metricColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
}

extension ScreenKit.Page where Secondary == EmptyView {
    /// A single-part page: always one readable column.
    init(scroll: String? = nil, spacing: CGFloat = 18, @ViewBuilder content: () -> Primary) {
        self.init(scroll: scroll, splits: false, spacing: spacing, primary: content, secondary: { EmptyView() })
    }
}

extension EnvironmentValues {
    /// True inside one pane of a two-pane `ScreenKit.Page`, so content such as
    /// a map can fill the pane instead of taking a fixed share of a column.
    @Entry var inScreenKitPane = false
}

/// Load state for screens that fetch once per vehicle.
enum Loadable<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? { if case .loaded(let v) = self { v } else { nil } }
}

/// Renders a `Loadable` with consistent loading and error chrome. While it
/// loads, the page's own layout is drawn as a skeleton: `placeholder` values
/// run through `content` when given, otherwise a generic card-and-rows shape.
/// A failure is an `ErrorState` with Try again.
struct LoadableContent<Value: Sendable, Content: View>: View {
    var state: Loadable<Value>
    var retry: () async -> Void
    var placeholder: Value? = nil
    var errorTitle = "Couldn't load"
    @ViewBuilder var content: (Value) -> Content

    init(state: Loadable<Value>, retry: @escaping () async -> Void, placeholder: Value? = nil,
         errorTitle: String = "Couldn't load", @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.retry = retry
        self.placeholder = placeholder
        self.errorTitle = errorTitle
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            Group {
                if let placeholder {
                    VStack(alignment: .leading, spacing: 18) { content(placeholder) }
                } else {
                    ScreenKit.SkeletonLayout()
                }
            }
            .voltaSkeleton(true)
        case .failed(let message):
            ErrorState(title: errorTitle, message: message, retry: retry)
                .padding(.top, 40)
        case .loaded(let value):
            content(value)
        }
    }
}

extension ScreenKit {
    /// The usual shape of a More page, for skeletons without sample values:
    /// a headline card and a card of rows.
    struct SkeletonLayout: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Loading reading").voltaLabelStyle()
                        Text("1,234 mi").font(.system(size: 48, weight: .heavy))
                        Text("Placeholder detail line").font(.subheadline)
                        RoundedRectangle(cornerRadius: 8).fill(Color.voltaTrack).frame(height: 120)
                    }
                }
                GroupCard(title: "Details") {
                    ForEach(0..<3, id: \.self) { index in
                        ValueRow(title: "Placeholder row", subtitle: "Detail", showsDivider: index < 2) {
                            Text("123 mi").font(.callout)
                        }
                    }
                }
            }
        }
    }
}

extension ScreenKit {
    /// Height for a map in a page: a share of the visible height in one column,
    /// or nearly the whole pane beside a list. Never a fixed phone height.
    struct MapHeight: ViewModifier {
        @Environment(\.inScreenKitPane) private var inPane
        func body(content: Content) -> some View {
            content.containerRelativeFrame(.vertical) { height, _ in
                inPane ? max(height - 80, 260) : min(max(height * 0.42, 220), 420)
            }
        }
    }
}
