import SwiftUI

enum DriveFilter: String, CaseIterable, Identifiable {
    case all, short, medium, long
    var id: String { rawValue }

    /// Bucket edges in km (≈10 mi and ≈50 mi).
    static let shortKm = 16.0934
    static let longKm = 80.4672

    func title(_ units: UnitPreferences) -> String {
        let s = VoltaFormat.number(units.distanceValue(km: Self.shortKm), digits: 0)
        let l = VoltaFormat.number(units.distanceValue(km: Self.longKm), digits: 0)
        let u = units.distanceUnit
        return switch self {
        case .all: "Any distance"
        case .short: "Under \(s) \(u)"
        case .medium: "\(s)–\(l) \(u)"
        case .long: "Over \(l) \(u)"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .short: "building.2"
        case .medium: "road.lanes"
        case .long: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    func matches(_ drive: DriveSummary) -> Bool {
        switch self {
        case .all: true
        case .short: drive.distanceKm < Self.shortKm
        case .medium: drive.distanceKm >= Self.shortKm && drive.distanceKm <= Self.longKm
        case .long: drive.distanceKm > Self.longKm
        }
    }
}

enum DriveSort: String, CaseIterable, Identifiable {
    case newest, longest, mostEfficient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest first"
        case .longest: "Longest first"
        case .mostEfficient: "Most efficient first"
        }
    }
}

extension DriveSummary {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [startAddress, endAddress, startCity, endCity].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var batteryUsed: Int? {
        guard let s = startBatteryLevel, let e = endBatteryLevel else { return nil }
        return s - e
    }

    /// Efficiency tint relative to a typical Model Y (~165 Wh/km is average).
    var efficiencyTint: Color {
        guard let e = displayEfficiencyWhPerKm else { return HistoryTheme.secondary }
        return e < 140 ? HistoryTheme.green : e < 190 ? HistoryTheme.blue : HistoryTheme.amber
    }
}

/// Where the Drives tab can navigate.
enum DriveRoute: Hashable {
    case drive(DriveSummary)
    case roadtrips
    case heatmap
}

