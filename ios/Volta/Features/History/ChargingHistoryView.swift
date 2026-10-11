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

    /// Street, then place name, then the first address component (same as the detail title).
    var title: String { ChargePlace.title(self) }

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
        case .fast: HistoryTheme.blue
        case .other: Color(hex: 0x7DD3C0)
        }
    }

    /// "AC" / "DC", where the place is unknown.
    var currentLabel: String { fastCharger ? "DC" : "AC" }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [placeName, address, street, city].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Charging tab: map hero under the floating header, totals, shortcuts and
/// day-grouped session cards.
struct ChargingHistoryView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    /// Optional so previews without an app model still render.
    @Environment(AppModel.self) private var model: AppModel?

    @State private var feed = HistoryFeed<ChargeSummary>()
    @State private var range: HistoryRange
    @State private var filter: ChargeFilter = .all
    @State private var searching = false
    @State private var query = ""
    @State private var showMap = false
    @State private var places = HistoryPlaces()
    @State private var path: [ChargeSummary] = []
    @State private var selectedCluster: HistoryClusterSelection?
    @State private var insight: MoreRoute?
    @State private var headerHeight: CGFloat = 60

    /// Totals and shortcuts share the detail screen's side margin.
    private static let margin = ChargingDetailView.margin
    private static let mapHeight: CGFloat = 296

    init(range: HistoryRange = .thirtyDays) {
        _range = State(initialValue: range)
    }

    private var visible: [ChargeSummary] {
        feed.items.filter { filter.matches($0) && $0.matches(query: query) }
    }

    private var rates: ElectricityRates {
        model?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
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
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .historyScreenBackground()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ChargeSummary.self) { ChargingDetailView(charge: $0) }
                .navigationDestination(item: $insight) { route in
                    switch route {
                    case .chargerMap: ChargerMapView()
                    default: StatsView()
                    }
                }
        }
        .task(id: range) {
            await reload(skeleton: true)
            #if DEBUG
            openDemoCharge()
            #endif
        }
    }

    #if DEBUG
    /// Screenshot aid (DEBUG): `-demoOpenCharge fast|home|<id>` opens that
    /// session once the list has loaded.
    private func openDemoCharge() {
        guard path.isEmpty, let target = UserDefaults.standard.string(forKey: "demoOpenCharge") else { return }
        let match = feed.items.first { charge in
            switch target {
            case "fast": charge.fastCharger
            case "home": charge.kind == .home
            default: String(charge.id) == target
            }
        }
        if let match { path.append(match) }
    }
    #endif

    private func reload(skeleton: Bool = false) async {
        let ds = dataSource, vid = vehicleID
        await feed.reload(range: range.dateRange(), fetch: { r, c in
            try await ds.charges(vehicleID: vid, range: r, cursor: c)
        }, showSkeleton: skeleton)
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .loading:
            HistorySkeletonList().padding(.top, headerHeight)
        case .failed(let message):
            HistoryErrorState(title: "Couldn't load charges", message: message) {
                Task { await reload(skeleton: true) }
            }
            .padding(.top, headerHeight)
        case .loaded:
            if feed.items.isEmpty {
                HistoryEmptyState(systemImage: "bolt.slash",
                                  title: range.emptyPhrase.map { "No charges \($0)" } ?? "No charges yet",
                                  message: "Try a different range or wait for your next charge.")
                    .padding(.top, headerHeight)
            } else if visible.isEmpty && !feed.hasMore {
                HistoryEmptyState(systemImage: "line.3.horizontal.decrease",
                                  title: "No matching charges",
                                  message: "Try a different search or location filter.")
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
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ChargingMapHero(coordinates: visible.compactMap { $0.location(places.state).coordinate },
                                height: Self.mapHeight) {
                    withAnimation(.snappy) { showMap = true }
                }
                ChargingHero(scope: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "sessions"),
                             charges: visible, partial: feed.hasMore) { insight = $0 }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 29)
                ForEach(DayGroup.group(visible, by: \.start)) { group in
                    ChargeDayHeader(day: group.day, title: group.title, trailing: dayTrailing(group.items))
                    VStack(spacing: 12) {
                        ForEach(group.items) { charge in
                            NavigationLink(value: charge) { ChargeRow(charge: charge) }
                                .buttonStyle(VoltaPressStyle())
                                .accessibilityIdentifier("row.charge.\(charge.id)")
                        }
                    }
                    .padding(.horizontal, HistoryTheme.gutter)
                    .padding(.top, 14).padding(.bottom, 26)
                }
                HistoryPageFooter(feed: feed) { await reload() }
                    .padding(.horizontal, HistoryTheme.gutter)
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

    /// "1 session • +47.6 kWh • $14.28". The cost shows only when every
    /// session resolves in one currency, with "~" if any is estimated.
    private func dayTrailing(_ items: [ChargeSummary]) -> String {
        var parts = ["\(items.count) \(items.count == 1 ? "session" : "sessions")"]
        if let kwh = PartialSum(items.map(\.energyAddedKwh)).value { parts.append("+" + VoltaFormat.energy(kwh)) }
        let costs = items.map { ChargeCost.resolve($0, rates: rates) }
        if let first = costs.first ?? nil, costs.allSatisfy({ $0?.currency == first.currency }) {
            let total = costs.reduce(0) { $0 + ($1?.amount ?? 0) }
            parts.append((costs.contains { $0?.isEstimated == true } ? "~" : "") + VoltaFormat.money(total, currency: first.currency))
        }
        return parts.joined(separator: " • ")
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

// MARK: - Map hero

/// Dim private MapKit tiles framing the listed sessions, fading into the
/// totals. Nothing is geocoded or searched; with no coordinates it stays blank.
private struct ChargingMapHero: View {
    var coordinates: [CLLocationCoordinate2D]
    var height: CGFloat
    var expand: () -> Void

    private static let fade: CGFloat = 80

    /// One pin per spot, to roughly 100 m.
    private var spots: [CLLocationCoordinate2D] {
        var seen = Set<String>()
        return coordinates.filter { seen.insert(String(format: "%.3f,%.3f", $0.latitude, $0.longitude)).inserted }
    }

    private var region: MKCoordinateRegion? {
        let spots = spots
        guard let minLat = spots.map(\.latitude).min(), let maxLat = spots.map(\.latitude).max(),
              let minLon = spots.map(\.longitude).min(), let maxLon = spots.map(\.longitude).max() else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.04, (maxLat - minLat) * 1.8), longitudeDelta: max(0.04, (maxLon - minLon) * 1.8)))
    }

    var body: some View {
        ZStack {
            HistoryTheme.background
            if let region {
                let spots = spots
                // Framed below the header; the Maps logo and Legal link stay above the fade.
                GreyTileMap(framing: .region(region, pins: spots),
                            insets: EdgeInsets(top: 110, leading: 0, bottom: Self.fade, trailing: 0), dim: 0.65) {
                    Circle().fill(HistoryTheme.pin.opacity(0.8)).frame(width: 13, height: 13).blur(radius: 1)
                }
                .allowsHitTesting(false)
                .id(spots.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";"))
                .overlay {
                    Color.clear.contentShape(.rect).onTapGesture(perform: expand)
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .top) {
            // Keeps the floating header legible over the tiles.
            LinearGradient(colors: [HistoryTheme.background.opacity(0.6), HistoryTheme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [HistoryTheme.background.opacity(0), HistoryTheme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
                .allowsHitTesting(false)
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Fixed private MapKit tiles drained to grey, with pins drawn over the map
/// so they keep their color. Nothing is geocoded or searched.
struct GreyTileMap<Pin: View>: View {
    enum Framing {
        /// One pin at the camera's centre.
        case camera(CLLocationCoordinate2D, distance: Double)
        /// The region fitted into the map, a pin per coordinate.
        case region(MKCoordinateRegion, pins: [CLLocationCoordinate2D])
    }

    var framing: Framing
    /// Area the camera frames; the Maps logo and Legal link sit above the bottom inset.
    var insets: EdgeInsets
    var dim: Double = 0
    @ViewBuilder var pin: Pin

    var body: some View {
        map
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, .dark)
            .safeAreaPadding(insets)
            .saturation(0)
            .overlay { Color.black.opacity(dim).allowsHitTesting(false) }
            .overlay {
                GeometryReader { geo in
                    ForEach(Array(points(in: geo.size).enumerated()), id: \.offset) { _, point in
                        pin.position(point)
                    }
                }
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder private var map: some View {
        switch framing {
        case .camera(let center, let distance):
            Map(initialPosition: .camera(MapCamera(centerCoordinate: center, distance: distance, heading: 0, pitch: 0)), interactionModes: [])
        case .region(let region, _):
            Map(initialPosition: .region(region), interactionModes: [])
        }
    }

    /// Flat camera: the centre of the framed area, or a Web Mercator projection
    /// of each pin into the region MapKit fits to that area.
    private func points(in size: CGSize) -> [CGPoint] {
        let w = size.width - insets.leading - insets.trailing, h = size.height - insets.top - insets.bottom
        let mid = CGPoint(x: insets.leading + w / 2, y: insets.top + h / 2)
        switch framing {
        case .camera:
            return [mid]
        case .region(let region, let pins):
            let c = region.center
            let dy = Self.mercatorY(c.latitude + region.span.latitudeDelta / 2) - Self.mercatorY(c.latitude - region.span.latitudeDelta / 2)
            guard region.span.longitudeDelta > 0, dy > 0, w > 0, h > 0 else { return [] }
            let scale = min(w / region.span.longitudeDelta, h / dy)
            return pins.map {
                CGPoint(x: mid.x + ($0.longitude - c.longitude) * scale,
                        y: mid.y - (Self.mercatorY($0.latitude) - Self.mercatorY(c.latitude)) * scale)
            }
        }
    }

    private static func mercatorY(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360)) * 180 / .pi
    }
}

// MARK: - Hero

/// Period and session count, total energy added, then shortcuts to the
/// cost map and energy statistics.
struct ChargingHero: View {
    var scope: String
    var charges: [ChargeSummary]
    var partial: Bool
    var open: (MoreRoute) -> Void
    @Environment(\.units) private var units

    var body: some View {
        let totals = ChargingTotals(charges, fallbackCurrency: units.currency)
        let energy = totals.energyAddedKwh.value
        let count = "\(charges.count)\(partial ? "+" : "") \(charges.count == 1 && !partial ? "session" : "sessions")"
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("\(scope) • \(count)".uppercased())
                    .font(.system(size: 9, weight: .medium)).tracking(1.8)
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(energy.map { VoltaFormat.number($0, digits: $0 >= 100 ? 0 : 1) } ?? "—")
                        .font(.system(size: 47, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("kWh").font(.system(size: 13, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("screen.charging")
            HistoryHeroNotes(notes: totals.notes).padding(.top, 8)
            HStack(spacing: 13) {
                ChargingShortcut(title: "Costs & Locations") {
                    Text("$").font(.system(size: 16, weight: .semibold)).foregroundStyle(HistoryTheme.green)
                } action: { open(.chargerMap) }
                .accessibilityIdentifier("button.charging.costs")
                ChargingShortcut(title: "Energy Mix") {
                    EnergyMixGlyph()
                } action: { open(.stats) }
                .accessibilityIdentifier("button.charging.energy-mix")
            }
            .padding(.top, 33)
        }
    }
}

/// Outlined shortcut pill: glyph, title, and a trailing "↗".
private struct ChargingShortcut<Icon: View>: View {
    var title: String
    @ViewBuilder var icon: Icon
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
            }
            .padding(.leading, 12.5).padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 45)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(VoltaPressStyle())
    }
}

/// Three stacked bars, brightest on top.
private struct EnergyMixGlyph: View {
    var body: some View {
        VStack(spacing: 2.3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(HistoryTheme.green).frame(height: 8.7)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(HistoryTheme.green.opacity(0.6)).frame(height: 4.7)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(HistoryTheme.green.opacity(0.4)).frame(height: 4.3)
        }
        .frame(width: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Day header

/// Blue calendar badge and day, the day's totals on the right, then a
/// full-width hairline.
private struct ChargeDayHeader: View {
    var day: Date
    var title: String
    var trailing: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                CalendarDayBadge(day: day)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HistoryTheme.blue).lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 11, weight: .regular)).monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 29)
            .padding(.bottom, 11)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// Small outlined calendar page with the day of the month.
private struct CalendarDayBadge: View {
    var day: Date

    var body: some View {
        Text(day.formatted(.dateTime.day()))
            .font(.system(size: 6.5, weight: .bold)).monospacedDigit()
            .padding(.top, 1.5)
            .frame(width: 13, height: 11)
            .overlay(alignment: .top) { Rectangle().frame(height: 2) }
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(lineWidth: 1.2))
            .clipShape(.rect(cornerRadius: 2, style: .continuous))
            .foregroundStyle(HistoryTheme.blue)
    }
}

// MARK: - Row

struct ChargeRow: View {
    var charge: ChargeSummary
    @Environment(\.units) private var units
    /// Optional so previews without an app model still render.
    @Environment(AppModel.self) private var model: AppModel?

    private var cost: ChargeCost? {
        ChargeCost.resolve(charge, rates: model?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6.2) {
                    HStack(alignment: .center, spacing: 8.3) {
                        Circle().fill(HistoryTheme.green).frame(width: 7.7, height: 7.7).frame(width: 16)
                        Text(charge.city ?? charge.title)
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    HStack(spacing: 4) {
                        Text(charge.start.historyTime)
                        Text("→").foregroundStyle(HistoryTheme.tertiary)
                        Text(charge.end?.historyTime ?? "Now")
                    }
                    .font(.system(size: 10.5, weight: .regular)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(charge.energyAddedKwh.map { "+" + VoltaFormat.energy($0) } ?? "—")
                        .font(.system(size: 14.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    if let kw = averagePowerKw {
                        Text("\(VoltaFormat.number(kw)) kW")
                            .font(.system(size: 10, weight: .regular)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    }
                }
                .fixedSize()
            }
            if let bar = ChargeSocBar(start: charge.startBatteryLevel, end: charge.endBatteryLevel) {
                ChargeSocBarView(bar: bar, numberSize: 13.5).padding(.top, 13.6)
            }
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.top, 14)
            HStack(spacing: 8) {
                metric("clock", VoltaFormat.duration(charge.durationMin))
                Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5)
                metric("creditcard.fill", costText)
                if needsRate { SetRateButton(settings: model?.settings, size: 10.5, link: true) }
                Spacer(minLength: 8)
                Text(place).font(.system(size: 10.5, weight: .regular)).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
                ChargePlaceBadge(charge: charge, size: 16)
            }
            .padding(.top, 14)
        }
        .padding(.leading, 14).padding(.trailing, 14.3)
        .padding(.top, 15).padding(.bottom, 12.7)
        .driveSurface(radius: 22)
        .accessibilityElement(children: .combine)
    }

    /// Recorded average, else energy over time. Unknown stays hidden.
    private var averagePowerKw: Double? {
        if let avg = charge.avgPowerKw, avg.isFinite, avg > 0 { return avg }
        guard let kwh = charge.energyAddedKwh, charge.durationMin >= 1 else { return nil }
        return kwh / (charge.durationMin / 60)
    }

    /// Network, else the place name, else the current type.
    private var place: String {
        ChargePlace.network(charge) ?? charge.placeName.flatMap { $0.isEmpty ? nil : $0 } ?? (charge.fastCharger ? "DC fast" : "AC")
    }

    /// Recorded cost, or "~$4.52" when estimated from the electricity rate.
    private var costText: String {
        guard let cost else { return "—" }
        let amount = VoltaFormat.money(cost.amount, currency: cost.currency)
        return cost.isEstimated ? "~" + amount : amount
    }

    /// Energy is known but no rate applies, so the cost can't be estimated.
    private var needsRate: Bool { cost == nil && charge.energyAddedKwh != nil && model != nil }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 10.5, weight: .regular)).monospacedDigit()
        }
        .foregroundStyle(HistoryTheme.secondary)
        .lineLimit(1).fixedSize()
    }
}

// MARK: - Place badge

/// The Tesla network's red "T" badge, otherwise the place kind's icon.
struct ChargePlaceBadge: View {
    var charge: ChargeSummary
    var size: CGFloat

    var body: some View {
        Group {
            if ChargePlace.network(charge) != nil {
                Circle().fill(HistoryTheme.teslaRed)
                    .overlay(Text("T").font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(.white))
                    .overlay(Circle().strokeBorder(.white, lineWidth: max(0.7, size * 0.05)))
            } else {
                Circle().fill(charge.kindTint.opacity(0.18))
                    .overlay(Image(systemName: charge.kindIcon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(charge.kindTint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension HistoryTheme {
    /// Session location dot on maps.
    static let pin = Color(hex: 0xD9604C)
    /// Tesla Supercharger badge.
    static let teslaRed = Color(hex: 0xE0453A)
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
