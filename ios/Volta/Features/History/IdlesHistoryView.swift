import MapKit
import SwiftUI
import UIKit

extension IdleSummary {
    var title: String { placeName ?? address ?? "Unknown location" }

    /// Battery percentage points lost; nil without both readings.
    var drain: Int? {
        guard let s = startBatteryLevel, let e = endBatteryLevel else { return nil }
        return s - e
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

    /// Still parked: the server leaves the end open until the next drive or charge.
    var isLive: Bool { end == nil }

    /// The place's saved name first, then the town, the first part of the
    /// address, or the recorded coordinates. Nothing is geocoded.
    var placeLabel: String {
        if let place = placeName?.trimmingCharacters(in: .whitespaces), !place.isEmpty { return place }
        if let city = city?.trimmingCharacters(in: .whitespaces), !city.isEmpty { return city }
        if let address, !address.isEmpty { return ChargePlace.firstComponent(address) }
        if let latitude, let longitude {
            return "\(VoltaFormat.number(latitude, digits: 3)), \(VoltaFormat.number(longitude, digits: 3))"
        }
        return "Unknown location"
    }

    /// "08:52 → 18:14", or "Yesterday 21:48 → 09:31" when the stop crosses
    /// midnight, and "→ Now" while it is still open.
    func timeRange(now: Date = .now, calendar: Calendar = .current) -> (String, String) {
        guard let end else { return (start.historyTime, "Now") }
        if calendar.isDate(start, inSameDayAs: end) { return (start.historyTime, end.historyTime) }
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            day = start.formatted(.dateTime.weekday(.abbreviated).day())
        }
        return ("\(day) \(start.historyTime)", end.historyTime)
    }
}

struct IdleStateSlice: Identifiable, Hashable {
    enum Kind: String {
        case sentry = "Sentry", climate = "Climate", awake = "Awake", asleep = "Asleep", unclassified = "Unclassified"
    }
    var kind: Kind
    var minutes: Double
    var id: Kind { kind }

    /// Neutral shades: a state is not a fault or a gain, so it takes no signal
    /// colour. The legend names each state; the order is fixed.
    var color: Color {
        switch kind {
        case .sentry: Color(hex: 0xD6D6D6)
        case .climate: Color(hex: 0xB0B0B0)
        case .awake: Color(hex: 0x8A8A8A)
        case .asleep: Color(hex: 0x6E6E6E)
        case .unclassified: Color(hex: 0x4A4A4A)
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
        case .asleep: "Deep sleep"
        case .unclassified: "State not recorded"
        }
    }
}

/// Segmented proportion bar of the recorded states.
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
                        .fill(slice.color)
                        .frame(width: max(height, (proxy.size.width - gaps) * slice.minutes / total))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// What a Parked tab page shows: a stop, or (stacked) the full summary.
enum ParkedRoute: Hashable {
    case stop(Int)
    case summary
}

