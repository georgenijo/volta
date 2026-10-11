import MapKit
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

    /// Peak opacity of this state's light. Sentry is a muted red so it reads
    /// as a state, not an alarm.
    var intensity: Double {
        switch kind {
        case .sentry: 0.55
        case .asleep: 0.7
        default: 0.75
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
                        .fill(slice.color.opacity(slice.intensity))
                        .frame(width: max(height, (proxy.size.width - gaps) * slice.minutes / total))
                }
            }
        }
        .frame(height: height)
    }
}

extension IdleSummary {
    /// Still parked: the server leaves the end open until the next drive or charge.
    var isLive: Bool { end == nil }

    /// Town first, as Wattly lists idles, then the place name, the first part
    /// of the address, or the recorded coordinates. Nothing is geocoded.
    var placeLabel: String {
        if let city = city?.trimmingCharacters(in: .whitespaces), !city.isEmpty { return city }
        if let place = placeName?.trimmingCharacters(in: .whitespaces), !place.isEmpty { return place }
        if let address, !address.isEmpty { return ChargePlace.firstComponent(address) }
        if let latitude, let longitude {
            return "\(VoltaFormat.number(latitude, digits: 3)), \(VoltaFormat.number(longitude, digits: 3))"
        }
        return "Unknown location"
    }

    /// Average vampire draw while parked.
    var whPerHour: Double? {
        guard let kwh = energyLostKwh, kwh.isFinite, kwh >= 0, durationMin >= 1 else { return nil }
        return kwh * 1000 / (durationMin / 60)
    }

    /// Lost energy at the home rate; nil without a rate or a measured loss.
    func cost(rates: ElectricityRates) -> Double? {
        guard let kwh = energyLostKwh, let rate = ElectricityRates.stored(rates.home) else { return nil }
        return kwh * rate
    }

    /// "19:31 → 19:43", or "Sat 10 → Sun 11" when the session crosses midnight.
    func timeRange(calendar: Calendar = .current) -> (String, String) {
        guard let end else { return (start.historyTime, "Now") }
        if calendar.isDate(start, inSameDayAs: end) { return (start.historyTime, end.historyTime) }
        let day = { (date: Date) in date.formatted(.dateTime.weekday(.abbreviated).day()) }
        return (day(start), day(end))
    }
}

