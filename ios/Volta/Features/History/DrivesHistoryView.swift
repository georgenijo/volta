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
        guard let e = efficiencyWhPerKm else { return HistoryTheme.secondary }
        return e < 140 ? HistoryTheme.green : e < 190 ? HistoryTheme.blue : HistoryTheme.amber
    }
}

/// Drives tab: range pill + filter, search, day-grouped drive cards.
struct DrivesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units

    @State private var feed = HistoryFeed<DriveSummary>()
    @State private var range: HistoryRange
    @State private var filter: DriveFilter = .all
    @State private var sort: DriveSort = .newest
    @State private var searching = false
    @State private var query = ""

    init(range: HistoryRange = .all) {
        _range = State(initialValue: range)
    }

    private var visible: [DriveSummary] {
        let items = feed.items.filter { filter.matches($0) && $0.matches(query: query) }
        switch sort {
        case .newest: return items
        case .longest: return items.sorted { $0.distanceKm > $1.distanceKm }
        case .mostEfficient: return items.sorted { ($0.efficiencyWhPerKm ?? .infinity) < ($1.efficiencyWhPerKm ?? .infinity) }
        }
    }

    var body: some View {
        NavigationStack {
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
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(alignment: .top) {
                RadialGradient(colors: [HistoryTheme.blue.opacity(0.16), HistoryTheme.mint.opacity(0.04), .clear], center: .init(x: 0.85, y: 0), startRadius: 0, endRadius: 420)
                    .frame(height: 520).ignoresSafeArea().allowsHitTesting(false)
            }
            .historyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DriveSummary.self) { DriveDetailView(drive: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
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

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                hero.padding(.top, 8).padding(.bottom, 26)
                HStack(spacing: 10) {
                    NavigationLink { RoadtripsView(drives: visible, partial: feed.hasMore) } label: { DriveShortcut(title: "Roadtrips", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                        .accessibilityIdentifier("button.drives.roadtrips")
                    NavigationLink { DrivesHeatmapView(drives: visible, partial: feed.hasMore) } label: { DriveShortcut(title: "Heatmap", systemImage: "square.grid.3x3.fill") }
                        .accessibilityIdentifier("button.drives.heatmap")
                }.buttonStyle(VoltaPressStyle()).padding(.bottom, 18)
                if visible.isEmpty && !feed.hasMore {
                    HistoryEmptyState(systemImage: "road.lanes", title: feed.items.isEmpty ? "No drives \(range.emptyPhrase ?? "yet")" : "No matching drives",
                                      message: feed.items.isEmpty ? "Try a different range or wait for your next drive." : "Try a different search or distance filter.")
                }
                if sort == .newest {
                    ForEach(DayGroup.group(visible, by: \.start)) { group in
                        Section {
                            rows(group.items).padding(.bottom, 10)
                        } header: {
                            DriveDayHeader(group: group)
                        }
                    }
                } else {
                    SectionLabel(sort.title, trailing: "\(visible.count) drives")
                        .padding(.top, 14).padding(.bottom, 12)
                    rows(visible)
                }
                HistoryPageFooter(feed: feed) { await reload() }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.drives")
        .refreshable { await reload() }
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        VStack(spacing: 12) {
            ForEach(items) { drive in
                NavigationLink(value: drive) { DriveCard(drive: drive, showsDate: sort != .newest) }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("row.drive.\(drive.id)")
            }
        }
    }

    private var hero: some View {
        DrivesHero(scope: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "drives"),
                   totals: DriveTotals(feed.items), durationMin: feed.items.reduce(0) { $0 + $1.durationMin },
                   partial: feed.hasMore, daily: DailyDistance.series(feed.items))
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
                    DriveRouteThumbnail(points: drive.route ?? []).frame(width: 64, height: 64)
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
                            HistoryInlineMetric(systemImage: "leaf.fill", text: units.formatEfficiency(drive.efficiencyWhPerKm))
                        }
                        HistoryInlineMetric(systemImage: "creditcard", text: DrivePricing.cost(drive, fallback: model?.settings.electricityRate ?? 0.20)
                            .map { VoltaFormat.money($0, currency: DrivePricing.rate(drive, fallback: model?.settings.electricityRate ?? 0.20).currency) + " est." } ?? "Cost unknown")
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