/// Parked tab ("Idles" in code and the API). The list of stops with the
/// period's loss on top. On the inner display opened flat the list ends at
/// the hinge and the other half always shows the summary, or the stop
/// selected in the list. In a compact window the summary is a pushed page.
struct IdlesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.barsOnSide) private var barsOnSide
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var feed = HistoryFeed<IdleSummary>()
    @State private var range: HistoryRange
    @State private var showMap = false
    @State private var refreshing = false
    @State private var places = HistoryPlaces()
    /// Open pages, resolved against the loaded list so an open stop follows
    /// a refresh (a stop that has since ended).
    @State private var path: [ParkedRoute] = []
    @State private var selectedCluster: HistoryClusterSelection?
    @State private var showingCustomRange = false
    /// The whole tab, which decides between a stack and a split.
    @State private var window = HistoryWindow()

    init(range: HistoryRange = .thirtyDays) {
        _range = State(initialValue: range)
    }

    private var split: Bool { sizeClass == .regular && window.isWide }
    private var selected: ParkedRoute? { split ? path.first : nil }

    private var summary: ParkedSummary {
        let dates = range.dateRange()
        return ParkedSummary(feed.items, partial: feed.hasMore, from: dates.from, to: dates.to)
    }

    var body: some View {
        let summary = self.summary
        HistoryNavigation(path: $path, split: split, window: window) {
            root(summary)
        } destination: { route in
            destination(route, summary: summary)
        } placeholder: {
            overviewPane(summary)
        }
        .readsHistoryWindow($window)
        .task(id: loadKey) { await load() }
        .followsSystemTextSize()
    }

    @ViewBuilder private func destination(_ route: ParkedRoute, summary: ParkedSummary) -> some View {
        switch route {
        case .stop(let id):
            if let idle = feed.items.first(where: { $0.id == id }) {
                IdleDetailView(idle: idle)
                    .toolbar {
                        // Beside the list the selection is the column's root:
                        // this leads back to the summary.
                        if split {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { path = [] } label: { Label("Summary", systemImage: "chevron.backward") }
                                    .tint(Color.voltaTextPrimary)
                                    .accessibilityIdentifier("button.parked.summary")
                            }
                        }
                    }
            } else {
                HistoryMissingSelection(systemImage: "parkingsign", title: "Stop not loaded",
                                        message: "This stop is no longer in the list for this range.")
            }
        case .summary:
            ParkedOverview(summary: summary, title: "Summary", open: open)
                .historyPage("Summary")
        }
    }

    /// The second column before a stop is selected: the summary, never empty.
    @ViewBuilder private func overviewPane(_ summary: ParkedSummary) -> some View {
        switch feed.phase {
        case .loaded where !summary.isEmpty:
            ParkedOverview(summary: summary, open: open)
        case .loaded:
            HistorySelectionPlaceholder(systemImage: "parkingsign", title: "No stops in this range",
                                        message: "Where the car sat and what it lost show here once it has parked.")
        default:
            Color.clear
        }
    }

    private func root(_ summary: ParkedSummary) -> some View {
        content(summary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .historyScreenBackground()
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .historyRangeSheet(isPresented: $showingCustomRange, range: $range)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        HistoryBarTitle(title: "Parked", barsOnSide: barsOnSide)
        // With the bars on the side the range menu sits in the content, by the title.
        if !barsOnSide {
            ToolbarItemGroup(placement: .topBarLeading) {
                HistoryRangeMenu(range: $range, showsValue: true) { showingCustomRange = true }
            }
            .historyPriority()
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            HistoryToolbarButton(title: showMap ? "List" : "Map", systemImage: showMap ? "list.bullet" : "mappin.and.ellipse",
                                 isOn: showMap, identifier: "button.history.map") {
                withAnimation(.snappy) { showMap.toggle() }
            }
            Button {
                Task {
                    refreshing = true
                    await reload()
                    refreshing = false
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: refreshing)
            }
            .tint(Color.voltaTextPrimary)
            .disabled(refreshing)
            .accessibilityIdentifier("button.idles.refresh")
        }
    }

    private func open(_ idle: IdleSummary) { path.historyOpen(.stop(idle.id), split: split) }

    /// The list this screen shows; a tab that comes back to the same key keeps its pages.
    private var loadKey: HistoryLoadKey { HistoryLoadKey(range: range, vehicleID: vehicleID) }

    private var fetch: HistoryFeed<IdleSummary>.Fetch {
        let ds = dataSource, vid = vehicleID
        return { r, c in try await ds.idles(vehicleID: vid, range: r, cursor: c) }
    }

    /// Loads the list unless it already holds this range and vehicle.
    private func load() async {
        await feed.loadIfNeeded(key: loadKey, range: range.dateRange(), fetch: fetch)
    }

    private func reload(skeleton: Bool = false) async {
        await feed.reload(key: loadKey, range: range.dateRange(), fetch: fetch, showSkeleton: skeleton)
    }

    /// Title and range menu in the content while the bars are on the side.
    @ViewBuilder private var header: some View {
        if barsOnSide {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    headerTitle
                    Spacer(minLength: 8)
                    ParkedRangeMenu(range: $range) { showingCustomRange = true }
                }
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle
                    ParkedRangeMenu(range: $range) { showingCustomRange = true }
                }
            }
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.top, VoltaSpacing.sm)
        }
    }

    private var headerTitle: some View {
        Text("Parked")
            .font(.system(.title, weight: .bold))
            .foregroundStyle(Color.voltaTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func content(_ summary: ParkedSummary) -> some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList().safeAreaInset(edge: .top, spacing: 0) { header }
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load stops", message: message) {
                Task { await reload(skeleton: true) }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
        case .loaded:
            if feed.items.isEmpty {
                HistoryEmptyState(systemImage: "parkingsign", title: "No Stops",
                                  message: "Stops show here once the car has been parked for more than 10 minutes.")
                    .safeAreaInset(edge: .top, spacing: 0) { header }
            } else if showMap {
                mapView
            } else {
                list(summary)
            }
        }
    }

    private func list(_ summary: ParkedSummary) -> some View {
        let text = ParkedText(units: units)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    ParkedHero(summary: summary, period: range.periodLabel)
                    if let live = summary.open {
                        Button { open(live) } label: {
                            ParkedNowCard(idle: live).parkedSelected(selected == .stop(live.id), radius: VoltaRadius.card)
                        }
                        .buttonStyle(VoltaPressStyle())
                        .accessibilityIdentifier("row.idle.live")
                    }
                    if !split, !summary.places.isEmpty {
                        Button { path.append(.summary) } label: { ParkedPlacesCard(summary: summary) }
                            .buttonStyle(VoltaPressStyle())
                            .accessibilityIdentifier("button.parked.summary")
                    }
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, 12)
                ForEach(summary.groups) { group in
                    ParkedDayHeader(title: DayGroup<IdleSummary>(day: group.day, items: group.stops).title,
                                    trailing: text.dayTotal(group.stops))
                        .padding(.horizontal, VoltaSpacing.screen)
                        .padding(.top, 26)
                    ForEach(group.stops) { idle in
                        Button { open(idle) } label: {
                            ParkedRow(idle: idle).parkedSelected(selected == .stop(idle.id))
                        }
                        .buttonStyle(VoltaPressStyle())
                        .accessibilityIdentifier("row.idle.\(idle.id)")
                        .padding(.horizontal, VoltaSpacing.screen - ParkedRow.inset)
                    }
                }
                HistoryPageFooter(feed: feed) { await reload() }
                    .padding(.horizontal, VoltaSpacing.screen)
                    .padding(.top, 20)
            }
            .voltaReadableWidth()
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.idles")
        .refreshable { await reload() }
    }

    private var mapView: some View {
        let visible = feed.items
        let grouping = HistoryMapGrouping(visible) { $0.location(places.state) }
        let pins = grouping.clusters.map { cluster in
            let minutes = cluster.items.reduce(0) { $0 + $1.durationMin }
            return HistoryMapPin(id: cluster.id, coordinate: cluster.coordinate, title: cluster.title(\.placeLabel),
                                 subtitle: "\(cluster.items.count)× · \(ParkedText.span(minutes))",
                                 systemImage: "parkingsign", tint: HistoryTheme.blue)
        }
        let needsPlaces = visible.contains { $0.needsPlaces }
        return HistorySessionsMap(pins: pins, summary: grouping.summary, retryPlaces: {
            Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
        }) { id in
            guard let cluster = grouping.clusters.first(where: { $0.id == id }) else { return }
            if cluster.items.count == 1 {
                open(cluster.items[0])
            } else {
                selectedCluster = HistoryClusterSelection(id: cluster.id, title: cluster.title(\.placeLabel),
                                                          itemIDs: cluster.items.map(\.id))
            }
        }
        // Above the map, not over it, so the camera never frames pins underneath.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                HistoryMapScopeBar(feed: feed, period: range.periodLabel, noun: "stops", count: visible.count) { await reload() }
                    .padding(.horizontal, HistoryTheme.gutter)
            }
            .padding(.vertical, 8)
            .background(HistoryTheme.background)
        }
        .sheet(item: $selectedCluster) { selection in
            HistoryClusterSheet(title: selection.title,
                                items: feed.items.filter { selection.itemIDs.contains($0.id) }) { idle in
                selectedCluster = nil
                open(idle)
            } row: { ParkedRow(idle: $0) }
        }
        .task(id: needsPlaces) {
            if needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }
}