/// Idles tab: map hero under the floating header, parked totals, the live
/// session, then day-grouped idle cards.
struct IdlesHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    /// Optional so previews without an app model still render.
    @Environment(AppModel.self) private var model: AppModel?

    @State private var feed = HistoryFeed<IdleSummary>()
    @State private var range: HistoryRange
    @State private var showMap = false
    @State private var refreshing = false
    @State private var places = HistoryPlaces()
    @State private var path: [IdleSummary] = []
    @State private var selectedCluster: HistoryClusterSelection?
    @State private var headerHeight: CGFloat = 60

    private static let margin = ChargingDetailView.margin
    private static let mapHeight: CGFloat = 238

    init(range: HistoryRange = .thirtyDays) {
        _range = State(initialValue: range)
    }

    private var visible: [IdleSummary] { feed.items }
    /// Finished sessions; the ongoing one has its own band.
    private var finished: [IdleSummary] { feed.items.filter { !$0.isLive } }
    private var live: IdleSummary? { feed.items.first(where: \.isLive) }

    private var rates: ElectricityRates {
        model?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
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
            HistorySkeletonList().padding(.top, headerHeight)
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load idles", message: message) {
                Task { await reload(skeleton: true) }
            }
            .padding(.top, headerHeight)
        case .loaded:
            if feed.items.isEmpty {
                HistoryEmptyState(systemImage: "parkingsign", title: "No Idle Sessions",
                                  message: "We'll track when your car is parked for more than 10 minutes.")
                    .padding(.top, headerHeight)
            } else if showMap {
                mapView.padding(.top, headerHeight)
            } else {
                list
            }
        }
    }

    private var list: some View {
        let needsPlaces = visible.contains { $0.needsPlaces }
        let locations = finished.map { $0.location(places.state).coordinate }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SessionsMapHero(coordinates: locations.compactMap { $0 }, height: Self.mapHeight, fade: 64,
                                pin: HistoryTheme.blue) {
                    withAnimation(.snappy) { showMap = true }
                }
                IdlesHero(period: range.periodLabel, idles: finished, places: placeCount(locations),
                          partial: feed.hasMore, rates: rates)
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 31)
                if let live {
                    NavigationLink(value: live) { IdleLiveBand(idle: live) }
                        .buttonStyle(VoltaPressStyle())
                        .accessibilityIdentifier("row.idle.live")
                }
                ForEach(DayGroup.group(finished, by: \.start)) { group in
                    ChargeDayHeader(day: group.day, title: group.title, trailing: dayTrailing(group.items),
                                    tint: .white.opacity(0.9))
                        .padding(.top, 34)
                    VStack(spacing: 9) {
                        ForEach(group.items) { idle in
                            NavigationLink(value: idle) { IdleRow(idle: idle, rates: rates) }
                                .buttonStyle(VoltaPressStyle())
                                .accessibilityIdentifier("row.idle.\(idle.id)")
                        }
                    }
                    .padding(.horizontal, HistoryTheme.gutter)
                    .padding(.top, 14)
                }
                HistoryPageFooter(feed: feed) { await reload() }
                    .padding(.horizontal, HistoryTheme.gutter)
                    .padding(.top, 20)
            }
        }
        .ignoresSafeArea(edges: .top)
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
        .task(id: needsPlaces) {
            if needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }

    /// Distinct spots to roughly 100 m; sessions without coordinates count by name.
    private func placeCount(_ locations: [CLLocationCoordinate2D?]) -> Int {
        var seen = Set<String>()
        for (idle, coordinate) in zip(finished, locations) {
            seen.insert(coordinate.map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) } ?? idle.placeLabel)
        }
        return seen.count
    }

    /// "9 idles • -5.2 kWh".
    private func dayTrailing(_ items: [IdleSummary]) -> String {
        var parts = ["\(items.count) \(items.count == 1 ? "idle" : "idles")"]
        if let kwh = PartialSum(items.map(\.energyLostKwh)).value { parts.append("-" + VoltaFormat.energy(kwh)) }
        return parts.joined(separator: " • ")
    }

    private var mapView: some View {
        let grouping = HistoryMapGrouping(visible) { $0.location(places.state) }
        let pins = grouping.clusters.map { cluster in
            let hours = cluster.items.reduce(0) { $0 + $1.durationMin } / 60
            return HistoryMapPin(id: cluster.id, coordinate: cluster.coordinate, title: cluster.title(\.placeLabel),
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
                selectedCluster = HistoryClusterSelection(id: cluster.id, title: cluster.title(\.placeLabel),
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
            } row: { IdleRow(idle: $0, rates: rates) }
        }
        .task(id: needsPlaces) {
            if needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) }
        }
    }
}

// MARK: - Hero

/// Period, idle and place counts, energy lost while parked with the average
/// draw on a gauge, then count, time, range and cost.
struct IdlesHero: View {
    var period: String
    var idles: [IdleSummary]
    var places: Int
    var partial: Bool
    var rates: ElectricityRates
    @Environment(\.units) private var units

