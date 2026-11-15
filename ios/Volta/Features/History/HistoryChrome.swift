import SwiftUI

// MARK: - Toolbar

// History screens put their controls in the system toolbar, so iPhone Duo can
// move them to the side strip with the tabs. Every item has a title and a
// symbol; the system shows the title in overflow menus and expanded forms.

/// Date range menu for a toolbar item: presets and a custom range.
struct HistoryRangeMenu: View {
    @Binding var range: HistoryRange
    /// In a horizontal bar the range shows as "30D" next to the calendar, as
    /// before. In the side strip only the symbol fits, so the content shows the range.
    var showsValue: Bool
    var customRange: () -> Void

    var body: some View {
        Menu {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.presets, id: \.self) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
            Divider()
            Button("Custom range…", systemImage: "calendar.badge.plus", action: customRange)
        } label: {
            if showsValue {
                Label(range.label, systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else {
                Label("Range, \(range.menuTitle)", systemImage: "calendar")
            }
        }
        .tint(Color.voltaTextPrimary)
        .accessibilityLabel("Date range, \(range.menuTitle)")
        .accessibilityIdentifier("button.history.range")
    }
}

/// Filter menu for a toolbar item; blue while a filter is applied.
struct HistoryFilterMenu<Content: View>: View {
    var isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Label(isActive ? "Filter, on" : "Filter",
                  systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .tint(isActive ? HistoryTheme.blue : Color.voltaTextPrimary)
        .accessibilityIdentifier("button.history.filter")
    }
}

/// A toolbar button with a title and a symbol; blue while `isOn`.
struct HistoryToolbarButton: View {
    var title: String
    var systemImage: String
    var isOn = false
    var identifier: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .contentTransition(.symbolEffect(.replace))
        }
        .tint(isOn ? HistoryTheme.blue : Color.voltaTextPrimary)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// The screen title in the bar while the bars are horizontal. With bars on
/// the side a title would keep a horizontal bar alive, so screens draw
/// `HistoryInlineTitle` in their content instead.
struct HistoryBarTitle: ToolbarContent {
    var title: String?
    var barsOnSide: Bool

    var body: some ToolbarContent {
        if !barsOnSide, let title {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.voltaScreenTitle)
                    .foregroundStyle(Color.voltaTextPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// The screen title drawn in the content while the bars are on the side.
struct HistoryInlineTitle: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.voltaTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(HistoryTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }
}

extension ToolbarContent {
    /// Keeps the most used items out of the overflow menu longest (iOS 27).
    @ToolbarContentBuilder
    func historyPriority(_ high: Bool = true) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(high ? .high : .low)
        } else {
            self
        }
    }
}

extension View {
    /// Pushed History page chrome: the system back button, the title in the
    /// bar while the bars are horizontal, and an optional clear bar over a map.
    func historyPage(_ title: String?, clearBar: Bool = false) -> some View {
        modifier(HistoryPageChrome(title: title, clearBar: clearBar))
    }

    /// The custom range sheet the range menu opens.
    func historyRangeSheet(isPresented: Binding<Bool>, range: Binding<HistoryRange>) -> some View {
        sheet(isPresented: isPresented) {
            CustomRangeSheet(range: range)
                .presentationDetents([.medium])
                .presentationBackground(HistoryTheme.card)
        }
    }

