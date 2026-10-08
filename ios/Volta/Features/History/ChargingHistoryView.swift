import MapKit
import SwiftUI

enum ChargeFilter: String, CaseIterable, Identifiable {
    case all, home, supercharger, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All locations"
        case .home: "Home"
        case .supercharger: "Supercharger / DC fast"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .home: "house"
        case .supercharger: "bolt.car"
        case .other: "mappin.and.ellipse"
        }
    }

    func matches(_ charge: ChargeSummary) -> Bool {
        switch self {
        case .all: true
        case .home: charge.kind == .home
        case .supercharger: charge.kind == .fast
        case .other: charge.kind == .other
        }
    }
}

extension ChargeSummary {
    enum Kind { case home, fast, other }

    var kind: Kind {
        if fastCharger { return .fast }
        if (placeName ?? "").localizedCaseInsensitiveContains("home") { return .home }
        return .other
    }

    var title: String { placeName ?? address ?? "Unknown location" }

    var kindIcon: String {
        switch kind {
        case .home: "house.fill"
        case .fast: "bolt.fill"
        case .other: "powerplug.portrait.fill"
        }
    }

    var kindTint: Color {
        switch kind {
        case .home: HistoryTheme.green
        case .fast: HistoryTheme.amber
        case .other: HistoryTheme.blue
        }
    }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [placeName, address].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Charging tab: range pill + filter, search, map toggle, day-grouped sessions.
struct ChargingHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units

    @State private var feed = HistoryFeed<ChargeSummary>()
    @State private var range: HistoryRange
    @State private var filter: ChargeFilter = .all
    @State private var searching = false
    @State private var query = ""
    @State private var showMap = false
    @State private var places = HistoryPlaces()
    @State private var path: [ChargeSummary] = []
    @State private var selectedCluster: HistoryClusterSelection?

    init(range: HistoryRange = .thirtyDays) {
        _range = State(initialValue: range)
    }

