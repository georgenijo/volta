import MapKit
import SwiftUI

struct DriveDetailView: View {
    var drive: DriveSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.units) private var units
    @Environment(\.historySideBars) private var sideBars
    @Environment(\.barsOnSide) private var barsOnSide
    @Environment(\.vehicleID) private var vehicleID
    /// Optional so previews without an app model still render; nil = no local persistence.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var loader = HistoryDetailLoader<DriveDetail>()
    @State private var rateLoader = TripRateLoader()
    @State private var snapshot: TripSnapshot?
    @State private var loadedKey: LoadKey?
    @State private var mode: TripMapMode = .speed
    /// Raw scrub position (elapsed minutes) from whichever chart is touched.
    @State private var scrub: Double?
    @State private var replayMinute: Double?
    @State private var replayTask: Task<Void, Never>?
    @State private var shareImage: Image?
    @State private var editingRate = false
    @State private var showingMap = false
    /// Counts chart scrubs as they begin, for one `.selection` tap per scrub.
    @State private var scrubs = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Identity of what's on screen. A change drops the old state and any in-flight result.
    struct LoadKey: Hashable {
        var driveID: Int
        var vehicleID: Int
        var server: String?
    }

    private var key: LoadKey { LoadKey(driveID: drive.id, vehicleID: vehicleID, server: model?.settings.serverURL) }
    private var summary: DriveSummary { loader.detail?.summary ?? drive }

    /// Wattly's text margin on a 402 pt wide phone.
    static let margin: CGFloat = 28
    /// The map's fade into the page; MapKit's logo and Legal link sit just above it.
    static let mapFade: CGFloat = VoltaMapChrome.fade

    @State private var page = HistoryWindow()

    /// Wide enough for the route beside the charts (the inner display with the list hidden).
    private var usesPanes: Bool { page.isWide && page.size.width >= HistoryLayout.panesMinWidth }

    var body: some View {
        Group {
            if usesPanes {
                // Scrub a chart on one side, watch the route on the other.
                VoltaPanes {
                    VStack(spacing: 0) {
                        routeMap.ignoresSafeArea(edges: [.top, .horizontal])
                        legendStrip
                    }
                } secondary: {
                    scroll(showsMap: false)
                }
            } else {
                scroll(showsMap: true)
            }
        }
        .readsHistoryWindow($page)
        .historyPage(nil, clearBar: true)
        .toolbar { toolbar }
        .electricityRateSheet(isPresented: $editingRate, settings: model?.settings)
        .fullScreenCover(isPresented: $showingMap) {
            if let snapshot, let route = snapshot.routes[mode] {
                TripRouteFullMap(timeline: snapshot.timeline, route: route, style: routeStyle(route),
                                 legend: routeStyle(route).legend(units: units),
                                 title: TripRouteFullMap.title(summary), subtitle: TripHero.dateLine(summary))
            }
        }
        .task(id: key) { await load(key) }
        .task(id: key) { await lookUpRate(key) }
        .onChange(of: units) { rebuild() }
        // The list refreshed this drive (one that was still in progress):
        // fetch its detail again in place, keeping the page.
        .onChange(of: drive) { reload() }
        .onChange(of: scrub == nil) { _, ended in if !ended { scrubs += 1 } }
        .onDisappear { stopReplay() }
        // A new colour mode and the start of a scrub are selections.
        .voltaFeedback(.selection, trigger: mode)
        .voltaFeedback(.selection, trigger: scrubs)
    }

    private func scroll(showsMap: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsMap {
                    // Under the status bar and system bar, then about two fifths of the page.
                    routeMap
                        .frame(height: page.safeArea.top + page.reveal(0.4, 200...300))
                        .overlay { expandTarget }
                    // The legend sits under the map, never over the route.
                    legendStrip
                        .padding(.horizontal, Self.margin - 16)
                        .voltaReadableWidth()
                        .historySides(sideBars)
                }
                VStack(alignment: .leading, spacing: 0) {
                    TripHero(summary: summary, units: units)
                        .voltaFocusIn(0)
                    Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.top, 22)
                    TripStatsRow(summary: summary, units: units, regen: snapshot?.regen, maxSpeed: snapshot?.maxSpeed)
                        .padding(.top, 46).padding(.bottom, 46)
                        .voltaFocusIn(1)
                    TripCostCard(estimate: costEstimate, editable: model != nil) { editingRate = true }
                        .voltaFocusIn(2)
                    TripScoreCard(score: summary.efficiencyScore,
                                  breakdown: .resolved(server: summary.scoreBreakdown, local: snapshot?.score),
                                  result: snapshot?.score)
                        .voltaFocusIn(3)
                    signalSections
                    TripSection(icon: "list.bullet", title: "Details") {
                        TripDetailsList(rows: detailRows)
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.top, showsMap ? 0 : VoltaSpacing.lg)
                .voltaReadableWidth()
                .historySides(showsMap ? sideBars : EdgeInsets())
            }
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.drive-detail")
        // With the map: under the bars, so it reaches the edges; the text keeps clear of them.
        .ignoresSafeArea(edges: showsMap ? sideBars.barEdges.union(.top) : [])
    }

    // MARK: Cost

    /// Server rate → previous priced charge → home → DC → default. Shown at
    /// once from what's known; the previous-charge lookup upgrades it later.
    private var costEstimate: TripCostEstimate? {
        let settings = model?.settings
        return TripCostEstimate.make(energyKwh: summary.costableEnergyKwh, distanceKm: summary.distanceKm,
                                     server: DrivePricing.rate(summary, home: nil),
                                     previousCharge: rateLoader.result?.rate,
                                     homeRate: settings?.electricityRate, dcFastRate: settings?.dcFastRate,
                                     settingsCurrency: settings?.units.currency ?? units.currency)
    }

    private func lookUpRate(_ key: LoadKey) async {
        rateLoader.reset()
        // The server's own rate wins; no lookup needed.
        guard DrivePricing.rate(drive, home: nil) == nil else { return }
        let ds = dataSource, vehicle = key.vehicleID, before = drive.start
        await rateLoader.load(before: before) { cursor in
            try await ds.charges(vehicleID: vehicle, range: DateRange(from: nil, to: before), cursor: cursor)
        }
    }

    // MARK: Loading

    private func load(_ key: LoadKey) async {
        if loadedKey != key {
            stopReplay()
            loader.reset()
            snapshot = nil
            scrub = nil
            shareImage = nil
            loadedKey = key
        }
        let ds = dataSource, id = key.driveID
        await loader.load { try await ds.drive(id: id) }
        guard !Task.isCancelled, loadedKey == key else { return }
        rebuild()
    }

    /// Retry: the detail and the previous-charge rate lookup, which may have
    /// failed with it. Both keep their own generation/cancellation guards.
    private func reload() {
        let key = key
        Task { await load(key) }
        Task { await lookUpRate(key) }
    }

    private func rebuild() {
        snapshot = loader.detail.map { TripSnapshot($0, units: units) }
        shareImage = loader.detail.flatMap { TripShareCard.render($0.summary, units: units) }
    }

    // MARK: Replay

    private var isPlaying: Bool { replayTask != nil }

    private func toggleReplay() {
        if isPlaying { stopReplay(); return }
        guard let timeline = snapshot?.timeline, timeline.points.count > 1 else { return }
        scrub = nil
        let total = timeline.totalMinutes
        let startMinute = (replayMinute ?? 0) >= total ? 0 : (replayMinute ?? 0)
        replayTask = Task { @MainActor in
            // Whole trip in ~15 s by the clock, however slowly frames render.
            let clock = ContinuousClock(), began = clock.now
            var minute = startMinute
            while minute <= total, !Task.isCancelled {
                replayMinute = minute
                try? await Task.sleep(for: .milliseconds(33))
                let elapsed = clock.now - began
                minute = startMinute + total * (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / 15
            }
            // A cancelled task must not clear a newer one started after it.
            guard !Task.isCancelled else { return }
            replayMinute = total
            replayTask = nil
        }
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
    }

    /// The one resolved position the map shows: a chart scrub wins over
    /// replay. Resolved against the full timeline.
    private var focus: TripSelection? {
        guard let timeline = snapshot?.timeline, let minute = scrub ?? replayMinute else { return nil }
        return TripSelection(minute: minute, timeline: timeline)
    }

    private var focusMinute: Double? { scrub ?? replayMinute }

    private var highlight: DrivePoint? {
        guard let timeline = snapshot?.timeline, let index = focus?.index else { return nil }
        return timeline.points[index]
    }

    // MARK: Toolbar

    /// iPhone: one capsule of five 44 pt slots laid out here, so the system
    /// never folds replay and share into an overflow menu. iPhone Duo: system
    /// items it can move to the side strip, the modes folded into one menu.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if barsOnSide {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // The strip shares its height with the tabs: one menu keeps
                // replay and share out of the overflow menu.
                Menu {
                    Picker("Color route by", selection: $mode) {
                        ForEach(TripMapMode.allCases) { m in
                            Label(m.title, systemImage: m.systemImage).tag(m)
                        }
                    }
                } label: {
                    Label("Color route by \(mode.title.lowercased())", systemImage: mode.systemImage)
                }
                .tint(Color.voltaTextPrimary)
                .accessibilityIdentifier("trip.mode")
            }
            .historyPriority()
            ToolbarItemGroup(placement: .topBarTrailing) {
                replayButton
                shareButton
            }
            .historyPriority()
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    // The selected mode is a neutral circle: green is not a selection colour.
                    ForEach(TripMapMode.allCases) { m in modeButton(m) }
                    replayButton.labelStyle(.iconOnly).frame(width: Self.slot, height: Self.slot).contentShape(.rect)
                    shareButton.labelStyle(.iconOnly).frame(width: Self.slot, height: Self.slot).contentShape(.rect)
                }
                // Fixed glyphs: five slots must fit a 375 pt phone at every text size.
                .font(.system(size: 17, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.voltaTextPrimary)
            }
            .historyPriority()
        }
    }

    /// A toolbar slot: the 44 pt hit region every control keeps.
    static let slot: CGFloat = 44

    private var replayButton: some View {
        Button(action: toggleReplay) {
            Label(isPlaying ? "Pause replay" : "Replay trip", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .tint(Color.voltaTextPrimary)
        .disabled((snapshot?.timeline.points.count ?? 0) < 2)
        .accessibilityIdentifier("trip.play")
    }

    @ViewBuilder private var shareButton: some View {
        if let shareImage {
            ShareLink(item: shareImage, preview: SharePreview("Trip summary", image: shareImage)) {
                Label("Share trip summary", systemImage: "square.and.arrow.up")
            }
            .tint(Color.voltaTextPrimary)
            .accessibilityIdentifier("trip.share")
        } else {
            Button {} label: { Label("Share trip summary", systemImage: "square.and.arrow.up") }
                .disabled(true)
                .accessibilityIdentifier("trip.share")
        }
    }

    /// A mode in the capsule: a 44 pt slot; the selected one sits on a 34 pt
    /// circle of white at 16%, so the capsule never splits.
    private func modeButton(_ m: TripMapMode) -> some View {
        let selected = mode == m
        return Button { mode = m } label: {
            Image(systemName: m.systemImage)
                .frame(width: 34, height: 34)
                .background { if selected { Circle().fill(Color.voltaInk.opacity(0.16)) } }
                .frame(width: Self.slot, height: Self.slot)
                .contentShape(.rect)
        }
        .accessibilityLabel("Color route by \(m.title.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("trip.mode.\(m.rawValue)")
    }

    // MARK: Map

    private func routeStyle(_ route: TripRoute) -> TripRouteStyle {
        TripRouteStyle(mode: mode, valueRange: route.valueRange,
                       reference: EfficiencyReference(ratedWhPerKm: summary.ratedWhPerKm), windowKm: route.windowKm)
    }

    /// The route keeps 24 pt from the top controls (iPhone: the toolbar under
    /// the status bar; iPhone Duo keeps its bar in the side strip), from the
    /// Maps attribution just above the fade, and from the sides. The map
    /// view adds the markers' reach.
    private var routeClearance: EdgeInsets {
        // The page's top safe area already includes the floating toolbar.
        let top: CGFloat = sideBars.barEdges.isEmpty ? page.safeArea.top + 24 : 24
        // The map runs under the side bars: they are obstructions.
        return EdgeInsets(top: top, leading: 24, bottom: Self.mapFade + Self.attribution + 24, trailing: 24).clearing(bars: sideBars)
    }

    /// The part of `routeClearance` that clears what covers the map (the
    /// floating toolbar, or the side bars): it holds on a small map.
    private var routeObstructions: EdgeInsets {
        EdgeInsets(top: sideBars.barEdges.isEmpty ? page.safeArea.top + 24 : 0, leading: 0, bottom: 0, trailing: 0)
            .clearing(bars: sideBars)
    }

    /// MapKit's logo and Legal link above the fade.
    static let attribution: CGFloat = VoltaMapChrome.attribution

    /// The legend for the current mode, under the map.
    @ViewBuilder private var legendStrip: some View {
        if let snapshot, let route = snapshot.routes[mode], snapshot.timeline.points.count > 1,
           let legend = routeStyle(route).legend(units: units) {
            // Two lines in every mode (elevation has one): the headline
            // below stays put when the mode changes.
            RouteLegendStrip(model: legend, reservedHeight: 44)
        }
    }

    private var routeMap: some View {
        let state = RouteMapState(detail: loader.detail, error: loader.error,
                                  preferredPath: snapshot?.usesFleetTelemetry == true ? snapshot?.timeline.points : nil)
        let caption = snapshot.flatMap { snapshot in
            if case .route = state { return mapCaption(snapshot) } else { return nil }
        }
        return ZStack(alignment: .bottom) {
            Group {
                switch state {
                case .route, .single:
                    if let snapshot, let route = snapshot.routes[mode] {
                        TripMapView(timeline: snapshot.timeline, route: route, style: routeStyle(route), highlight: highlight,
                                    bottomInset: Self.mapFade, frameInsets: routeClearance, hardInsets: routeObstructions,
                                    underEdges: sideBars.barEdges.union(.vertical))
                    } else {
                        mapPlaceholder(nil)
                    }
                case .notRecorded:
                    mapPlaceholder("Route not recorded for this drive.")
                case .loading:
                    mapPlaceholder(nil, loading: true)
                case .failed(let message):
                    mapPlaceholder(message, retry: true)
                }
            }
            // Fade the map into the page; MapKit's legal label sits above it.
            LinearGradient(stops: [.init(color: HistoryTheme.background.opacity(0), location: 0),
                                   .init(color: HistoryTheme.background.opacity(0.85), location: 0.6),
                                   .init(color: HistoryTheme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.mapFade)
                .allowsHitTesting(false)
            if let caption {
                Text(caption)
                    .scaledFont(12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Color.voltaInk.opacity(0.7))
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("trip.map.caption")
                    .transition(.opacity)
            }
        }
        .animation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion), value: caption == nil)
        .overlay(alignment: .top) {
            // Keeps the bar's buttons legible over the route.
            LinearGradient(colors: [HistoryTheme.background.opacity(0.7), HistoryTheme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: page.safeArea.top + 30)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    /// The inline map is a preview: a tap anywhere on it opens the whole
    /// route full screen, and a drag on it scrolls the page.
    @ViewBuilder private var expandTarget: some View {
        if let snapshot, snapshot.routes[mode] != nil, !snapshot.timeline.points.isEmpty {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { showingMap = true }
                .accessibilityElement()
                .accessibilityLabel("Trip route map")
                .accessibilityHint("Opens the route full screen")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showingMap = true }
                .accessibilityIdentifier("trip.map.expand")
        }
    }

    private func mapPlaceholder(_ message: String?, loading: Bool = false, retry: Bool = false) -> some View {
        ZStack {
            HistoryTheme.background
            RouteWatermark(points: summary.drawableRoute, opacity: loading ? 0.45 : 0.3)
                .padding(.horizontal, 60).padding(.top, 110).padding(.bottom, 80)
                // The list's sketch of the route, with the skeleton's sweep along it while the detail loads.
                .voltaSkeleton(loading)
            VStack(spacing: 10) {
                if let message {
                    Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                if retry { PillButton("Try again", systemImage: "arrow.clockwise") { reload() } }
            }
            .padding(.bottom, 40)
        }
    }

    /// A quiet line under the route only while scrubbing/replaying or when the
    /// route has gaps; nil otherwise.
    private func mapCaption(_ snapshot: TripSnapshot) -> String? {
        let timeline = snapshot.timeline
        if let focus, focus.index == nil { return "No sample at \(TripChart.minuteLabel(focus.minute))" }
        if let focus {
            return "\(TripChart.minuteLabel(focus.sampleMinute ?? focus.minute)) of \(TripChart.minuteLabel(timeline.totalMinutes))"
        }
        if timeline.gapCount > 0 {
            return "\(timeline.gapCount) gap\(timeline.gapCount == 1 ? "" : "s") · dashed lines are not the driven path"
        }
        return nil
    }

    // MARK: Signal sections

    private var speedUnit: String { units.distance == .miles ? "mph" : "km/h" }
    private var heightUnit: String { units.distance == .miles ? "ft" : "m" }
    private func height(_ m: Double) -> Double { units.distance == .miles ? m * 3.28084 : m }
    private func number(_ v: Double, _ digits: Int = 0) -> String { VoltaFormat.number(v, digits: digits) }
    private func temp(_ c: Double) -> Double { units.temperatureValue(celsius: c) }
    private func degrees(_ v: Double) -> String { "\(number(v))\(units.temperatureUnit)" }

    private func mapped(_ points: [DriveCharts.Point], _ transform: (Double) -> Double) -> [DriveCharts.Point] {
        points.map { DriveCharts.Point(t: $0.t, v: transform($0.v)) }
    }

    @ViewBuilder private var signalSections: some View {
        if let snapshot {
            let start = snapshot.charts.start, end = snapshot.charts.end
            batterySection(snapshot, start: start, end: end)
            energySection(snapshot, start: start, end: end)
            speedSection(snapshot, start: start, end: end)
            elevationSection(snapshot, start: start, end: end)
            batteryTempSection(snapshot, start: start, end: end)
            temperatureSection(snapshot, start: start, end: end)
            rangeSection(snapshot, start: start, end: end)
        } else if let error = loader.error {
            TripSection(icon: "waveform.path.ecg", title: "Charts") {
                HistoryChartPlaceholder(height: 120, message: error) { reload() }
            }
        } else {
            // Shaped like the sections that are coming: header, value, chart.
            VStack(alignment: .leading, spacing: 0) {
                ForEach([("battery.75percent", "Battery"), ("bolt.fill", "Energy remaining"),
                         ("gauge.with.dots.needle.33percent", "Speed")], id: \.1) { icon, title in
                    TripSection(icon: icon, title: title) {
                        TripHeaderValue(text: "80% → 72%")
                    } content: {
                        HistoryChartSkeleton().frame(height: 132)
                    }
                }
            }
            .voltaSkeleton(true)
            .accessibilityLabel("Loading charts")
        }
    }

    /// `id` keeps the UI-test identifier the section's chart had before the redesign.
    private func chart(_ traces: [TripTrace], start: Date, end: Date, domain: ClosedRange<Double>,
                       axis: @escaping (Double) -> String, fillBetween: Bool = false, id: String? = nil,
                       tooltip: @escaping (Double) -> String?) -> some View {
        TripSignalChart(traces: traces, start: start, end: end, domain: domain, axisLabel: axis,
                        fillBetween: fillBetween, tooltip: tooltip, scrub: $scrub, focusMinute: focusMinute)
            .accessibilityIdentifier(id ?? "")
    }

    private func at(_ points: [DriveCharts.Point], _ start: Date, _ minute: Double) -> Double? {
        DriveChartSeries.value(points, at: start.addingTimeInterval(minute * 60))
    }

    @ViewBuilder private func batterySection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let points = s.series(.batteryLevel)
        if !points.isEmpty {
            let from = summary.startBatteryLevel ?? Int(points.first!.v.rounded())
            let to = summary.endBatteryLevel ?? Int(points.last!.v.rounded())
            TripSection(icon: "battery.75percent", title: "Battery") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(to - from > 0 ? "+" : "")\(to - from)%").font(.footnote)
                        .monospacedDigit().foregroundStyle(HistoryTheme.tertiary)
                    TripHeaderValue(text: "\(from)% → \(to)%", color: HistoryTheme.blue)
                }
            } content: {
                chart([TripTrace(label: "Battery", color: HistoryTheme.blue, points: points, fill: true)],
                      start: start, end: end, domain: TripSignalDomain.padded(points.map(\.v), minSpan: 4),
                      axis: { "\(number($0))%" }, id: "trip.chart.coverage.battery") { m in at(points, start, m).map { "\(number($0))%" } }
            }
        }
    }

    @ViewBuilder private func energySection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let points = s.series(.energyRemainingKwh)
        if let first = points.first?.v, let last = points.last?.v {
            TripSection(icon: "bolt.fill", title: "Energy remaining") {
                TripHeaderValue(text: "\(number(first, 1)) → \(number(last, 1)) kWh", color: HistoryTheme.blue)
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    let domain = TripSignalDomain.padded(points.map(\.v), minSpan: 1)
                    // Small spans tick in fractions of a kWh; whole numbers would repeat.
                    let digits = domain.upperBound - domain.lowerBound < 6 ? 1 : 0
                    // The battery's content: blue, as the battery reads everywhere at rest.
                    chart([TripTrace(label: "Energy", color: HistoryTheme.blue, points: points, fill: true)],
                          start: start, end: end, domain: domain,
                          axis: { number($0, digits) }, id: "trip.telemetry.energy-remaining") { m in at(points, start, m).map { "\(number($0, 1)) kWh" } }
                    // Only the server's figure; the chart's ends are not the energy used.
                    if let used = summary.energyUsedKwh {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "battery.25percent").font(.system(size: 15)).foregroundStyle(HistoryTheme.secondary)
                            Text("Used").tripLabel(HistoryTheme.tertiary)
                            Text("\(number(used, 1)) kWh")
                                .font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private func speedSection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let points = mapped(s.series(.speedKph)) { units.distanceValue(km: $0) }
        if let top = points.map(\.v).max() {
            let maxText = number(summary.maxSpeedKph.map { units.distanceValue(km: $0) } ?? top)
            let current = focusMinute.flatMap { at(points, start, $0) }
                ?? TripStatsRow.avgSpeedKph(summary).map { units.distanceValue(km: $0) }
            TripSection(icon: "gauge.with.dots.needle.33percent", title: "Speed") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Top \(maxText)").tripLabel(HistoryTheme.tertiary)
                    TripHeaderValue(text: current.map { "\(number($0)) \(speedUnit)" } ?? "—")
                }
            } content: {
                // Drives are ink, as on the Dashboard's 48-hour strip; the map
                // carries the speed colours.
                chart([TripTrace(label: "Speed", color: Color.voltaTextPrimary, points: points,
                                 fill: true, endDot: Color.voltaTextPrimary)],
                      start: start, end: end, domain: TripSignalDomain.zeroBased(points.map(\.v)),
                      axis: { number($0) }, id: "trip.chart.coverage.speed") { m in at(points, start, m).map { "\(number($0)) \(speedUnit)" } }
            }
        }
    }

    @ViewBuilder private func elevationSection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let points = mapped(s.series(.elevationM)) { height($0) }
        if let lo = points.map(\.v).min(), let hi = points.map(\.v).max() {
            TripSection(icon: "mountain.2.fill", title: "Elevation") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Low").tripLabel()
                    TripHeaderValue(text: "\(number(loader.detail?.elevationMinM.flatMap { $0.isFinite ? height($0) : nil } ?? lo)) \(heightUnit)")
                    Text("High").tripLabel().padding(.leading, 8)
                    TripHeaderValue(text: "\(number(loader.detail?.elevationMaxM.flatMap { $0.isFinite ? height($0) : nil } ?? hi)) \(heightUnit)")
                }
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    chart([TripTrace(label: "Elevation", color: HistoryTheme.secondary, points: points, fill: true)],
                          start: start, end: end, domain: TripSignalDomain.padded(points.map(\.v), minSpan: 10),
                          axis: { number($0) }, id: "trip.chart.coverage.elevation") { m in at(points, start, m).map { "\(number($0)) \(heightUnit)" } }
                    Text("Climbed \(climbText) · descended \(descentText)")
                        .font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
            }
        }
    }

    private var hasElevation: Bool {
        loader.detail?.elevationGainM != nil || snapshot?.series(.elevationM).isEmpty == false
    }

    private var climbText: String {
        loader.detail?.elevationGainM.map { "\(number(height($0))) \(heightUnit)" } ?? "—"
    }

    private var descentText: String {
        if let loss = loader.detail?.elevationLossM, loss.isFinite { return "\(number(height(loss))) \(heightUnit)" }
        if case .value(let v) = snapshot?.descent { return "\(number(height(v))) \(heightUnit)" }
        return "—"
    }

    @ViewBuilder private func batteryTempSection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let maxPoints = mapped(s.series(.batteryTempMaxC), temp), minPoints = mapped(s.series(.batteryTempMinC), temp)
        if !maxPoints.isEmpty || !minPoints.isEmpty {
            let values = (maxPoints + minPoints).map(\.v)
            let headline = (minPoints.last ?? maxPoints.last).map { degrees($0.v) } ?? "—"
            TripSection(icon: "thermometer.medium", title: "Battery temperature") {
                TripHeaderValue(text: headline)
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    // Ink and grey: red means a problem and the blue-to-red
                    // ramp belongs to temperature scales, not chart series.
                    chart([TripTrace(label: "Warmest cell", color: Color.voltaTextPrimary, points: maxPoints),
                           TripTrace(label: "Coolest cell", color: Self.outside, points: minPoints)].filter { !$0.points.isEmpty },
                          start: start, end: end, domain: TripSignalDomain.padded(values, minSpan: 2),
                          axis: { degrees($0) }, id: "trip.telemetry.battery-temperature") { m in
                        let hi = at(maxPoints, start, m), lo = at(minPoints, start, m)
                        return [hi.map { "warmest \(degrees($0))" }, lo.map { "coolest \(degrees($0))" }].compactMap { $0 }.joined(separator: " · ")
                    }
                    TripChartLegend(items: [.init(label: "Warmest cell", color: Color.voltaTextPrimary),
                                            .init(label: "Coolest cell", color: Self.outside)])
                }
            }
        }
    }

    @ViewBuilder private func temperatureSection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        let inside = mapped(s.series(.insideTempC), temp), outside = mapped(s.series(.outsideTempC), temp)
        if !inside.isEmpty || !outside.isEmpty {
            let values = (inside + outside).map(\.v)
            let headline = [inside.last, outside.last].compactMap { $0.map { degrees($0.v) } }.joined(separator: " · ")
            TripSection(icon: "thermometer.sun.fill", title: "Temperatures") {
                TripHeaderValue(text: headline)
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    chart([TripTrace(label: "Inside", color: Color.voltaTextPrimary, points: inside),
                           TripTrace(label: "Outside", color: Self.outside, points: outside)].filter { !$0.points.isEmpty },
                          start: start, end: end, domain: TripSignalDomain.padded(values, minSpan: 4),
                          axis: { degrees($0) }, id: "trip.telemetry.cabin-&-outside") { m in
                        let a = at(inside, start, m), b = at(outside, start, m)
                        return [a.map { "inside \(degrees($0))" }, b.map { "outside \(degrees($0))" }].compactMap { $0 }.joined(separator: " · ")
                    }
                    TripChartLegend(items: [.init(label: "Inside", color: Color.voltaTextPrimary), .init(label: "Outside", color: Self.outside)])
                }
            }
        }
    }

    @ViewBuilder private func rangeSection(_ s: TripSnapshot, start: Date, end: Date) -> some View {
        if let efficiency = s.rangeEfficiency, efficiency.points.count > 1 {
            let actual = efficiency.points.map { DriveCharts.Point(t: $0.t, v: units.distanceValue(km: $0.actualKm)) }
            let ideal = efficiency.points.map { DriveCharts.Point(t: $0.t, v: units.distanceValue(km: $0.idealKm)) }
            TripSection(icon: "gauge.with.dots.needle.67percent", title: "Range efficiency") {
                // Green at or above rated, amber only when clearly short of it.
                TripHeaderValue(text: efficiency.percent.map { "\(number($0))%" } ?? "—",
                                color: efficiency.percent.map { $0 >= 100 ? HistoryTheme.green : $0 < 85 ? HistoryTheme.amber : Color.voltaTextPrimary }
                                    ?? HistoryTheme.secondary)
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    chart([TripTrace(label: "Actual", color: HistoryTheme.green, points: actual),
                           TripTrace(label: "Ideal", color: .voltaTextPrimary, points: ideal, dashed: true, interpolation: .linear)],
                          start: start, end: end, domain: TripSignalDomain.padded((actual + ideal).map(\.v), minSpan: 4),
                          axis: { number($0) }, fillBetween: true) { m in
                        at(actual, start, m).map { "\(number($0)) \(units.distanceUnit) rated" }
                    }
                    TripChartLegend(items: [.init(label: "Actual", color: HistoryTheme.green),
                                            .init(label: "Ideal", color: HistoryTheme.secondary, dashed: true)])
                }
            }
        }
    }

    // MARK: Details

    private var detailRows: [(String, String)] {
        let regenKwh = TripStatsRow.regenKwh(server: summary.regenKwh, estimate: snapshot?.regen)
        var rows: [(String, String)] = [
            ("Average speed", TripStatsRow.avgSpeedKph(summary).map { "\(number(units.distanceValue(km: $0))) \(speedUnit)" } ?? "—"),
        ]
        switch snapshot?.maxSpeed {
        case .value(let v): rows.append(("Top speed", "\(number(units.distanceValue(km: v))) \(speedUnit)"))
        case .atLeast(let v): rows.append(("Top speed", "≥ \(number(units.distanceValue(km: v))) \(speedUnit)"))
        default: rows.append(("Top speed", summary.maxSpeedKph.map { "\(number(units.distanceValue(km: $0))) \(speedUnit)" } ?? "—"))
        }
        if let regenKwh { rows.append(("Regenerated", "\(number(regenKwh, 2)) kWh")) }
        if hasElevation { rows.append(("Climbed, descended", "\(climbText), \(descentText)")) }
        rows.append(("Energy used", summary.energyUsedKwh.map { "\(number($0, 2)) kWh" } ?? "—"))
        rows.append(("Efficiency", summary.displayEfficiencyWhPerKm.map { "\(number(units.efficiencyValue(whPerKm: $0))) \(units.efficiencyUnit)" } ?? "—"))
        rows.append(("Outside temperature", summary.outsideTempAvgC.map { degrees(temp($0)) } ?? "—"))
        if let from = summary.startBatteryLevel, let to = summary.endBatteryLevel {
            rows.append(("Battery", "\(from)% → \(to)%"))
        }
        rows.append(("Duration", VoltaFormat.duration(TripStatsRow.durationMinutes(summary))))
        if let t = snapshot?.timeline, !t.points.isEmpty {
            rows.append(("Samples", "\(t.points.count.formatted()) · \(TripAnalysis.percent(t.coverage)) covered"))
        }
        let tz = TimeZone.current
        rows.append(("Time zone", tz.abbreviation(for: summary.start) ?? tz.identifier))
        return rows
    }
}