// MARK: - Range menu

/// The range menu as a capsule in the content, beside the title, while the
/// bars are on the side (the side strip has room for its symbol only).
struct ParkedRangeMenu: View {
    @Binding var range: HistoryRange
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
            HStack(spacing: 6) {
                Text(range.menuTitle)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.voltaTextPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(HistoryTheme.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.voltaControlFill, in: .capsule)
            .contentShape(.capsule)
        }
        .accessibilityLabel("Date range, \(range.menuTitle)")
        .accessibilityIdentifier("button.history.range")
    }
}

// MARK: - Hero

/// "Lost while parked": range lost as the main figure, the estimated energy
/// beside it, then the rate per day parked, the time parked and the stops.
struct ParkedHero: View {
    var summary: ParkedSummary
    var period: String
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 52

    var body: some View {
        let text = ParkedText(units: units)
        let total = summary.total
        let more = summary.partial ? "+" : ""
        VStack(alignment: .leading, spacing: 0) {
            ParkedLabelRow(title: "Lost while parked") {
                Text(summary.partial ? HistoryTotalsScope.title(period: period, hasMore: true, noun: "stops") : period)
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
            }
            figure(text: text, more: more)
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(spokenFigure(text: text, more: more))
                .accessibilityIdentifier("screen.idles")
            HairlineDivider().padding(.top, 14)
            stats(text: text, more: more).padding(.top, 12)
            ForEach(summary.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 10)
            }
            if total.measuredStops == 0 && total.stops > 0 {
                Text("No stop in this list recorded its range loss.")
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voltaCardBackground()
    }

    @ViewBuilder private func figure(text: ParkedText, more: String) -> some View {
        let lost = summary.total.lost
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 6))
        layout {
            if let lost {
                Text(text.number(lost) + more)
                    .font(.system(size: numberSize, weight: .heavy))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(Color.voltaTextPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("\(units.distanceUnit) of range")
                    .font(.body)
                    .foregroundStyle(HistoryTheme.secondary)
            } else {
                Text("Loss not recorded")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Color.voltaTextPrimary)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let kwh = summary.energyKwh.value {
                Text("about \(VoltaFormat.energy(kwh))")
                    .font(.subheadline)
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
            }
        }
    }

