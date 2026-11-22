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

    /// Efficiency tint relative to a typical Model Y (~165 Wh/km is average):
    /// green efficient, ink ordinary, amber heavy.
    var efficiencyTint: Color {
        guard let e = displayEfficiencyWhPerKm else { return HistoryTheme.secondary }
        return e < 140 ? HistoryTheme.green : e < 190 ? Color.voltaTextPrimary : HistoryTheme.amber
    }
}

/// Where the Drives tab can navigate. Routes name what they show by ID
/// (or day) and the tab resolves them against the loaded list, so an open
/// page follows a refresh and every page deep in a chain is part of the path.
enum DriveRoute: Hashable {
    case drive(Int)
    case roadtrips
    case heatmap
    /// The roadtrip that contains this drive.
    case roadtrip(containing: Int)
    /// A day on the heatmap calendar (its start).
    case heatmapDay(Date)
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
    @State private var showingMap = false
    /// The whole tab, which decides between a stack and a split.
    @State private var window = HistoryWindow()
    /// The list's own area, inside the system bars.
    @State private var page = HistoryWindow()
    /// Counts pull-to-refreshes that brought data, for the `.refreshed` haptic.
    @State private var refreshes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(range: HistoryRange = .all) {
        _range = State(initialValue: range)
    }

    private var split: Bool { sizeClass == .regular && window.isWide }
    /// Side bars along the list's edges: none in a split, whose list column touches no bar.
    private var sideBars: EdgeInsets {
        split ? EdgeInsets() : EdgeInsets(top: 0, leading: window.safeArea.leading, bottom: 0, trailing: window.safeArea.trailing)
    }