/// Drives tab: range and filter menus, search, route map, day-grouped drive
/// cards. On a wide regular-width window the list and the selected drive sit
/// side by side.
struct DrivesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.barsOnSide) private var barsOnSide
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var model: AppModel?

    @State private var feed = HistoryFeed<DriveSummary>()
    @State private var range: HistoryRange
    @State private var filter: DriveFilter = .all
    @State private var sort: DriveSort = .newest
    @State private var searching = false
    @State private var query = ""
    @State private var path: [DriveRoute] = []
    @State private var showingCustomRange = false
    /// The whole tab, which decides between a stack and a split.
    @State private var window = HistoryWindow()
    /// The list's own area, inside the system bars.
    @State private var page = HistoryWindow()

    init(range: HistoryRange = .all) {
        _range = State(initialValue: range)
    }

    private var split: Bool { sizeClass == .regular && window.isWide }
    /// Side bars along the list's edges: none in a split, whose list column touches no bar.
    private var sideBars: EdgeInsets {
        split ? EdgeInsets() : EdgeInsets(top: 0, leading: window.safeArea.leading, bottom: 0, trailing: window.safeArea.trailing)
    }

    private var visible: [DriveSummary] { Self.visible(feed.items, filter: filter, query: query, sort: sort) }

    /// The rows the list shows, and the set the hero totals: filter and search applied.
    static func visible(_ items: [DriveSummary], filter: DriveFilter, query: String, sort: DriveSort) -> [DriveSummary] {
        let items = items.filter { filter.matches($0) && $0.matches(query: query) }
        switch sort {
        case .newest: return items
        case .longest: return items.sorted { $0.distanceKm > $1.distanceKm }
        case .mostEfficient: return items.sorted { ($0.displayEfficiencyWhPerKm ?? .infinity) < ($1.displayEfficiencyWhPerKm ?? .infinity) }
        }
    }

    private var selected: DriveRoute? { split ? path.first : nil }

    var body: some View {
        HistoryNavigation(path: $path, split: split, window: window) {
            root
        } destination: { route in
            switch route {
            case .drive(let drive): DriveDetailView(drive: drive)
            case .roadtrips: RoadtripsView(drives: visible, partial: feed.hasMore)
            case .heatmap: DrivesHeatmapView(drives: visible, partial: feed.hasMore)
            }
        } placeholder: {
            HistorySelectionPlaceholder(systemImage: "steeringwheel", title: "No drive selected",
                                        message: "Choose a drive to see its route, charts and cost.")
        }
        .readsHistoryWindow($window)
        .task(id: range) { await reload(skeleton: true) }
    }

    private var root: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .readsHistoryWindow($page)
            .safeAreaInset(edge: .top, spacing: 0) {
                if searching {
                    HistorySearchField(text: $query, prompt: "Search cities or addresses") {
                        withAnimation(.snappy) { searching = false }
                    }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .historyScreenBackground()
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .historyRangeSheet(isPresented: $showingCustomRange, range: $range)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        HistoryBarTitle(title: "Drives", barsOnSide: barsOnSide)
        ToolbarItemGroup(placement: .topBarLeading) {
            HistoryRangeMenu(range: $range, showsValue: !barsOnSide) { showingCustomRange = true }
            HistoryFilterMenu(isActive: filter != .all || sort != .newest) {
                Picker("Distance", selection: $filter) {
                    ForEach(DriveFilter.allCases) { f in
                        Label(f.title(units), systemImage: f.systemImage).tag(f)
                    }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(DriveSort.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .historyPriority()
        ToolbarItemGroup(placement: .topBarTrailing) {
            HistoryToolbarButton(title: "Search", systemImage: "magnifyingglass", isOn: searching,
                                 identifier: "button.history.search") {
                withAnimation(.snappy) { searching.toggle(); if !searching { query = "" } }
            }
        }
    }

    private func open(_ route: DriveRoute) { path.historyOpen(route, split: split) }

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.drives(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    /// The title in the content while the bars are on the side.
    @ViewBuilder private var inlineTitle: some View {
        if barsOnSide {
            HistoryInlineTitle(title: "Drives", subtitle: range.menuTitle)
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.top, VoltaSpacing.sm)
        }
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList().safeAreaInset(edge: .top, spacing: 0) { inlineTitle }
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load drives", message: message) {
                Task { await reload(skeleton: true) }
            }
            .safeAreaInset(edge: .top, spacing: 0) { inlineTitle }
        case .loaded:
            list
        }
    }

    /// Status bar plus system bar and search: how far the hero map reaches up behind them.
    @State private var topInset: CGFloat = 0

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                let mapped = visible.contains { drive in DriveRouteSegments.runs(drive.drawableRoute).contains { $0.count > 1 } }
                if mapped {
                    let reveal = page.reveal(0.23, 150...180)
                    DrivesRouteMap(drives: visible, height: reveal + topInset, fullBleed: true,
                                   topInset: topInset + (barsOnSide ? 40 : 0), legalInset: 56)
                        .padding(.top, -topInset)
                        .allowsHitTesting(false)
                        .overlay(alignment: .topLeading) { inlineTitle.historySides(sideBars) }
                } else {
                    inlineTitle.historySides(sideBars)
                }
                Group {
                    hero.padding(.horizontal, DrivesLayout.margin)
                        .padding(.top, mapped ? -6 : 18).padding(.bottom, 40)
                    HStack(spacing: 13) {
                        Button { open(.roadtrips) } label: { DriveShortcut(title: "Roadtrips", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                            .historySelected(selected == .roadtrips, radius: 17)
                            .accessibilityIdentifier("button.drives.roadtrips")
                        Button { open(.heatmap) } label: { DriveShortcut(title: "Heatmap", systemImage: "square.grid.3x3.fill") }
                            .historySelected(selected == .heatmap, radius: 17)
                            .accessibilityIdentifier("button.drives.heatmap")
                    }.buttonStyle(VoltaPressStyle()).padding(.horizontal, DrivesLayout.margin).padding(.bottom, 15)
                    if visible.isEmpty && !feed.hasMore {
                        HistoryEmptyState(systemImage: "road.lanes", title: feed.items.isEmpty ? "No drives \(range.emptyPhrase ?? "yet")" : "No matching drives",
                                          message: feed.items.isEmpty ? "Try a different range or wait for your next drive." : "Try a different search or distance filter.")
                            .padding(.horizontal, HistoryTheme.gutter)
                    }
                }
                .voltaReadableWidth()
                .historySides(sideBars)
                if sort == .newest {
                    ForEach(DayGroup.group(visible, by: \.start)) { group in
                        Section {
                            rows(group.items).padding(.bottom, 14)
                        } header: {
                            DriveDayHeader(group: group, sides: sideBars)
                        }
                    }
                } else {
                    SectionLabel(sort.title, trailing: "\(visible.count) drives")
                        .padding(.horizontal, DrivesLayout.margin)
                        .padding(.top, 14).padding(.bottom, 12)
                        .voltaReadableWidth()
                        .historySides(sideBars)
                    rows(visible)
                }
                HistoryPageFooter(feed: feed) { await reload() }
                    .padding(.horizontal, HistoryTheme.gutter)
                    .historySides(sideBars)
            }
        }
        // Under the side bars, so the route map reaches the edges; the rest keeps clear of them.
        .ignoresSafeArea(edges: sideBars.barEdges)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in topInset = inset }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.drives")
        .refreshable { await reload() }
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        VStack(spacing: 9) {
            ForEach(items) { drive in
                Button { open(.drive(drive)) } label: {
                    DriveCard(drive: drive, showsDate: sort != .newest).historySelected(selected == .drive(drive), radius: 18)
                }
                .buttonStyle(VoltaPressStyle())
                .accessibilityIdentifier("row.drive.\(drive.id)")
            }
        }
        .padding(.horizontal, DrivesLayout.cardInset)
        .voltaReadableWidth()
        .historySides(sideBars)
    }

    /// Totals follow the active filter and search, like the list below them.
    private var hero: some View {
        let drives = visible
        return DrivesHero(scope: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "drives"),
                          totals: DriveTotals(drives), durationMin: drives.reduce(0) { $0 + $1.durationMin },
                          cost: DrivePricing.total(drives, home: model?.settings.rates.homeTripRate),
                          partial: feed.hasMore)
    }

}