    private func spokenFigure(text: ParkedText, more: String) -> String {
        var parts = ["Lost while parked"]
        if let lost = summary.total.lost {
            parts.append("\(summary.partial ? "at least " : "")\(text.spokenDistance(lost)) of range")
        } else {
            parts.append("loss not recorded")
        }
        if let kwh = summary.energyKwh.value { parts.append("about \(VoltaFormat.number(kwh)) kilowatt-hours, estimated") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func stats(text: ParkedText, more: String) -> some View {
        let total = summary.total
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            stat(total.perDayKm.map(text.distance) ?? "—", "Per day parked",
                 spoken: total.perDayKm.map { "\(text.spokenDistance($0)) lost per day parked" } ?? "Per day parked, not recorded")
            stat(ParkedText.span(total.minutes) + more, "Parked",
                 spoken: "Parked \(summary.partial ? "at least " : "")\(ParkedText.spokenSpan(total.minutes))")
            stat("\(total.stops)\(more)", "Stops",
                 spoken: "\(summary.partial ? "at least " : "")\(total.stops) \(total.stops == 1 ? "stop" : "stops")",
                 trailing: !typeSize.isAccessibilitySize)
        }
    }

    private func stat(_ value: String, _ label: String, spoken: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            Text(value)
                .font(.system(.body, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.voltaTextPrimary)
            Text(label).voltaLabelStyle()
        }
        .frame(maxWidth: trailing ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

// MARK: - Parked now

/// The stop still open. There is none while the car drives or charges.
struct ParkedNowCard: View {
    var idle: IdleSummary
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 34

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minutes = max(idle.durationMin, context.date.timeIntervalSince(idle.start) / 60)
            VStack(alignment: .leading, spacing: 10) {
                if typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Parked now").voltaLabelStyle()
                            Text(idle.placeLabel)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(Color.voltaTextPrimary)
                            Text(ParkedText.span(minutes))
                                .font(.system(.body, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.voltaTextPrimary)
                        }
                        Spacer(minLength: 0)
                        chevron
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Text("P")
                            .font(.system(.body, weight: .bold))
                            .foregroundStyle(Color.voltaTextPrimary)
                            .frame(width: badge, height: badge)
                            .background(HistoryTheme.cardRaised, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Parked now").voltaLabelStyle()
                            Text(idle.placeLabel)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(Color.voltaTextPrimary)
                        }
                        Spacer(minLength: 8)
                        Text(ParkedText.span(minutes))
                            .font(.system(.body, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.voltaTextPrimary)
                        chevron
                    }
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .voltaCardBackground()
            .contentShape(.rect(cornerRadius: VoltaRadius.card))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Parked now at \(idle.placeLabel), \(ParkedText.spokenSpan(minutes)) so far. \(footnote)")
            .accessibilityHint("Opens this stop")
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(HistoryTheme.secondary)
            .accessibilityHidden(true)
    }

    private var footnote: String {
        let battery = idle.startBatteryLevel.map { "\($0)% when parked. " } ?? ""
        return battery + "Loss is measured when the car next drives or charges."
    }
}

// MARK: - Compact "Where it sat"

/// Up to three places, opening the full summary as a pushed page (compact width).
struct ParkedPlacesCard: View {
    var summary: ParkedSummary
    @Environment(\.units) private var units

    var body: some View {
        let places = Array(summary.places.prefix(ParkedRules.placesShown))
        VStack(alignment: .leading, spacing: 4) {
            ParkedLabelRow(title: "Where it sat") {
                HStack(spacing: 4) {
                    Text("Summary")
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(HistoryTheme.blue)
            }
            .padding(.bottom, 4)
            ForEach(places) { place in
                ParkedPlaceRow(place: place, compact: true)
            }
            if summary.places.count > places.count {
                Text("\(summary.places.count - places.count) more \(summary.places.count - places.count == 1 ? "place" : "places"), loss by day and more")
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 2)
            } else {
                Text("Loss by day, time asleep and the fastest drain")
                    .font(.caption)
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voltaCardBackground()
        .contentShape(.rect(cornerRadius: VoltaRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the parked summary")
    }
}

// MARK: - Labels

/// A small-caps label with a note at the far end; stacked at accessibility
/// sizes so neither breaks mid-word.
struct ParkedLabelRow<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).voltaLabelStyle()
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).voltaLabelStyle().layoutPriority(1)
                Spacer(minLength: 8)
                trailing.multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Day header and row

struct ParkedDayHeader: View {
    var title: String
    var trailing: String

    var body: some View {
        ParkedLabelRow(title: title) {
            Text(trailing)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One stop: place and times on the left, duration and the loss line on the right.
struct ParkedRow: View {
    var idle: IdleSummary
    /// Room around the text for the selection highlight.
    static let inset: CGFloat = 10
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let text = ParkedText(units: units)
        let loss = ParkedLoss(idle)
        let times = idle.timeRange()
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(spacing: 0) {
            HairlineDivider()
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(idle.placeLabel)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                    Text("\(times.0) → \(times.1)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HistoryTheme.secondary)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
                    Text(VoltaFormat.duration(idle.durationMin))
                        .font(.system(.subheadline, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.voltaTextPrimary)
                    Text(text.lossLine(loss))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Self.inset)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(text: text, loss: loss, times: times))
    }

    private func spoken(text: ParkedText, loss: ParkedLoss, times: (String, String)) -> String {
        "\(idle.placeLabel), parked \(ParkedText.spokenSpan(idle.durationMin)), \(times.0) to \(times.1). \(text.spokenLoss(loss))"
    }
}

extension View {
    /// The row whose stop fills the other half: tinted and outlined in the accent.
    func parkedSelected(_ isSelected: Bool, radius: CGFloat = 12) -> some View {
        background {
            if isSelected {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(HistoryTheme.blue.opacity(0.14))
            }
        }
        .historySelected(isSelected, radius: radius)
    }
}

extension ParkedText {
    /// "2.1 miles" for VoiceOver.
    func spokenDistance(_ km: Double) -> String {
        "\(number(km)) \(units.distance == .miles ? "miles" : "kilometers")"
    }

    func spokenLoss(_ loss: ParkedLoss) -> String {
        switch loss {
        case .pending, .notRecorded, .noLoss: return lossLine(loss) + "."
        case .lost(let km, let rate):
            let unit = units.distance == .miles ? "miles" : "kilometers"
            var line = "Lost \(VoltaFormat.number(rowValue(km), digits: 1)) \(unit)"
            if let rate { line += ", \(spokenDistance(rate)) a day" }
            return line + "."
        }
    }
}

#Preview("Parked") {
    IdlesHistoryView()
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Parked · empty") {
    IdlesHistoryView()
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}

#Preview("Parked · error") {
    IdlesHistoryView()
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