    /// Pages arrive newest first, so a day is whole once any loaded drive
    /// started before it; only the oldest loaded day can still be missing drives.
    static func dayMayBePartial(_ day: Date, loaded: [DriveSummary], hasMore: Bool, calendar: Calendar = .current) -> Bool {
        guard hasMore else { return false }
        let start = calendar.startOfDay(for: day)
        return !loaded.contains { $0.start < start }
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
            case .drive(let id):
                if let drive = feed.items.first(where: { $0.id == id }) {
                    DriveDetailView(drive: drive)
                } else {
                    HistoryMissingSelection(systemImage: "steeringwheel", title: "Drive not loaded",
                                            message: "This drive is no longer in the list for this range.")
                }
            case .roadtrips: RoadtripsView(drives: visible, partial: feed.hasMore)
            case .heatmap: DrivesHeatmapView(drives: visible, partial: feed.hasMore)
            case .roadtrip(let id):
                if let trip = Roadtrip.group(visible).first(where: { $0.drives.contains { $0.id == id } }) {
                    RoadtripDetailView(trip: trip, partial: feed.hasMore)
                } else {
                    HistoryMissingSelection(systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                            title: "Roadtrip not loaded",
                                            message: "This roadtrip is no longer in the drives shown.")
                }
            case .heatmapDay(let day):
                HeatmapDayView(date: day, drives: visible.filter { Calendar.current.isDate($0.start, inSameDayAs: day) },
                               partial: Self.dayMayBePartial(day, loaded: feed.items, hasMore: feed.hasMore))
            }
        } placeholder: {
            HistorySelectionPlaceholder(systemImage: "steeringwheel", title: "No drive selected",
                                        message: "Choose a drive to see its route, charts and cost.")
        }
        .readsHistoryWindow($window)
        .fullScreenCover(isPresented: $showingMap) {
            DrivesFullMap(drives: visible, title: "Drives",
                          subtitle: "\(range.menuTitle) · \(visible.count) \(visible.count == 1 ? "drive" : "drives")")
        }
        .task(id: loadKey) { await load() }
        .voltaFeedback(.selection, trigger: range)
        .voltaFeedback(.selection, trigger: filter)
        .voltaFeedback(.selection, trigger: sort)
        .voltaFeedback(.refreshed, trigger: refreshes)
    }

    private var root: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .readsHistoryWindow($page)
            .safeAreaInset(edge: .top, spacing: 0) {
                if searching {
                    HistorySearchField(text: $query, prompt: "Search cities or addresses") {
                        withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) { searching = false }
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
                withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) {
                    searching.toggle(); if !searching { query = "" }
                }
            }
        }
    }

    private func open(_ route: DriveRoute) { path.historyOpen(route, split: split) }

    /// The list this screen shows; a tab that comes back to the same key keeps its pages.
    private var loadKey: HistoryLoadKey { HistoryLoadKey(range: range, vehicleID: vehicleID) }

    private var fetch: HistoryFeed<DriveSummary>.Fetch {
        let ds = dataSource, vid = vehicleID
        return { r, c in try await ds.drives(vehicleID: vid, range: r, cursor: c) }
    }

    /// Loads the list unless it already holds this range and vehicle.
    private func load() async {
        await feed.loadIfNeeded(key: loadKey, range: range.dateRange(), fetch: fetch)
    }

    private func reload(skeleton: Bool = false) async {
        await feed.reload(key: loadKey, range: range.dateRange(), fetch: fetch, showSkeleton: skeleton)
    }

    /// Pull to refresh: a soft tap once new data is in, nothing on failure.
    private func refresh() async {
        await reload()
        if feed.phase == .loaded, feed.refreshError == nil { refreshes += 1 }
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
            DrivesSkeleton().safeAreaInset(edge: .top, spacing: 0) { inlineTitle }
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load drives", message: message) {
                await reload(skeleton: true)
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
                    // The inline title (bars on the side) sits on the map: the
                    // map grows by its row so the routes keep their space.
                    let title: CGFloat = barsOnSide ? 40 : 0
                    let reveal = page.reveal(0.23, 150...180) + title
                    // Coloured by road density, like the heatmap, so both all-drives maps agree.
                    DrivesRouteMap(drives: visible, height: reveal + topInset, coloring: .density, fullBleed: true,
                                   topInset: topInset + title, attribution: false)
                        .padding(.top, -topInset)
                        .allowsHitTesting(false)
                        .overlay { mapExpandTarget }
                        .overlay(alignment: .topLeading) { inlineTitle.historySides(sideBars) }
                } else {
                    inlineTitle.historySides(sideBars)
                }
                Group {
                    hero.padding(.horizontal, DrivesLayout.margin)
                        .padding(.top, mapped ? -6 : 18).padding(.bottom, 40)
                        .voltaFocusIn(0)
                    HStack(spacing: 13) {
                        Button { open(.roadtrips) } label: { DriveShortcut(title: "Roadtrips", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                            .historySelected(selected == .roadtrips, radius: 17)
                            .accessibilityIdentifier("button.drives.roadtrips")
                        Button { open(.heatmap) } label: { DriveShortcut(title: "Heatmap", systemImage: "square.grid.3x3.fill") }
                            .historySelected(selected == .heatmap, radius: 17)
                            .accessibilityIdentifier("button.drives.heatmap")
                    }.buttonStyle(VoltaPressStyle()).padding(.horizontal, DrivesLayout.margin).padding(.bottom, 15)
                        .voltaFocusIn(1)
                    if visible.isEmpty && !feed.hasMore {
                        emptyState.padding(.horizontal, HistoryTheme.gutter)
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
        .refreshable { await refresh() }
    }

    /// The hero map is a preview: a tap anywhere on it opens every route full
    /// screen, and a drag on it scrolls the page.
    private var mapExpandTarget: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { showingMap = true }
            .accessibilityElement()
            .accessibilityLabel("Drives route map")
            .accessibilityHint("Opens every route full screen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showingMap = true }
            .accessibilityIdentifier("drives.map.expand")
    }

    /// Why nothing shows, and the next step: a wider range, or clearing the
    /// search and filter that hid every drive.
    @ViewBuilder private var emptyState: some View {
        if feed.items.isEmpty {
            HistoryEmptyState(systemImage: "road.lanes", title: "No drives \(range.emptyPhrase ?? "yet")",
                              message: range.wider == nil
                                ? "Drives appear here after the car's next trip."
                                : "The car hasn't driven \(range.emptyPhrase ?? "in this range"). Older drives are in a wider range.",
                              actionTitle: range.wider?.showTitle,
                              action: range.wider.map { wider in { range = wider } },
                              actionSystemImage: "calendar")
        } else {
            HistoryEmptyState(systemImage: "line.3.horizontal.decrease", title: "No matching drives",
                              message: "No drive \(range.emptyPhrase ?? "loaded") matches this search or distance filter.",
                              actionTitle: "Clear search and filter",
                              action: {
                                  filter = .all
                                  query = ""
                                  withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) { searching = false }
                              },
                              actionSystemImage: "xmark.circle")
        }
    }

    /// Where each drive sits in the list, so the first screenful focuses in in order.
    private var order: [Int: Int] {
        Dictionary(visible.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        let order = order
        return VStack(spacing: 9) {
            ForEach(items) { drive in
                Button { open(.drive(drive.id)) } label: {
                    DriveCard(drive: drive, showsDate: sort != .newest).historySelected(selected == .drive(drive.id), radius: 18)
                }
                .buttonStyle(VoltaPressStyle())
                .accessibilityIdentifier("row.drive.\(drive.id)")
                // The hero and shortcuts take the first two places.
                .historyFocusIn((order[drive.id] ?? 99) + 2)
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

// MARK: - Loading

/// The Drives list while its first page loads: the hero and a day of drive
/// cards, drawn from sample values as a skeleton (`.voltaSkeleton`), so the
/// screen keeps its shape as the real list arrives.
struct DrivesSkeleton: View {
    static let samples: [DriveSummary] = (0..<4).map { i in
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3_600)
        return DriveSummary(id: -1 - i, start: start, end: start.addingTimeInterval(1_500),
                            startAddress: "Palo Alto", endAddress: "Mountain View",
                            distanceKm: 18, durationMin: 25, startBatteryLevel: 80, endBatteryLevel: 76,
                            energyUsedKwh: 2.8, efficiencyWhPerKm: 155, maxSpeedKph: 95, avgSpeedKph: 45,
                            outsideTempAvgC: 18, driveScore: 82)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DrivesHero(scope: "Loading", totals: DriveTotals(Self.samples), durationMin: 100, partial: false)
                    .padding(.horizontal, DrivesLayout.margin)
                    .padding(.top, 18).padding(.bottom, 40)
                HStack(spacing: 13) {
                    DriveShortcut(title: "Roadtrips", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    DriveShortcut(title: "Heatmap", systemImage: "square.grid.3x3.fill")
                }
                .padding(.horizontal, DrivesLayout.margin).padding(.bottom, 15)
                DriveDayHeader(group: DayGroup(day: Self.samples[0].start, items: Self.samples))
                VStack(spacing: 9) {
                    ForEach(Self.samples) { DriveCard(drive: $0) }
                }
                .padding(.horizontal, DrivesLayout.cardInset)
            }
            .voltaReadableWidth()
            .voltaSkeleton(true)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading drives")
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
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.voltaTextPrimary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
}

#Preview("Drives · empty") {
    DrivesHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
}

#Preview("Drives · error") {
    DrivesHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
}