// MARK: - Row

struct DriveRow: View {
    var drive: DriveSummary
    var showsDate = false
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model: AppModel?
    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    DriveRouteThumbnail(points: drive.drawableRoute).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(drive.startPlace + " → " + drive.endPlace)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(drive.start.historyTime + " → " + (drive.end?.historyTime ?? "In progress"))
                            .font(.system(size: 12)).foregroundStyle(HistoryTheme.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 10) {
                        HistoryValue(value: VoltaFormat.number(units.distanceValue(km: drive.distanceKm)), unit: units.distanceUnit, size: 28)
                    }
                }
                if showsDate { Text(drive.start.formatted(date: .abbreviated, time: .omitted)).voltaLabelStyle() }
                HairlineDivider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            HistoryInlineMetric(systemImage: "clock", text: VoltaFormat.duration(drive.durationMin))
                            HistoryInlineMetric(systemImage: "leaf.fill", text: units.formatEfficiency(drive.displayEfficiencyWhPerKm))
                        }
                        HistoryInlineMetric(systemImage: "creditcard", text: DrivePricing.rate(drive, home: model?.settings.rates.homeTripRate)
                            .flatMap { rate in rate.cost(energyKwh: drive.costableEnergyKwh).map { VoltaFormat.money($0, currency: rate.currency) + " est." } } ?? "Cost unknown")
                    }
                    Spacer(minLength: 0)
                    DriveScoreRing(score: drive.efficiencyScore)
                }
            }
        }.accessibilityElement(children: .combine)
    }
}

#Preview("Drives") {
    DrivesHistoryView()
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Drives · empty") {
    DrivesHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}

#Preview("Drives · error") {
    DrivesHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