    var body: some View {
        let totals = IdleTotals(idles)
        let energy = PartialSum(idles.map(\.energyLostKwh))
        let measured = idles.filter { $0.energyLostKwh != nil }
        let hours = measured.reduce(0) { $0 + $1.durationMin } / 60
        let draw = energy.value.flatMap { hours > 0 ? $0 * 1000 / hours : nil }
        let more = partial ? "+" : ""
        VStack(alignment: .leading, spacing: 0) {
            Text("\(period) • \(idles.count)\(more) \(idles.count == 1 && !partial ? "idle" : "idles") • \(places)\(more) \(places == 1 && !partial ? "place" : "places")".uppercased())
                .font(.system(size: 9.5, weight: .medium)).tracking(2.4)
                .foregroundStyle(HistoryTheme.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(energy.value.map { "-" + VoltaFormat.number($0, digits: $0 >= 100 ? 0 : 1) } ?? "—")
                        .font(.system(size: 60, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("kWh").font(.system(size: 14, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    DrainGauge(whPerHour: draw, size: 61, line: 4.3)
                    Text(draw.map { "\(Int($0.rounded())) Wh/h" } ?? "— Wh/h")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DrainGauge.color(for: draw) ?? HistoryTheme.secondary)
                }
                .padding(.trailing, -2)
            }
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("screen.idles")
            HStack(spacing: 10) {
                stat { Text("P").font(.system(size: 15, weight: .bold)).foregroundStyle(HistoryTheme.green) }
                    text: { "\(idles.count)\(more)" }
                dot
                stat { icon("clock") } text: { Self.span(totals.parkedMinutes) }
                if let km = totals.rangeLostKm.value {
                    dot
                    stat { icon("road.lanes") } text: { "-" + units.formatDistance(km) }
                }
                if let cost = PartialSum(idles.map { $0.cost(rates: rates) }).value {
                    dot
                    stat { icon("creditcard.fill") } text: { VoltaFormat.money(cost, currency: rates.currency) }
                }
            }
            .padding(.top, 12)
        }
    }

    /// "3d 15h", "16h 59m" or "42m".
    static func span(_ minutes: Double) -> String {
        let total = Int(max(0, minutes).rounded())
        if total >= 1440 { return "\(total / 1440)d \(total % 1440 / 60)h" }
        return VoltaFormat.duration(Double(total))
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 3, height: 3) }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(HistoryTheme.green)
    }

    private func stat<Icon: View>(@ViewBuilder _ icon: () -> Icon, text: () -> String) -> some View {
        HStack(spacing: 7) {
            icon()
            Text(text()).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
        }
        .lineLimit(1).fixedSize()
    }
}

// MARK: - Drain gauge

/// Open 270° vampire-drain gauge in four bands (green, blue, amber, red). The
/// draw fills the arc in its band's color; with no measured loss the bands stay dim.
struct DrainGauge: View {
    var whPerHour: Double?
    var size: CGFloat
    var line: CGFloat

    /// Upper bound of each band in Wh/h. Each band takes a quarter of the arc.
    static let bands: [(limit: Double, color: Color)] = [
        (50, HistoryTheme.green), (200, HistoryTheme.blue), (300, HistoryTheme.amber), (450, HistoryTheme.red),
    ]

    static func band(for value: Double) -> Int {
        bands.firstIndex { value < $0.limit } ?? bands.count - 1
    }

    /// Band color of a positive draw; nil when nothing was measured.
    static func color(for value: Double?) -> Color? {
        guard let value, value > 0 else { return nil }
        return bands[band(for: value)].color
    }

    /// Share of the arc, linear within each band.
    static func fraction(_ value: Double) -> Double {
        let index = band(for: value)
        let lower = index == 0 ? 0 : bands[index - 1].limit
        let within = min(1, max(0, (value - lower) / (bands[index].limit - lower)))
        return (Double(index) + within) / Double(bands.count)
    }

