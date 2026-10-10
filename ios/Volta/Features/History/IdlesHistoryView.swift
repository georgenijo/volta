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

/// Segmented proportion bar: sentry / climate / awake / asleep, drawn as light.
struct IdleBreakdownBar: View {
    var slices: [IdleStateSlice]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, slices.reduce(0) { $0 + $1.minutes })
            let gaps = CGFloat(max(0, slices.count - 1)) * 3
            HStack(spacing: 3) {
                if slices.isEmpty {
                    Capsule().fill(HistoryTheme.track)
                }
                ForEach(slices) { slice in
                    Capsule()
                        .fill(LinearGradient(colors: [slice.color.opacity(slice.kind == .asleep ? 0.7 : 0.75), slice.color.opacity(slice.kind == .asleep ? 0.4 : 0.4)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, (proxy.size.width - gaps) * slice.minutes / total))
                        .shadow(color: slice.color.opacity(slice.kind == .unclassified ? 0 : 0.35), radius: min(6, height * 0.9))
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
            .historyGlow(HistoryTheme.blue, HistoryTheme.purple, strength: 0.15)
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
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                totals.padding(.top, 8).padding(.bottom, 22)
                ForEach(DayGroup.group(visible, by: \.start)) { group in
                    Section {
                        VStack(spacing: 12) {
                            ForEach(group.items) { idle in
                                NavigationLink(value: idle) { IdleRow(idle: idle) }
                                    .buttonStyle(VoltaPressStyle())
                                    .accessibilityIdentifier("row.idle.\(idle.id)")
                            }
                        }
                        .padding(.bottom, 10)
                    } header: {
                        SessionDayHeader(day: group.day, title: group.title,
                                         trailing: "\(VoltaFormat.duration(group.items.reduce(0) { $0 + $1.durationMin })) · \(drainLabel(group.items))")
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
        IdlesHero(scope: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "sessions"),
                  idles: visible, partial: feed.hasMore)
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

// MARK: - Hero

/// Open hero: total parked time, sleep-share dial, drain strip, drain per day.
struct IdlesHero: View {
    var scope: String
    var idles: [IdleSummary]
    var partial: Bool
    @Environment(\.units) private var units

    var body: some View {
        let totals = IdleTotals(idles)
        let energy = PartialSum(idles.map(\.energyLostKwh)).value
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scope).voltaLabelStyle(color: HistoryTheme.tertiary)
                    HistoryHeroNumeral(value: VoltaFormat.number(totals.parkedMinutes / 60, digits: 0), unit: "h parked")
                }
                Spacer(minLength: 0)
                sleepDial.padding(.trailing, 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("screen.idles")

            VStack(alignment: .leading, spacing: 10) {
                HistoryStatStrip(items: [
                    .init(value: totals.drainPerDay.map { VoltaFormat.number($0, digits: 1) + "%" } ?? "—", caption: "Per day",
                          accent: (totals.drainPerDay ?? 0) > 3 ? HistoryTheme.amber : nil),
                    .init(value: totals.rangeLostKm.value.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                          caption: "\(units.distanceUnit) lost"),
                    .init(value: energy.map { VoltaFormat.number($0, digits: $0 >= 10 ? 0 : 1) } ?? "—", caption: "kWh"),
                    .init(value: "\(idles.count)\(partial ? "+" : "")", caption: idles.count == 1 && !partial ? "Session" : "Sessions"),
                ])
                HistoryHeroNotes(notes: totals.notes)
            }
            let days = HistoryRhythmDay.series(idles, date: \.start, value: { Double($0.drain ?? 0) }, accent: { ($0.drainPerDay ?? 0) > 3 })
            if days.contains(where: { $0.value > 0 }) {
                let drained = days.filter { $0.value > 0 }
                HistoryRhythmStrip(days: days, tint: .white, accent: HistoryTheme.amber,
                                   lit: [HistoryTheme.blue, HistoryTheme.purple],
                                   trailing: "\(VoltaFormat.number(drained.reduce(0) { $0 + $1.value }, digits: 0))% drained in 14 days",
                                   accessibilityLabel: "Battery drained while parked per day, last 14 days")
            }
        }
    }

    /// Share of parked time spent asleep; more sleep means less vampire drain.
    private var sleepDial: some View {
        let recorded = idles.filter { $0.asleepMinutes != nil }
        let minutes = recorded.reduce(0) { $0 + $1.durationMin }
        let asleep = recorded.reduce(0) { $0 + ($1.asleepMinutes ?? 0) }
        let share = minutes > 0 ? Int((min(asleep, minutes) / minutes * 100).rounded()) : nil
        return SegmentDial(segments: [.init(label: "Asleep", value: share.map(Double.init) ?? 0, color: HistoryTheme.blue)],
                           center: share.map { "\($0)%" } ?? "–", caption: "Asleep", scale: 100,
                           accessibility: share.map { "Asleep \($0)% of parked time" } ?? "Sleep share unavailable")
    }
}

// MARK: - Row

struct IdleRow: View {
    var idle: IdleSummary
    @Environment(\.units) private var units

    private var warm: Bool { (idle.drainPerDay ?? 0) > 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(idle.title)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    HStack(spacing: 5) {
                        Text(idle.start.historyTime)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HistoryTheme.tertiary)
                        Text(idle.end?.historyTime ?? "Now")
                    }
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    duration
                    HStack(spacing: 4) {
                        Text(idle.drain.map { $0 > 0 ? "−\($0)%" : "\($0)%" } ?? "—")
                            .foregroundStyle(warm ? HistoryTheme.amber : .white.opacity(0.85))
                        Text("·").foregroundStyle(HistoryTheme.tertiary)
                        Text(idle.rangeLostKm.map { "−" + units.formatDistance($0) } ?? "—")
                    }
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
                .fixedSize()
            }
            .padding(.bottom, 16)
            IdleBreakdownBar(slices: idle.breakdown, height: 3)
                .padding(.bottom, 14)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                if idle.breakdown.isEmpty {
                    Text("States not recorded").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                }
                ForEach(Array(idle.breakdown.prefix(3).enumerated()), id: \.element.id) { index, slice in
                    if index > 0 { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }
                    HStack(spacing: 5) {
                        Image(systemName: slice.systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(slice.color.opacity(0.9))
                        Text(VoltaFormat.duration(slice.minutes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .lineLimit(1).fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(slice.kind.rawValue) \(VoltaFormat.duration(slice.minutes))")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .driveSurface()
        .accessibilityElement(children: .combine)
    }

    private var duration: some View {
        let hours = Int(idle.durationMin / 60), minutes = Int(idle.durationMin.truncatingRemainder(dividingBy: 60))
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            if hours > 0 {
                Text("\(hours)").font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8)
                Text("H").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary).padding(.trailing, 2)
            }
            Text("\(minutes)").font(.system(size: hours > 0 ? 22 : 30, weight: .bold)).fontWidth(.expanded).tracking(-0.6)
            Text("M").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
        }
        .monospacedDigit().foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoltaFormat.duration(idle.durationMin))
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
