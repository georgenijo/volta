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
        case .home: HistoryTheme.mint
        case .fast: HistoryTheme.blue
        case .other: Color(hex: 0x7DD3C0)
        }
    }

    /// "AC" / "DC" plus where, for the card's kind line.
    var currentLabel: String { fastCharger ? "DC" : "AC" }
    var currentTint: Color { fastCharger ? HistoryTheme.blue : HistoryTheme.mint }

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
            .historyGlow(HistoryTheme.mint, HistoryTheme.blue, strength: 0.13)
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
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                totals.padding(.top, 8).padding(.bottom, 22)
                ForEach(DayGroup.group(visible, by: \.start)) { group in
                    Section {
                        VStack(spacing: 12) {
                            ForEach(group.items) { charge in
                                NavigationLink(value: charge) { ChargeRow(charge: charge) }
                                    .buttonStyle(VoltaPressStyle())
                                    .accessibilityIdentifier("row.charge.\(charge.id)")
                                    .voltaCascade()
                            }
                        }
                        .padding(.bottom, 10)
                    } header: {
                        SessionDayHeader(day: group.day, title: group.title, trailing: dayTrailing(group.items))
                    }
                }
                HistoryPageFooter(feed: feed) { await reload() }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
        .voltaArrivalScope()
    }

    private var totals: some View {
        ChargingHero(scope: HistoryTotalsScope.title(period: range.periodLabel, hasMore: feed.hasMore, noun: "sessions"),
                     charges: visible, partial: feed.hasMore,
                     window: HistoryDayWindow(range: feed.range, oldestLoaded: feed.items.map(\.start).min(), hasMore: feed.hasMore))
    }

    private func dayTrailing(_ items: [ChargeSummary]) -> String {
        "\(items.count) \(items.count == 1 ? "session" : "sessions") · " + VoltaFormat.energy(PartialSum(items.map(\.energyAddedKwh)).value)
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

// MARK: - Hero

/// Open hero: energy added, home/public split dial, stat strip, kWh per day.
struct ChargingHero: View {
    var scope: String
    var charges: [ChargeSummary]
    var partial: Bool
    /// Days the rhythm strip may show.
    var window: HistoryDayWindow
    @Environment(\.units) private var units

    var body: some View {
        let totals = ChargingTotals(charges, fallbackCurrency: units.currency)
        let energy = totals.energyAddedKwh.value
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scope).voltaLabelStyle(color: HistoryTheme.tertiary)
                    HistoryHeroNumeral(value: energy.map { VoltaFormat.number($0, digits: $0 >= 100 ? 0 : 1) } ?? "—", unit: "kWh")
                }
                Spacer(minLength: 0)
                splitDial.padding(.trailing, 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("screen.charging")

            VStack(alignment: .leading, spacing: 10) {
                HistoryStatStrip(items: [
                    .init(value: totals.cost.display, caption: "Cost", accent: HistoryTheme.amber),
                    .init(value: "\(charges.count)\(partial ? "+" : "")", caption: charges.count == 1 && !partial ? "Session" : "Sessions"),
                    .init(value: VoltaFormat.duration(charges.reduce(0) { $0 + $1.durationMin }), caption: "Plugged"),
                    .init(value: averageRate(totals) ?? "—", caption: "Per kWh"),
                ])
                HistoryHeroNotes(notes: totals.notes)
            }
            let days = HistoryRhythmDay.series(charges, date: \.start, value: { $0.energyAddedKwh ?? 0 }, accent: \.fastCharger, window: window)
            if window.isDrawable, days.contains(where: { $0.value > 0 }) {
                let charged = days.filter { $0.value > 0 }
                HistoryRhythmStrip(days: days, tint: HistoryTheme.mint, accent: HistoryTheme.blue,
                                   lit: [HistoryTheme.mint, HistoryTheme.blue], leading: window.label,
                                   trailing: "\(VoltaFormat.energy(charged.reduce(0) { $0 + $1.value } / Double(max(charged.count, 1)))) per charge day",
                                   legend: days.contains(where: \.accent) ? [("AC", HistoryTheme.mint), ("DC", HistoryTheme.blue)] : [],
                                   accessibilityLabel: "Energy added per day, \(window.label)")
            }
        }
    }

    private var splitDial: some View {
        let home = charges.filter { $0.kind == .home }.reduce(0) { $0 + ($1.energyAddedKwh ?? 0) }
        let publicKwh = charges.filter { $0.kind != .home }.reduce(0) { $0 + ($1.energyAddedKwh ?? 0) }
        let total = home + publicKwh
        let share = total > 0 ? Int((home / total * 100).rounded()) : nil
        return SegmentDial(segments: [.init(label: "Home", value: home, color: HistoryTheme.mint),
                                      .init(label: "Public", value: publicKwh, color: HistoryTheme.blue)],
                           center: share.map { "\($0)%" } ?? "–", caption: "Home",
                           accessibility: share.map { "Home charging \($0)% of energy, public \(100 - $0)%" } ?? "Home share unavailable")
    }

    /// Blended price over sessions that recorded both cost and energy, single currency only.
    private func averageRate(_ totals: ChargingTotals) -> String? {
        guard case .single(_, let currency) = totals.cost else { return nil }
        let priced = charges.compactMap { c -> (Double, Double)? in
            guard let cost = c.cost, let kwh = c.energyUsedKwh ?? c.energyAddedKwh, kwh > 0 else { return nil }
            return (cost, kwh)
        }
        let kwh = priced.reduce(0) { $0 + $1.1 }
        guard kwh > 0 else { return nil }
        return VoltaFormat.money(priced.reduce(0) { $0 + $1.0 } / kwh, currency: currency)
    }
}

