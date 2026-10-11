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

/// Drives tab: range pill + filter, search, day-grouped drive cards.
struct DrivesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var model: AppModel?

    @State private var feed = HistoryFeed<DriveSummary>()
    @State private var range: HistoryRange
    @State private var filter: DriveFilter = .all
    @State private var sort: DriveSort = .newest
    @State private var searching = false
    @State private var query = ""

    init(range: HistoryRange = .all) {
        _range = State(initialValue: range)
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

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The header floats over the list so the route map runs behind it.
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .historyScreenBackground()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DriveSummary.self) { DriveDetailView(drive: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HistoryHeader(title: "Drives", range: $range, filterActive: filter != .all || sort != .newest) {
                Picker("Distance", selection: $filter) {
                    ForEach(DriveFilter.allCases) { f in
                        Label(f.title(units), systemImage: f.systemImage).tag(f)
                    }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(DriveSort.allCases) { Text($0.title).tag($0) }
                }
            } trailing: {
                HistoryHeaderButton(systemImage: "magnifyingglass", label: "Search", isOn: searching) {
                    withAnimation(.snappy) { searching.toggle(); if !searching { query = "" } }
                }
            }
            if searching {
                HistorySearchField(text: $query, prompt: "Search cities or addresses") {
                    withAnimation(.snappy) { searching = false }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // A soft scrim keeps the title legible over the map and scrolled cards.
        .background {
            LinearGradient(colors: [HistoryTheme.background.opacity(0.85), HistoryTheme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.drives(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList()
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load drives", message: message) {
                Task { await reload(skeleton: true) }
            }
        case .loaded:
            list
        }
    }

    /// Status bar plus floating header: how far the hero map reaches up behind them.
    @State private var topInset: CGFloat = 0

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                let mapped = visible.contains { drive in DriveRouteSegments.runs(drive.drawableRoute).contains { $0.count > 1 } }
                if mapped {
                    DrivesRouteMap(drives: visible, height: 300 + max(topInset - 124, 0), fullBleed: true,
                                   topInset: max(topInset - 60, 0), legalInset: 56)
                        .padding(.top, -topInset)
                        .allowsHitTesting(false)
                }
                hero.padding(.horizontal, DrivesLayout.margin)
                    .padding(.top, mapped ? -6 : 18).padding(.bottom, 40)
                HStack(spacing: 13) {
                    NavigationLink { RoadtripsView(drives: visible, partial: feed.hasMore) } label: { DriveShortcut(title: "Roadtrips", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                        .accessibilityIdentifier("button.drives.roadtrips")
                    NavigationLink { DrivesHeatmapView(drives: visible, partial: feed.hasMore) } label: { DriveShortcut(title: "Heatmap", systemImage: "square.grid.3x3.fill") }
                        .accessibilityIdentifier("button.drives.heatmap")
                }.buttonStyle(VoltaPressStyle()).padding(.horizontal, DrivesLayout.margin).padding(.bottom, 15)
                if visible.isEmpty && !feed.hasMore {
                    HistoryEmptyState(systemImage: "road.lanes", title: feed.items.isEmpty ? "No drives \(range.emptyPhrase ?? "yet")" : "No matching drives",
                                      message: feed.items.isEmpty ? "Try a different range or wait for your next drive." : "Try a different search or distance filter.")
                        .padding(.horizontal, HistoryTheme.gutter)
                }
                if sort == .newest {
                    ForEach(DayGroup.group(visible, by: \.start)) { group in
                        Section {
                            rows(group.items).padding(.bottom, 14)
                        } header: {
                            DriveDayHeader(group: group)
                        }
                    }
                } else {
                    SectionLabel(sort.title, trailing: "\(visible.count) drives")
                        .padding(.horizontal, DrivesLayout.margin)
                        .padding(.top, 14).padding(.bottom, 12)
                    rows(visible)
                }
                HistoryPageFooter(feed: feed) { await reload() }
                    .padding(.horizontal, HistoryTheme.gutter)
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in topInset = inset }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.drives")
        .refreshable { await reload() }
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        VStack(spacing: 9) {
            ForEach(items) { drive in
                NavigationLink(value: drive) { DriveCard(drive: drive, showsDate: sort != .newest) }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("row.drive.\(drive.id)")
            }
        }
        .padding(.horizontal, DrivesLayout.cardInset)
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
