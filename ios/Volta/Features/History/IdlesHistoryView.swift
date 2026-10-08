import SwiftUI

extension IdleSummary {
    var title: String { placeName ?? address ?? "Unknown location" }

    var drain: Int? {
        guard let s = startBatteryLevel, let e = endBatteryLevel else { return nil }
        return s - e
    }

    /// Battery % lost per 24h, for spotting vampire drain.
    var drainPerDay: Double? {
        guard let drain, durationMin >= 60 else { return nil }
        return Double(drain) / (durationMin / 1440)
    }

    /// Ordered state breakdown. The time not covered by recorded states is
    /// "Awake" only when sentry, climate and asleep are all recorded; otherwise
    /// it stays "Unclassified" rather than being guessed. Empty when no state
    /// was recorded at all.
    var breakdown: [IdleStateSlice] {
        guard sentryMinutes != nil || climateMinutes != nil || asleepMinutes != nil else { return [] }
        let sentry = sentryMinutes ?? 0, climate = climateMinutes ?? 0, asleep = asleepMinutes ?? 0
        let allKnown = sentryMinutes != nil && climateMinutes != nil && asleepMinutes != nil
        let remainder = max(0, durationMin - sentry - climate - asleep)
        return [
            IdleStateSlice(kind: .sentry, minutes: sentry),
            IdleStateSlice(kind: .climate, minutes: climate),
            IdleStateSlice(kind: allKnown ? .awake : .unclassified, minutes: remainder),
            IdleStateSlice(kind: .asleep, minutes: asleep),
        ].filter { $0.minutes > 0.5 }
    }
}

struct IdleStateSlice: Identifiable, Hashable {
    enum Kind: String {
        case sentry = "Sentry", climate = "Climate", awake = "Awake", asleep = "Asleep", unclassified = "Unclassified"
    }
    var kind: Kind
    var minutes: Double
    var id: Kind { kind }

    var color: Color {
        switch kind {
        case .sentry: HistoryTheme.red
        case .climate: HistoryTheme.amber
        case .awake: HistoryTheme.green
        case .asleep: HistoryTheme.blue
        case .unclassified: HistoryTheme.tertiary
        }
    }

    var systemImage: String {
        switch kind {
        case .sentry: "shield.lefthalf.filled"
        case .climate: "fan"
        case .awake: "antenna.radiowaves.left.and.right"
        case .asleep: "moon.zzz"
        case .unclassified: "questionmark.circle"
        }
    }

    var detail: String {
        switch kind {
        case .sentry: "Cameras recording while parked"
        case .climate: "Cabin heating or cooling"
        case .awake: "Online, not sleeping"
        case .asleep: "Deep sleep, minimal drain"
        case .unclassified: "State not recorded"
        }
    }
}

/// Segmented proportion bar: sentry / climate / awake / asleep.
struct IdleBreakdownBar: View {
    var slices: [IdleStateSlice]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, slices.reduce(0) { $0 + $1.minutes })
            let gaps = CGFloat(max(0, slices.count - 1)) * 2
            HStack(spacing: 2) {
                if slices.isEmpty {
                    Capsule().fill(HistoryTheme.track)
                }
                ForEach(slices) { slice in
                    Capsule()
                        .fill(slice.color.opacity(slice.kind == .asleep ? 0.7 : 0.95))
                        .frame(width: max(height, (proxy.size.width - gaps) * slice.minutes / total))
                }
            }
        }
        .frame(height: height)
    }
}