// MARK: - Charge curve

/// The session's state-of-charge climb drawn as a faint luminous curve.
/// AC rises steadily; DC tapers as the pack fills.
struct ChargeCurveWatermark: View {
    var from: Int?
    var to: Int?
    var fast: Bool
    var opacity: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            if let from, let to {
                let points = Self.curve(from: from, to: to, fast: fast, in: geometry.size, inset: 12)
                let path = Path { p in
                    p.move(to: points[0]); points.dropFirst().forEach { p.addLine(to: $0) }
                }
                let gradient = LinearGradient(colors: [HistoryTheme.mint, HistoryTheme.blue], startPoint: .leading, endPoint: .trailing)
                let area = Path { p in
                    p.addPath(path)
                    p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                    p.addLine(to: CGPoint(x: points[0].x, y: geometry.size.height))
                    p.closeSubpath()
                }
                ZStack {
                    area.fill(LinearGradient(colors: [HistoryTheme.blue.opacity(0.14), HistoryTheme.mint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    path.stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)).blur(radius: 7).opacity(0.45)
                    path.stroke(gradient, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    Circle().fill(HistoryTheme.mint).frame(width: 5, height: 5).position(points[0])
                    Circle().fill(HistoryTheme.blue).frame(width: 5, height: 5).position(points[points.count - 1])
                        .shadow(color: HistoryTheme.blue, radius: 4)
                }
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Larger sessions climb higher; the shape is the AC/DC taper.
    static func curve(from: Int, to: Int, fast: Bool, in size: CGSize, inset: CGFloat) -> [CGPoint] {
        let w = max(1, size.width - inset * 2), h = max(1, size.height - inset * 2)
        let rise = min(1, max(0.35, Double(abs(to - from)) / 60)) * (to >= from ? 1 : -1)
        let baseY = to >= from ? inset + h : inset
        return (0...32).map { i in
            let t = Double(i) / 32
            let f = fast ? 1 - pow(1 - t, 2.4) : t * t * (3 - 2 * t)
            return CGPoint(x: inset + w * t, y: baseY - h * rise * f)
        }
    }
}

// MARK: - Row

struct ChargeRow: View {
    var charge: ChargeSummary
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(charge.title)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    kindLine
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(charge.energyAddedKwh.map { "+" + VoltaFormat.number($0) } ?? "—")
                            .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                        Text("KWH").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text(charge.start.historyTime)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HistoryTheme.tertiary)
                        Text(charge.end?.historyTime ?? "Now")
                    }
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
                .fixedSize()
            }
            .padding(.bottom, 16)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    metrics(compact: false)
                    metrics(compact: true)
                }
                Spacer(minLength: 8)
                SocDial(from: charge.startBatteryLevel, to: charge.endBatteryLevel, size: 38,
                        colors: charge.fastCharger ? [HistoryTheme.mint, HistoryTheme.blue] : [HistoryTheme.mint.opacity(0.7), HistoryTheme.mint])
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .background {
            ChargeCurveWatermark(from: charge.startBatteryLevel, to: charge.endBatteryLevel, fast: charge.fastCharger, opacity: 0.6)
                .padding(.leading, 120).padding(.trailing, 110).padding(.top, 6).padding(.bottom, 52)
                .mask(RadialGradient(colors: [.black, .black.opacity(0.6), .clear], center: .center, startRadius: 10, endRadius: 110))
        }
        .driveSurface()
        .accessibilityElement(children: .combine)
    }

    /// Small colored glyph for AC/DC, then where.
    private var kindLine: some View {
        HStack(spacing: 6) {
            if charge.fastCharger {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(HistoryTheme.blue)
                    .shadow(color: HistoryTheme.blue.opacity(0.8), radius: 3)
            } else {
                Circle().fill(HistoryTheme.mint).frame(width: 6, height: 6).shadow(color: HistoryTheme.mint.opacity(0.8), radius: 3)
            }
            Text(charge.fastCharger ? "DC FAST" : "AC").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(charge.currentTint)
            if let place = subtitle {
                Text(place).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String? {
        if let address = charge.address, address != charge.title { return address }
        return charge.kind == .home ? "Home charger" : nil
    }

    private func metrics(compact: Bool) -> some View {
        HStack(spacing: 8) {
            metric("clock", VoltaFormat.duration(charge.durationMin))
            dot
            metric("bolt", charge.maxPowerKw.map { "\(VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1)) kW" } ?? "—")
            dot
            metric("creditcard", VoltaFormat.money(charge.cost, currency: charge.currency ?? units.currency), tint: HistoryTheme.amber)
            if !compact, let rate = ratePerKwh { dot; metric(nil, rate) }
        }
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }

    private func metric(_ icon: String?, _ text: String, tint: Color = HistoryTheme.tertiary) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint) }
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.78))
        }
        .lineLimit(1).fixedSize()
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