    /// Marks the row whose detail fills the second column of a split layout.
    func historySelected(_ isSelected: Bool, radius: CGFloat = 22) -> some View {
        overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HistoryTheme.blue.opacity(0.85), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HistoryPageChrome: ViewModifier {
    var title: String?
    var clearBar: Bool
    @Environment(\.barsOnSide) private var barsOnSide

    func body(content: Content) -> some View {
        content
            .historyScreenBackground()
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(clearBar ? .hidden : .automatic, for: .navigationBar)
            .toolbar { HistoryBarTitle(title: title, barsOnSide: barsOnSide) }
    }
}

// MARK: - Layout

enum HistoryLayout {
    /// Narrowest page that puts its map beside its content, so two panes keep
    /// a phone-like column each (the inner display with the list hidden).
    static let panesMinWidth: CGFloat = 700
    /// Narrowest page that lays cards in two columns.
    static let twoColumnMinWidth: CGFloat = 640
}

/// The window a History tab fills, measured once at the tab root.
struct HistoryWindow: Equatable {
    var size: CGSize = .zero
    var safeArea = EdgeInsets()

    /// Wider than tall (iPhone Duo's inner display opened flat).
    var isWide: Bool { size.width > size.height }
    /// Half the window, bars included: where the inner display folds.
    var half: CGFloat { (size.width + safeArea.leading + safeArea.trailing) / 2 }
    /// Height left between the top and bottom bars (`size` is already inside the safe area).
    var contentHeight: CGFloat { size.height }

    /// A hero map's visible height: a share of the content height inside
    /// `limits`, so a short window (the 678 pt outer display) still shows
    /// content below the map.
    func reveal(_ share: CGFloat, _ limits: ClosedRange<CGFloat>) -> CGFloat {
        guard contentHeight > 0 else { return limits.upperBound }
        return min(max(contentHeight * share, limits.lowerBound), limits.upperBound)
    }
}

extension EnvironmentValues {
    /// The side bars (iPhone Duo's strip) along this column's edges, from the
    /// tab's window. Scroll views with a hero map run under them and pad their
    /// text by these insets. Read from the tab, not from the page itself: a
    /// page that pads by its own insets changes them, and the layout loops.
    @Entry var historySideBars = EdgeInsets()
}

extension EdgeInsets {
    /// The horizontal edges that have a bar.
    var barEdges: Edge.Set {
        var edges: Edge.Set = []
        if leading > 0 { edges.insert(.leading) }
        if trailing > 0 { edges.insert(.trailing) }
        return edges
    }
}

extension View {
    /// Keeps content clear of the side bars inside a scroll view that runs
    /// under them so its hero map can (see `\.historySideBars`).
    func historySides(_ bars: EdgeInsets) -> some View {
        padding(.leading, bars.leading).padding(.trailing, bars.trailing)
    }

    /// Publishes the size and safe area of the space this view is given.
    /// Measured on a container that stays inside the safe area, so content
    /// that runs under the bars (and pads itself by these insets) can't feed
    /// back into the measurement.
    func readsHistoryWindow(_ window: Binding<HistoryWindow>) -> some View {
        ZStack { self }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: HistoryWindow.self) { proxy in
                HistoryWindow(size: proxy.size, safeArea: proxy.safeAreaInsets)
            } action: { window.wrappedValue = $0 }
    }
}

// MARK: - Navigation

/// A History tab's navigation: one split view that the system collapses into
/// a single stack in a compact window and expands to the list beside the
/// selection in a regular-width window wider than tall (the inner display
/// opened flat). A regular window taller than wide (the inner display
/// rotated) is told it is compact, so it stays a stack like a phone.
///
/// The hierarchy is the same in every layout, so folding and unfolding only
/// changes how it is shown: open pages keep their state, scroll position and
/// sheets. `path` holds everything open: its first route is the selection
/// (the detail column's root) and the rest is pushed on top of it.
struct HistoryNavigation<Route: Hashable, Root: View, Destination: View, Placeholder: View>: View {
    @Binding var path: [Route]
    var split: Bool
    /// The tab's window; the list column ends at its middle, where the inner
    /// display folds, so it keeps its width as the device folds and unfolds.
    var window: HistoryWindow
    @ViewBuilder var root: Root
    @ViewBuilder var destination: (Route) -> Destination
    @ViewBuilder var placeholder: Placeholder
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var sideBars: EdgeInsets {
        EdgeInsets(top: 0, leading: window.safeArea.leading, bottom: 0, trailing: window.safeArea.trailing)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: compactColumn) {
            root
                .navigationSplitViewColumnWidth(min: 320, ideal: max(320, window.half), max: max(320, window.half))
                // Beside the detail, the list column touches no side bar.
                .environment(\.historySideBars, split ? EdgeInsets() : sideBars)
                .environment(\.horizontalSizeClass, sizeClass)
        } detail: {
            NavigationStack(path: detailPath) {
                Group {
                    if let first = path.first {
                        // A new selection is a new page with fresh state.
                        destination(first).id(first)
                    } else {
                        placeholder.historyScreenBackground()
                    }
                }
                .navigationDestination(for: Route.self) { destination($0) }
            }
            // Beside the list, the detail column touches the trailing strip only.
            .environment(\.historySideBars, split
                         ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: window.safeArea.trailing) : sideBars)
            .environment(\.horizontalSizeClass, sizeClass)
        }
        .navigationSplitViewStyle(.balanced)
        // The split view collapses whenever it is told the width is compact.
        .environment(\.horizontalSizeClass, split ? .regular : .compact)
    }

    /// Collapsed, the stack shows the list until something is open. Going
    /// back past the selection closes it.
    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding {
            path.isEmpty ? .sidebar : .detail
        } set: { column in
            if column == .sidebar, !path.isEmpty { path = [] }
        }
    }

    /// What the detail column pushes on top of the selection.
    private var detailPath: Binding<[Route]> {
        Binding {
            Array(path.dropFirst())
        } set: { tail in
            path = Array(path.prefix(1)) + tail
        }
    }
}

extension Array where Element: Hashable {
    /// Opens a History route: pushed onto a stack, or the new selection of a split.
    mutating func historyOpen(_ route: Element, split: Bool) {
        if split { self = [route] } else { append(route) }
    }
}