    var body: some View {
        let tint = Self.color(for: whPerHour)
        let quarter = 0.75 / Double(Self.bands.count), gap = 0.006
        ZStack {
            ForEach(Self.bands.indices, id: \.self) { i in
                Circle().trim(from: Double(i) * quarter + gap, to: Double(i + 1) * quarter - gap)
                    .stroke(Self.bands[i].color.opacity(0.3), style: StrokeStyle(lineWidth: line))
            }
            if let value = whPerHour, let tint {
                Circle().trim(from: 0, to: max(0.01, 0.75 * Self.fraction(value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(135))
        .overlay {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: size * 0.24, weight: .semibold))
                .foregroundStyle(tint ?? HistoryTheme.tertiary)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(whPerHour.map { "Average draw \(Int($0.rounded())) watt-hours per hour" } ?? "Draw not measured")
    }
}

// MARK: - Live

/// The session still in progress: green band with the street, current charge
/// and time parked so far.
struct IdleLiveBand: View {
    var idle: IdleSummary

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(HistoryTheme.liveAccent).frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Circle().fill(HistoryTheme.liveAccent).frame(width: 6, height: 6)
                    Text("LIVE NOW").font(.system(size: 9.5, weight: .medium)).tracking(2.6).foregroundStyle(HistoryTheme.liveAccent)
                    Spacer(minLength: 8)
                    if let drain = idle.drain {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.slash.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(HistoryTheme.secondary)
                            Text(drain > 0 ? "-\(drain)%" : "\(drain)%").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(idle.street ?? idle.placeLabel)
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text(Self.duration(idle.durationMin))
                        .font(.system(size: 23, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).fixedSize()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HistoryTheme.liveAccent.opacity(0.7))
                }
                .padding(.top, 9)
                if let level = idle.endBatteryLevel {
                    HStack(spacing: 7) {
                        Image(systemName: Self.batteryIcon(level)).font(.system(size: 12, weight: .regular))
                        Text("\(level)%").font(.system(size: 11, weight: .regular)).monospacedDigit()
                    }
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 6)
                }
            }
            .padding(.leading, 24).padding(.trailing, 28)
            .padding(.top, 21).padding(.bottom, 19)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(hex: 0x2D5040), Color(hex: 0x1D2A24)], startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Parked now at \(idle.street ?? idle.placeLabel), \(VoltaFormat.duration(idle.durationMin))")
    }

    /// "12h 01m": hours with zero-padded minutes, as Wattly's live timer.
    static func duration(_ minutes: Double) -> String {
        let total = Int(max(0, minutes))
        return total >= 60 ? String(format: "%dh %02dm", total / 60, total % 60) : "\(total)m"
    }

    static func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

extension HistoryTheme {
    /// Live session accent on the idles band.
    static let liveAccent = Color(hex: 0x64C494)
}

// MARK: - Row

struct IdleRow: View {
    var idle: IdleSummary
    var rates: ElectricityRates
    @Environment(\.units) private var units

    var body: some View {
        let metrics = self.metrics
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6.2) {
                    HStack(alignment: .center, spacing: 8.3) {
                        Circle().fill(HistoryTheme.green).frame(width: 8, height: 8).frame(width: 16)
                        Text(idle.placeLabel)
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    let times = idle.timeRange()
                    HStack(spacing: 4) {
                        Text(times.0)
                        Text("→")
                        Text(times.1)
                    }
                    .font(.system(size: 10.5, weight: .regular)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 4)
                Text(VoltaFormat.duration(idle.durationMin))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1).fixedSize()
                DrainGauge(whPerHour: (idle.energyLostKwh ?? 0) > 0 ? idle.whPerHour : nil, size: 46, line: 2.5)
            }
            if !metrics.isEmpty {
                Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.top, 19)
                HStack(spacing: 8) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                        if index > 0 { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }
                        HStack(spacing: 5) {
                            Image(systemName: metric.icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(HistoryTheme.green)
                            Text(metric.text).font(.system(size: 10.5, weight: .regular)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                        }
                        .lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .padding(.top, 20).padding(.bottom, metrics.isEmpty ? 20 : 15)
        .driveSurface(radius: 22)
        .accessibilityElement(children: .combine)
    }

    /// Energy, cost, range and draw; only what was measured as a loss.
    private var metrics: [(icon: String, text: String)] {
        guard let kwh = idle.energyLostKwh, kwh > 0 else { return [] }
        var items: [(icon: String, text: String)] = [("bolt.fill", "-" + VoltaFormat.energy(kwh))]
        if let cost = idle.cost(rates: rates) { items.append(("creditcard.fill", VoltaFormat.money(cost, currency: rates.currency))) }
        if let km = idle.rangeLostKm, km > 0 { items.append(("road.lanes", "-" + units.formatDistance(km))) }
        if let draw = idle.whPerHour { items.append(("bolt.slash.fill", "\(Int(draw.rounded())) Wh/h")) }
        return items
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