    private var visible: [ChargeSummary] {
        feed.items.filter { filter.matches($0) && $0.matches(query: query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HistoryHeader(title: "Charging", range: $range, filterActive: filter != .all) {
                    Picker("Location", selection: $filter) {
                        ForEach(ChargeFilter.allCases) { f in
                            Label(f.title, systemImage: f.systemImage).tag(f)
                        }
                    }
                } trailing: {
                    HistoryHeaderButton(systemImage: "magnifyingglass", label: "Search", isOn: searching) {
                        withAnimation(.snappy) { searching.toggle(); if !searching { query = "" } }
                    }
                    HistoryHeaderButton(systemImage: showMap ? "list.bullet" : "map", label: showMap ? "List" : "Map") {
                        withAnimation(.snappy) { showMap.toggle() }
                    }
                }
                if searching {
                    HistorySearchField(text: $query, prompt: "Search locations") {
                        withAnimation(.snappy) { searching = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .historyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ChargeSummary.self) { ChargingDetailView(charge: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
    }

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.charges(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList()
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load charges", message: message) {
                Task { await reload(skeleton: true) }
            }
        case .loaded:
            if feed.items.isEmpty {
                HistoryEmptyState(systemImage: "bolt.slash",
                                  title: range.emptyPhrase.map { "No charges \($0)" } ?? "No charges yet",
                                  message: "Try a different range or wait for your next charge.")
            } else if visible.isEmpty && !feed.hasMore {
                HistoryEmptyState(systemImage: "line.3.horizontal.decrease",
                                  title: "No matching charges",
                                  message: "Try a different search or location filter.")
            } else if showMap {
                mapView
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                totals
                    .padding(.bottom, 20)
                ForEach(DayGroup.group(visible, by: \.start)) { group in
                    SectionLabel(group.title, trailing: dayTrailing(group.items))
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    VStack(spacing: 10) {
                        ForEach(group.items) { charge in
                            NavigationLink(value: charge) { ChargeRow(charge: charge) }
                                .buttonStyle(VoltaPressStyle())
                                .accessibilityIdentifier("row.charge.\(charge.id)")
                        }
                    }
                }
                HistoryPageFooter(feed: feed) { await reload() }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
    }

    private var totals: some View {
        let totals = ChargingTotals(visible, fallbackCurrency: units.currency)
        let energy = totals.energyAddedKwh.value
        return HistoryTotalsBlock(
            title: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "sessions"),
            isPartial: feed.hasMore,
            items: [
                .init(label: "kWh added", value: energy.map { VoltaFormat.number($0, digits: $0 >= 100 ? 0 : 1) } ?? "—", unit: nil),
                .init(label: "Cost", value: totals.cost.display, unit: nil),
                .init(label: visible.count == 1 ? "Session" : "Sessions", value: "\(visible.count)\(feed.hasMore ? "+" : "")", unit: nil),
            ],
            notes: totals.notes)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("screen.charging")
    }

    private func dayTrailing(_ items: [ChargeSummary]) -> String {
        VoltaFormat.energy(PartialSum(items.map(\.energyAddedKwh)).value)
    }

    // MARK: Map

    private var mapView: some View {
        let grouping = HistoryMapGrouping(visible) { $0.location(places.state) }
        let pins = grouping.clusters.map { cluster in
            let first = cluster.items[0]
            let kwh = VoltaFormat.energy(PartialSum(cluster.items.map(\.energyAddedKwh)).value, fractionDigits: 0)
            return HistoryMapPin(id: cluster.id, coordinate: cluster.coordinate, title: cluster.title(\.title),
                                 subtitle: "\(cluster.items.count)× · \(kwh)",
                                 systemImage: first.kindIcon, tint: first.kindTint)
        }
        let needsPlaces = visible.contains { $0.needsPlaces }
        return HistorySessionsMap(pins: pins, summary: grouping.summary, retryPlaces: {
            Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
        }) { id in
            guard let cluster = grouping.clusters.first(where: { $0.id == id }) else { return }
            if cluster.items.count == 1 {
                path.append(cluster.items[0])
            } else {
                selectedCluster = HistoryClusterSelection(id: cluster.id, title: cluster.title(\.title),
                                                          itemIDs: cluster.items.map(\.id))
            }
        }
        // Above the map, not over it, so the camera never frames pins underneath.
        .safeAreaInset(edge: .top, spacing: 0) {
            HistoryMapScopeBar(feed: feed, period: range.periodLabel, noun: "sessions", count: visible.count) { await reload() }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.vertical, 8)
                .background(HistoryTheme.background)
        }
        .sheet(item: $selectedCluster) { selection in
            HistoryClusterSheet(title: selection.title,
                                items: feed.items.filter { selection.itemIDs.contains($0.id) }) { charge in
                selectedCluster = nil
                path.append(charge)
            } row: { ChargeRow(charge: $0) }
        }
        .task(id: needsPlaces) {
            if needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }
}

// MARK: - Row

struct ChargeRow: View {
    var charge: ChargeSummary
    @Environment(\.units) private var units

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    HistoryIconTile(systemImage: charge.kindIcon, tint: charge.kindTint)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(charge.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if charge.fastCharger {
                                HistoryBadge(title: "DC Fast", systemImage: "bolt.fill", tint: HistoryTheme.amber)
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(HistoryTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        HistoryValue(value: charge.energyAddedKwh.map { "+" + VoltaFormat.number($0) } ?? "—", unit: "kWh", size: 19)
                        Text(VoltaFormat.money(charge.cost, currency: charge.currency ?? units.currency))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HistoryTheme.secondary)
                            .monospacedDigit()
                    }
                }
                BatteryRangeView(from: charge.batteryEndpoints.from, to: charge.batteryEndpoints.to, tint: HistoryTheme.green)
                HStack(spacing: 18) {
                    HistoryInlineMetric(systemImage: "clock", text: VoltaFormat.duration(charge.durationMin))
                    HistoryInlineMetric(systemImage: "gauge.with.dots.needle.67percent",
                                        text: charge.maxPowerKw.map { "\(VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1)) kW max" } ?? "—")
                    if let rate = ratePerKwh {
                        HistoryInlineMetric(systemImage: "dollarsign.circle", text: rate)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HistoryTheme.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let time = charge.start.historyTime
        if let address = charge.address, address != charge.title { return "\(time) · \(address)" }
        return time
    }

    private var ratePerKwh: String? {
        guard let cost = charge.cost, let kwh = charge.energyUsedKwh ?? charge.energyAddedKwh, kwh > 0 else { return nil }
        return VoltaFormat.money(cost / kwh, currency: charge.currency ?? units.currency) + "/kWh"
    }
}

#Preview("Charging") {
    ChargingHistoryView()
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Charging · empty") {
    ChargingHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}

#Preview("Charging · error") {
    ChargingHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