/// The detail column before anything is selected.
struct HistorySelectionPlaceholder: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(HistoryTheme.tertiary)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(HistoryTheme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(VoltaSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screen.history-placeholder")
    }
}

/// An open page whose item is no longer in the loaded list (a refresh or a
/// new range dropped it): the selection's empty state, with page chrome.
struct HistoryMissingSelection: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        HistorySelectionPlaceholder(systemImage: systemImage, title: title, message: message)
            .historyPage(nil)
    }
}

private struct CustomRangeSheet: View {
    @Binding var range: HistoryRange
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HistorySectionLabel(title: "Custom range")
            DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
            DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
            Spacer()
            Button {
                range = .custom(from: from, to: to)
                dismiss()
            } label: {
                Text("Apply")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(HistoryTheme.blue)
        }
        .foregroundStyle(.white)
        .padding(24)
        .onAppear {
            if case .custom(let f, let t) = range { from = f; to = t }
        }
    }
}

// MARK: - Search

struct HistorySearchField: View {
    @Binding var text: String
    var prompt: String
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HistoryTheme.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .foregroundStyle(.white)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(HistoryTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button("Cancel") { text = ""; onClose() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HistoryTheme.blue)
                .buttonStyle(.plain)
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(HistoryTheme.card, in: .capsule)
        .overlay { Capsule().strokeBorder(HistoryTheme.hairline) }
        .padding(.horizontal, HistoryTheme.gutter)
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }
}

// MARK: - States

/// Empty state placed like the references: left-aligned, a little above
/// center, with an optional action underneath.
struct HistoryEmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            EmptyState(systemImage: systemImage, title: title, message: message)
            if let actionTitle, let action {
                PillButton(actionTitle, systemImage: "arrow.clockwise", action: action)
                    .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.bottom, 40)
    }
}

struct HistoryErrorState: View {
    var title: String
    var message: String
    var retry: () -> Void

    var body: some View {
        HistoryEmptyState(systemImage: "wifi.exclamationmark", title: title, message: message,
                          actionTitle: "Try again", action: retry)
    }
}

/// Pulsing placeholder blocks shown while the first page loads.
struct HistorySkeletonList: View {
    var rows: Int = 5
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            bar(width: 70, height: 26)
                            bar(width: 50, height: 9)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 14)
                bar(width: 80, height: 10).padding(.top, 8)
                ForEach(0..<rows, id: \.self) { _ in
                    HistoryCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Circle().fill(HistoryTheme.track).frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 7) {
                                    bar(width: 150, height: 13)
                                    bar(width: 100, height: 10)
                                }
                                Spacer()
                                bar(width: 46, height: 14)
                            }
                            bar(width: nil, height: 6)
                            HStack(spacing: 18) {
                                bar(width: 60, height: 11)
                                bar(width: 50, height: 11)
                                bar(width: 56, height: 11)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .scrollDisabled(true)
        // Only brightness pulses. Animating the whole ScrollView also animates
        // its initial layout and safe-area adjustments as the tab is mounted.
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { content in
            content.opacity(pulse ? 0.45 : 1)
        }
        .onAppear { pulse = true }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(HistoryTheme.track)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// Bottom of a paginated list. Loads the next page while visible.
///
/// The container's identity never depends on loading state; the load is keyed
/// on the feed's `paginationTrigger` (cursor + blocked), which does not change
/// when a request starts, so the request is never cancelled by its own state.
struct HistoryPageFooter<Item: Codable & Hashable & Sendable & Identifiable>: View {
    var feed: HistoryFeed<Item>
    /// Retries a failed pull-to-refresh (page errors retry in place).
    var retryRefresh: () async -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error = feed.footerError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(HistoryTheme.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task {
                        if feed.refreshError != nil { await retryRefresh() } else { await feed.retryLoadMore() }
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.blue)
                .buttonStyle(.plain)
            } else if feed.hasMore {
                ProgressView()
                    .tint(HistoryTheme.secondary)
                    .accessibilityLabel("Loading more")
            } else {
                Text("That's everything")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .task(id: feed.paginationTrigger) { await feed.loadMore() }
    }
}

// MARK: - Totals

/// Totals header: scope heading ("Last 30 days", or "Loaded drives — partial"
/// when more pages exist), the totals row and any coverage notes.
struct HistoryTotalsBlock: View {
    var title: String
    var isPartial: Bool
    var items: [HistoryTotalsRow.Item]
    var notes: [String] = []

    var body: some View {
        VStack(spacing: 12) {
            HistorySectionLabel(title: title, systemImage: isPartial ? "circle.dashed" : nil)
            HistoryTotalsRow(items: items)
            if !notes.isEmpty {
                VStack(spacing: 3) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(HistoryTheme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            HairlineDivider()
        }
        .padding(.top, 8)
    }
}
