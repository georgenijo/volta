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
            .historyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DriveSummary.self) { DriveDetailView(drive: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
        .task(id: vehicleID) { await reload(skeleton: true) }
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
            if feed.items.isEmpty {
                if let phrase = range.emptyPhrase {
                    HistoryEmptyState(systemImage: "road.lanes", title: "No drives \(phrase)",
                                      message: "Try a different range or wait for your next drive.")
                } else {
                    HistoryEmptyState(systemImage: "road.lanes", title: "No drives yet",
                                      message: "Your driving history will appear here once you start using your vehicle.")
                }
            } else if visible.isEmpty && !feed.hasMore {
                HistoryEmptyState(systemImage: "line.3.horizontal.decrease", title: "No matching drives",
                                  message: "Try a different search or distance filter.")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                DrivesRouteMap(drives: visible).padding(.bottom, 8)
                totals.padding(.bottom, 20)
                HStack(spacing: 12) {
                    NavigationLink { RoadtripsView(drives: visible, partial: feed.hasMore) } label: { overviewButton("Roadtrips", "road.lanes") }
                    NavigationLink { DrivesHeatmapView(drives: visible, partial: feed.hasMore) } label: { overviewButton("Heatmap", "square.grid.3x3.fill") }
                }.buttonStyle(.plain).padding(.bottom, 18)
                if sort == .newest {
                    ForEach(DayGroup.group(visible, by: \.start)) { group in
                        SectionLabel(group.title, trailing: "\(group.items.count) drives · " + units.formatDistance(group.items.reduce(0) { $0 + $1.distanceKm }))
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                        rows(group.items)
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
        .refreshable { await reload() }
    }

    private func rows(_ items: [DriveSummary]) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { drive in
                NavigationLink(value: drive) { DriveRow(drive: drive, showsDate: sort != .newest) }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("row.drive.\(drive.id)")
            }
        }
    }

    private func overviewButton(_ title: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(HistoryTheme.green)
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").foregroundStyle(HistoryTheme.secondary)
        }.padding(18).background(HistoryTheme.card, in: .rect(cornerRadius: 20))
    }

    private var totals: some View {
        let totals = DriveTotals(visible)
        let cost = DrivePricing.total(visible, fallback: model?.settings.electricityRate ?? 0.20)
        let scored = visible.filter { $0.efficiencyScore != nil }
        let scoredKm = scored.reduce(0) { $0 + $1.distanceKm }
        let average = scoredKm > 0 ? Int((scored.reduce(0) { $0 + Double($1.efficiencyScore!) * $1.distanceKm } / scoredKm).rounded()) : nil
        return VStack(alignment: .leading, spacing: 18) {
            SectionLabel(HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "drives"))
            HStack {
                HistoryValue(value: VoltaFormat.number(units.distanceValue(km: totals.distanceKm), digits: 0), unit: units.distanceUnit, size: 72)
                Spacer()
                if let average { DriveScoreRing(score: average, size: 84) }
            }
            HStack(spacing: 20) {
                HistoryInlineMetric(systemImage: "clock", text: VoltaFormat.duration(visible.reduce(0) { $0 + $1.durationMin }), tint: HistoryTheme.green)
                HistoryInlineMetric(systemImage: "road.lanes", text: "\(visible.count)\(feed.hasMore ? "+" : "") drives", tint: HistoryTheme.green)
            }
            HStack(spacing: 20) {
                HistoryInlineMetric(systemImage: "bolt.fill", text: totals.energyUsedKwh.value.map { VoltaFormat.energy($0) } ?? "—", tint: HistoryTheme.green)
                HistoryInlineMetric(systemImage: "leaf.fill", text: units.formatEfficiency(totals.efficiencyWhPerKm), tint: HistoryTheme.green)
            }
            HistoryInlineMetric(systemImage: "creditcard", text: cost.display + " estimated", tint: HistoryTheme.green)
            Text("Efficiency score · rated ÷ actual × 100, capped at 100").font(.system(size: 11)).foregroundStyle(HistoryTheme.tertiary)
            if scored.count < visible.count && !scored.isEmpty {
                Text("Score from \(scored.count) of \(visible.count) drives, weighted by distance").font(.system(size: 11)).foregroundStyle(HistoryTheme.tertiary)
            }
            ForEach(totals.notes + [cost.note].compactMap { $0 }, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(HistoryTheme.tertiary) }
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.drives")
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
                    RouteGlyph().frame(width: 14, height: 52).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 14) { Text(drive.startPlace); Text(drive.endPlace) }
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 10) {
                        HistoryValue(value: VoltaFormat.number(units.distanceValue(km: drive.distanceKm)), unit: units.distanceUnit, size: 28)
                        Text(drive.start.historyTime + " → " + (drive.end?.historyTime ?? "In progress"))
                            .font(.system(size: 12)).foregroundStyle(HistoryTheme.secondary).monospacedDigit()
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
                    if let score = drive.efficiencyScore { DriveScoreRing(score: score) }
                }
            }.background { DriveRouteThumbnail(points: drive.route ?? []).frame(width: 100, height: 110) }
        }.accessibilityElement(children: .combine)
    }
}

/// Start dot, dashed connector, end pin — a cheap stand-in for a route
/// thumbnail (summaries carry no path).
struct RouteGlyph: View {
    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(HistoryTheme.green)
                .frame(width: 10, height: 10)
            Line()
                .stroke(HistoryTheme.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                .frame(width: 1.5)
            Circle()
                .fill(HistoryTheme.blue)
                .frame(width: 10, height: 10)
                .shadow(color: HistoryTheme.blue.opacity(0.6), radius: 4)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
        }
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