/// What the drive detail's map area shows.
extension DriveDetailView {
    /// The second, quieter series beside an ink one (outside air, the coolest
    /// cell): grey, at least 3:1 on a white card (see docs/APPEARANCE.md).
    static let outside = Color(light: 0x6E6E73, dark: 0x8E8E8E)
}

enum RouteMapState: Equatable {
    case loading
    case failed(String)
    /// Detail loaded but the path is empty.
    case notRecorded
    /// Exactly one recorded position: a marker, no line.
    case single(DrivePoint)
    case route([DrivePoint])

    init(detail: DriveDetail?, error: String?, preferredPath: [DrivePoint]? = nil) {
        if let error { self = .failed(error); return }
        guard let detail else { self = .loading; return }
        let path = preferredPath ?? detail.path
        switch path.count {
        case 0: self = .notRecorded
        case 1: self = .single(path[0])
        default: self = .route(path)
        }
    }
}

extension DrivePoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

#Preview("Trip · dense") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, MockDataSource())
    .task { drive = try? await MockDataSource().drive(id: TripFixtures.denseDriveID).summary }
}

#Preview("Trip · sparse collector") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, MockDataSource())
    .task { drive = try? await MockDataSource().drive(id: TripFixtures.sparseDriveID).summary }
}

#Preview("Trip · error") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, HistoryPreviewFailingSource())
    .task { drive = try? await MockDataSource().drives(vehicleID: 1, range: .init(), cursor: nil).items.first }
}