/// Idles tab: parked sessions longer than 10 minutes.
struct IdlesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units

    @State private var feed = HistoryFeed<IdleSummary>()
    @State private var range: HistoryRange
    @State private var showMap = false
    @State private var refreshing = false
    @State private var places = HistoryPlaces()
    @State private var path: [IdleSummary] = []
    @State private var selectedCluster: HistoryClusterSelection?

    init(range: HistoryRange = .thirtyDays) {
        _range = State(initialValue: range)
    }

    private var visible: [IdleSummary] { feed.items }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HistoryHeader(title: "Idles", range: $range, filterActive: false) {
                    EmptyView()
                } trailing: {
                    HistoryHeaderButton(systemImage: showMap ? "list.bullet" : "mappin.and.ellipse",
                                        label: showMap ? "List" : "Map", isOn: showMap) {
                        withAnimation(.snappy) { showMap.toggle() }
                    }
                    HistoryHeaderButton(systemImage: "arrow.clockwise", label: "Refresh") {
                        Task {
                            refreshing = true
                            await reload()
                            refreshing = false
                        }
                    }
                    .symbolEffect(.rotate, isActive: refreshing)
                    .disabled(refreshing)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .historyScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: IdleSummary.self) { IdleDetailView(idle: $0) }
        }
        .task(id: range) { await reload(skeleton: true) }
    }

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.idles(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList()
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load idles", message: message) {
                Task { await reload(skeleton: true) }
            }
        case .loaded:
            if feed.items.isEmpty {
                HistoryEmptyState(systemImage: "parkingsign", title: "No Idle Sessions",
                                  message: "We'll track when your car is parked for more than 10 minutes.")
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
                totals.padding(.bottom, 20)
                ForEach(DayGroup.group(visible, by: \.start)) { group in
                    SectionLabel(group.title, trailing: drainLabel(group.items))
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    VStack(spacing: 10) {
                        ForEach(group.items) { idle in
                            NavigationLink(value: idle) { IdleRow(idle: idle) }
                                .buttonStyle(VoltaPressStyle())
                                .accessibilityIdentifier("row.idle.\(idle.id)")
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

    private func drainLabel(_ items: [IdleSummary]) -> String {
        guard let drain = PartialSum(items.map { $0.drain.map(Double.init) }).value.map({ Int($0) }) else { return "—" }
        return drain > 0 ? "−\(drain)%" : "\(drain)%"
    }

    private var totals: some View {
        let totals = IdleTotals(visible)
        return HistoryTotalsBlock(
            title: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "sessions"),
            isPartial: feed.hasMore,
            items: [
                .init(label: "Parked", value: VoltaFormat.number(totals.parkedMinutes / 60, digits: 0), unit: "h"),
                .init(label: "Range lost", value: totals.rangeLostKm.value.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                      unit: totals.rangeLostKm.value == nil ? nil : units.distanceUnit),
                .init(label: "Drain / day", value: totals.drainPerDay.map { VoltaFormat.number($0, digits: 1) } ?? "—",
                      unit: totals.drainPerDay == nil ? nil : "%"),
            ],
            notes: totals.notes)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("screen.idles")
    }

    private var mapView: some View {
        let grouping = HistoryMapGrouping(visible) { $0.location(places.state) }
        let pins = grouping.clusters.map { cluster in
            let hours = cluster.items.reduce(0) { $0 + $1.durationMin } / 60
            return HistoryMapPin(id: cluster.id, coordinate: cluster.coordinate, title: cluster.title(\.title),
                                 subtitle: "\(cluster.items.count)× · \(VoltaFormat.number(hours, digits: 0))h",
                                 systemImage: "parkingsign", tint: HistoryTheme.blue)
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
                                items: feed.items.filter { selection.itemIDs.contains($0.id) }) { idle in
                selectedCluster = nil
                path.append(idle)
            } row: { IdleRow(idle: $0) }
        }
        .task(id: needsPlaces) {
            if needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }
}

// MARK: - Row

struct IdleRow: View {
    var idle: IdleSummary
    @Environment(\.units) private var units

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    HistoryIconTile(systemImage: "parkingsign", tint: HistoryTheme.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(idle.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(HistoryTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        HistoryValue(value: idle.drain.map { $0 > 0 ? "−\($0)" : "\($0)" } ?? "—", unit: "%", size: 20,
                                     color: (idle.drainPerDay ?? 0) > 3 ? HistoryTheme.amber : .white)
                        Text(idle.rangeLostKm.map { "−" + units.formatDistance($0) } ?? "—")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(HistoryTheme.secondary)
                            .monospacedDigit()
                    }
                }
                IdleBreakdownBar(slices: idle.breakdown, height: 6)
                HStack(spacing: 14) {
                    ForEach(idle.breakdown.prefix(3)) { slice in
                        HStack(spacing: 5) {
                            StatusDot(color: slice.color, size: 6)
                            Text("\(slice.kind.rawValue) \(VoltaFormat.duration(slice.minutes))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HistoryTheme.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
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
        let end = idle.end.map { "–" + $0.historyTime } ?? " · now"
        return "\(idle.start.historyTime)\(end) · \(VoltaFormat.duration(idle.durationMin))"
    }
}

#Preview("Idles") {
    IdlesHistoryView()
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Idles · empty") {
    IdlesHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}

#Preview("Idles · error") {
    IdlesHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
