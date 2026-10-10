import MapKit
import SwiftUI

/// Loads one detail record; shared by the three detail screens.
@MainActor @Observable
final class HistoryDetailLoader<Detail: Sendable> {
    private(set) var detail: Detail?
    private(set) var error: String?
    /// Bumped by every `load`/`reset`; a fetch publishes only if it is still the latest.
    private var generation = 0

    func load(_ fetch: @Sendable () async throws -> Detail) async {
        generation += 1
        let token = generation
        error = nil
        do {
            let result = try await fetch()
            guard token == generation, !Task.isCancelled else { return }
            detail = result
        } catch {
            // Cancelled or superseded: leave the state for the newer request.
            if token != generation || error is CancellationError || Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }

    /// Clears state when the subject changes (another drive, vehicle or server)
    /// and invalidates any request still in flight.
    func reset() {
        generation += 1
        detail = nil
        error = nil
    }
}

struct ChargingDetailView: View {
    var charge: ChargeSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    /// Optional so previews without an app model still render.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var loader = HistoryDetailLoader<ChargeDetail>()
    @State private var places = HistoryPlaces()
    @State private var electrical: Electrical = .voltage
    @State private var showingMap = false
    /// Scroll offset; fades the header scrim in once content rises past the map.
    @State private var scrollY: CGFloat = 0

    enum Electrical: String, CaseIterable, Hashable {
        case voltage = "Volts", current = "Amps"
    }

    private static let mapHeight: CGFloat = 320

    /// The detail's summary when loaded (it may carry fields the list row lacks).
    private var summary: ChargeSummary { loader.detail?.summary ?? charge }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    mapBackdrop
                    VStack(alignment: .leading, spacing: 0) {
                        hero.padding(.bottom, 24)
                        VStack(spacing: 12) {
                            costCard.voltaCascade(index: 0)
                            energyCard.voltaCascade(index: 1)
                            curveCard
                                .background(alignment: .top) { Color.clear.frame(height: 0).id(ScrollTarget.curve) }
                                .voltaCascade(index: 2)
                            temperatureCard.voltaCascade(index: 3)
                            telemetryCards.voltaCascade(index: 4)
                            electricalCard.voltaCascade(index: 5)
                        }
                        Color.clear.frame(height: 1).id(ScrollTarget.bottom)
                    }
                    .padding(.horizontal, HistoryTheme.gutter)
                    // The hero rises into the map's fade.
                    .padding(.top, -56)
                }
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.charge-detail")
            .voltaArrivalScope()
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in scrollY = y }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) { header }
            #if DEBUG
            .task(id: loader.detail != nil) { await debugScroll(proxy) }
            #endif
        }
        .historyGlow(charge.fastCharger ? HistoryTheme.blue : HistoryTheme.mint, charge.fastCharger ? HistoryTheme.mint : HistoryTheme.blue, strength: 0.14)
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingMap) {
            if let coordinate = location.coordinate {
                ChargeLocationMap(coordinate: coordinate, title: ChargePlace.title(summary), subtitle: ChargePlace.subtitle(summary),
                                  systemImage: summary.kindIcon, tint: summary.kindTint)
            }
        }
        .task { await load() }
        .task { if charge.needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) } }
    }

    private enum ScrollTarget: Hashable { case curve, bottom }

    #if DEBUG
    /// Screenshot aid: `-demoDetailScroll curve|bottom` scrolls once the detail loads.
    private func debugScroll(_ proxy: ScrollViewProxy) async {
        guard loader.detail != nil, let target = UserDefaults.standard.string(forKey: "demoDetailScroll") else { return }
        try? await Task.sleep(for: .milliseconds(600))
        switch target {
        // Below the floating header rather than under it.
        case "curve": proxy.scrollTo(ScrollTarget.curve, anchor: UnitPoint(x: 0.5, y: 0.15))
        case "bottom": proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
        default: break
        }
    }
    #endif

    private func load() async {
        let ds = dataSource, id = charge.id
        await loader.load { try await ds.charge(id: id) }
    }

    private var samples: [ChargeSample] { loader.detail?.samples ?? [] }
    private var telemetry: FleetTelemetrySeries? { loader.detail?.telemetry }
    private var sessionStart: Date { summary.start }
    private var sessionEnd: Date { summary.end ?? summary.start.addingTimeInterval(summary.durationMin * 60) }
    private var location: HistoryLocation { summary.location(places.state) }
    private var rate: Double { model?.settings.electricityRate ?? 0.20 }
    private var accent: Color { summary.fastCharger ? HistoryTheme.blue : HistoryTheme.mint }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: HistoryTheme.background, location: 0),
                                   .init(color: HistoryTheme.background.opacity(0.75), location: 0.55),
                                   .init(color: HistoryTheme.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                ChargeBackButton()
                Spacer(minLength: 0)
                if location.coordinate != nil {
                    GlassCircleButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 48, accessibilityLabel: "Expand map") {
                        showingMap = true
                    }
                    .accessibilityIdentifier("charge.map.expand")
                }
            }
            .padding(.horizontal, HistoryTheme.gutter)
            .padding(.bottom, 8)
            .voltaTopScrim(opacity: min(max((scrollY - 110) / 70, 0), 1), glow: false)
        }
    }

    // MARK: Map backdrop

    /// Private MapKit tiles centred on the recorded or geofence coordinate.
    /// Nothing is geocoded or searched.
    private var mapBackdrop: some View {
        Group {
            switch location {
            case .known:
                if let coordinate = location.coordinate {
                    Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1400, heading: 0, pitch: 50)),
                        interactionModes: []) {
                        Annotation("", coordinate: coordinate) { ChargePin(systemImage: summary.kindIcon, tint: summary.kindTint) }
                    }
                    .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
                    .overlay {
                        // The whole backdrop opens the full-screen map.
                        Color.clear.contentShape(.rect).onTapGesture { showingMap = true }
                            .accessibilityHidden(true)
                    }
                }
            case .pending:
                mapPlaceholder(nil, loading: true)
            case .placesUnavailable:
                mapPlaceholder("Saved places couldn't load, so this location isn't mapped.", retry: true)
            case .unmapped:
                mapPlaceholder(summary.address == nil ? "Location not recorded." : nil)
            }
        }
        // The map dissolves into the screen instead of ending at an edge.
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                   .init(color: .black.opacity(0.45), location: 0.7), .init(color: .black.opacity(0.1), location: 0.84),
                                   .init(color: .clear, location: 0.94)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: Self.mapHeight)
    }

    private func mapPlaceholder(_ message: String?, loading: Bool = false, retry: Bool = false) -> some View {
        ZStack {
            HistoryTheme.card.opacity(0.6)
            Image(systemName: summary.kindIcon)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(summary.kindTint.opacity(0.08))
                .offset(y: -20)
            VStack(spacing: 10) {
                if loading { ProgressView().tint(HistoryTheme.secondary) }
                if let message {
                    Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                if retry {
                    PillButton("Retry", systemImage: "arrow.clockwise") {
                        Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
                    }
                }
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(ChargePlace.title(summary))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.charge-detail")
                    currentChip
                }
                if let subtitle = ChargePlace.subtitle(summary) {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HistoryTheme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                    Text(dateLine).monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HistoryTheme.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                HistoryHeroNumeral(value: summary.energyAddedKwh.map { VoltaFormat.number($0) } ?? "—", unit: "kWh", size: 64)
                Spacer(minLength: 0)
                if let cost = costEstimate {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(VoltaFormat.money(cost.amount, currency: cost.currency))
                            .font(.system(size: 22, weight: .bold)).fontWidth(.expanded).monospacedDigit().foregroundStyle(.white)
                        Text(cost.isEstimated ? "Est. cost" : "Cost")
                            .font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase)
                            .foregroundStyle(cost.isEstimated ? HistoryTheme.amber : HistoryTheme.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let bar = ChargeSocBar(start: summary.startBatteryLevel, end: summary.endBatteryLevel) {
                ChargeSocBarView(bar: bar, colors: summary.fastCharger ? [HistoryTheme.mint, HistoryTheme.blue]
                                                                       : [HistoryTheme.mint.opacity(0.6), HistoryTheme.mint])
            }
            stats
        }
    }

    private var currentChip: some View {
        HStack(spacing: 4) {
            Image(systemName: summary.fastCharger ? "bolt.fill" : "powerplug.portrait.fill").font(.system(size: 9, weight: .bold))
            Text(summary.fastCharger ? "DC FAST" : "AC").font(.system(size: 10, weight: .bold)).tracking(1)
        }
        .foregroundStyle(summary.currentTint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(summary.currentTint.opacity(0.1), in: .capsule)
        .overlay(Capsule().strokeBorder(summary.currentTint.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }

    /// "Sat, Oct 4 · 10:12 – 10:39 · 27m" in the app's time format.
    private var dateLine: String {
        let day = summary.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let end = summary.end.map { " – " + $0.historyTime } ?? " – now"
        return "\(day) · \(summary.start.historyTime)\(end) · \(VoltaFormat.duration(summary.durationMin))"
    }

    // MARK: Stats

    private var averagePowerKw: Double? {
        if let avg = summary.avgPowerKw, avg.isFinite, avg > 0 { return avg }
        let powers = powerCurve.points.map(\.value).filter { $0 > 0.2 }
        if !powers.isEmpty { return powers.reduce(0, +) / Double(powers.count) }
        return summary.energyAddedKwh.map { $0 / max(summary.durationMin / 60, 0.01) }
    }

    private var stats: some View {
        let rangeAdded = rangeAddedKm
        let kw = { (v: Double) in VoltaFormat.number(v, digits: v >= 20 ? 0 : 1) }
        return HistoryStatStrip(items: [
            .init(value: VoltaFormat.duration(summary.durationMin), caption: "Duration"),
            .init(value: peakPowerKw.map(kw) ?? "—", caption: "Peak kW", accent: accent),
            .init(value: averagePowerKw.map(kw) ?? "—", caption: "Avg kW"),
            .init(value: rangeAdded.map { ($0 < 0 ? "−" : "+") + VoltaFormat.number(units.distanceValue(km: abs($0)), digits: 0) } ?? "—",
                  caption: "Range \(units.distanceUnit)"),
        ])
    }

    private var peakPowerKw: Double? {
        [summary.maxPowerKw, ChargeCurve.peak(powerCurve.points)?.value].compactMap { $0 }.filter(\.isFinite).max()
    }

    // MARK: Cost

    private var costEstimate: ChargeCost? {
        ChargeCost.resolve(summary, fallbackRate: rate, fallbackCurrency: units.currency)
    }

    private var costCard: some View {
        let cost = costEstimate
        let currency = cost?.currency ?? units.currency
        let perDistance: String? = {
            guard let cost, let km = rangeAddedKm, km > 1 else { return nil }
            return VoltaFormat.money(cost.amount / units.distanceValue(km: km) * 100, currency: currency) + " / 100 \(units.distanceUnit)"
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cost").voltaLabelStyle(color: HistoryTheme.tertiary)
                Spacer()
                if cost?.isEstimated == true { HistoryBadge(title: "Estimated", tint: HistoryTheme.amber) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(cost?.pricePerKwh.map { VoltaFormat.money($0, currency: currency) + " / kWh" } ?? "Rate unknown")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                Spacer()
                Text(VoltaFormat.money(cost?.amount, currency: currency))
                    .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("charge.cost")
            }
            .padding(.top, 10).padding(.bottom, cost?.isEstimated == true ? 8 : 14)
            if let cost, cost.isEstimated {
                Text(estimateNote(cost))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            if let perDistance {
                Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
                row("Cost per distance", perDistance, secondary: true)
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, perDistance == nil ? 4 : 6)
        .driveSurface()
    }

    private func estimateNote(_ cost: ChargeCost) -> String {
        let rateText = VoltaFormat.money(cost.pricePerKwh, currency: cost.currency) + "/kWh"
        return summary.fastCharger
            ? "No price was recorded for this fast charge. Estimated at your electricity rate of \(rateText); network pricing is usually higher."
            : "No price was recorded. Estimated from energy added at your electricity rate of \(rateText)."
    }

    // MARK: Energy flow

    @ViewBuilder private var energyCard: some View {
        if let flow = ChargeEnergyFlow.resolve(summary) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Energy flow").voltaLabelStyle(color: HistoryTheme.tertiary)
                    Spacer()
                    if flow.isEstimated { HistoryBadge(title: "Estimated", tint: HistoryTheme.amber) }
                }
                .padding(.bottom, 14)
                ChargeEnergyBars(flow: flow, accent: accent)
                    .padding(.bottom, 12)
                Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
                row("From grid", VoltaFormat.energy(flow.gridKwh) + (flow.isEstimated ? " est." : ""))
                HairlineDivider()
                row("Added to battery", VoltaFormat.energy(flow.addedKwh))
                HairlineDivider()
                row("Charging losses", VoltaFormat.energy(flow.lossKwh)
                    + (flow.lossFraction.map { " · \(VoltaFormat.number($0 * 100, digits: 0))%" } ?? ""), secondary: true)
                HairlineDivider()
                row("Efficiency", flow.efficiency.map { VoltaFormat.number($0 * 100, digits: 0) + "%" } ?? "—", secondary: true)
                if flow.isEstimated {
                    Text("Grid energy wasn't measured for this session; it assumes \(Int(ChargeEnergyFlow.assumedEfficiency * 100))% charging efficiency.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4).padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            .driveSurface()
        }
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondary ? HistoryTheme.secondary : .white.opacity(0.88))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(secondary ? HistoryTheme.secondary : .white)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
    }

    private var rangeAddedKm: Double? { ChargeMath.rangeAddedKm(samples) }

    // MARK: Curves (one source per chart)

    private struct Curve {
        var points: [ChargeCurvePoint]
        var source: ChargeCurve.Source
        var telemetry: TelemetryMetricSeries
    }

    /// Clipped telemetry if it covers the session, otherwise the recorded
    /// samples. The two are never merged into one series.
    private func curve(field: String, telemetryValue: (FleetTelemetrySample) -> Double?,
                       sampleValue: (ChargeSample) -> Double?) -> Curve {
        let series = TelemetryMetricSeries(telemetry, field: field, value: telemetryValue).clipped(start: sessionStart, end: sessionEnd)
        let fromTelemetry = ChargeCurve.points(series, start: sessionStart, end: sessionEnd)
        let fromSamples = ChargeCurve.points(samples.map { (t: $0.t, value: sampleValue($0)) }, start: sessionStart, end: sessionEnd,
                                             breaks: ChargeCurve.boundaries(telemetry, field: field))
        let chosen = ChargeCurve.choose(telemetry: fromTelemetry, samples: fromSamples, start: sessionStart, end: sessionEnd)
        return Curve(points: ChargeCurve.reduced(chosen.points), source: chosen.source, telemetry: series)
    }

    private var powerCurve: Curve { curve(field: "Power", telemetryValue: { $0.powerKw }, sampleValue: { $0.powerKw }) }
    private var socCurve: Curve {
        curve(field: "BatteryLevel", telemetryValue: { $0.batteryLevel }, sampleValue: { $0.batteryLevel.map(Double.init) })
    }

    private var curveCard: some View {
        let power = powerCurve, soc = socCurve
        return HistoryChartCard(title: "Charge curve", systemImage: "bolt.fill") {
            HStack(spacing: 10) {
                legend("kW", color: accent, dashed: false)
                if soc.points.count >= 2 { legend("SoC", color: HistoryTheme.blue.opacity(0.9), dashed: true) }
            }
        } chart: {
            VStack(alignment: .leading, spacing: 10) {
                if let error = loader.error {
                    HistoryChartPlaceholder(message: error) { Task { await load() } }
                } else if loader.detail == nil {
                    HistoryChartPlaceholder()
                } else if power.points.count < 2 {
                    HistoryChartPlaceholder(message: "Power wasn't recorded for this session.")
                } else {
                    ChargeCurveChart(power: power.points, soc: soc.points.count >= 2 ? soc.points : [],
                                     sessionStart: sessionStart, sessionEnd: sessionEnd,
                                     powerColor: accent, socColor: HistoryTheme.blue.opacity(0.9),
                                     summaryPeak: summary.maxPowerKw,
                                     gradient: summary.fastCharger ? [HistoryTheme.mint, HistoryTheme.blue] : nil)
                        .accessibilityIdentifier("charge.curve")
                    sourceNote(power)
                }
            }
        }
    }

    private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: dashed ? 6 : 12, height: 2)
                .overlay(alignment: .trailing) { if dashed { Capsule().fill(color).frame(width: 4, height: 2).offset(x: 7) } }
                .padding(.trailing, dashed ? 6 : 0)
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(HistoryTheme.tertiary)
        }
    }

    @ViewBuilder private func sourceNote(_ curve: Curve) -> some View {
        if curve.source == .telemetry {
            telemetryNote(curve.telemetry)
        } else {
            Text("Recorded samples · \(curve.points.count.formatted()) points")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
        }
    }

    // MARK: Battery temperature

    @ViewBuilder private var temperatureCard: some View {
        let minimum = ChargeCurve.points(TelemetryMetricSeries(telemetry, field: "ModuleTempMin") {
            $0.batteryTempMinC.map { units.temperatureValue(celsius: $0) }
        }, start: sessionStart, end: sessionEnd)
        let maximum = ChargeCurve.points(TelemetryMetricSeries(telemetry, field: "ModuleTempMax") {
            $0.batteryTempMaxC.map { units.temperatureValue(celsius: $0) }
        }, start: sessionStart, end: sessionEnd)
        if minimum.count >= 2 || maximum.count >= 2 {
            let values = (minimum + maximum).map(\.value)
            let range = values.min().flatMap { lo in values.max().map { hi in
                "\(VoltaFormat.number(lo, digits: 0))–\(VoltaFormat.number(hi, digits: 0))\(units.temperatureUnit)"
            } }
            HistoryChartCard(title: "Battery temperature", systemImage: "thermometer.medium") {
                if let range {
                    Text(range).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                }
            } chart: {
                VStack(alignment: .leading, spacing: 10) {
                    ChargeTemperatureChart(minimum: ChargeCurve.reduced(minimum), maximum: ChargeCurve.reduced(maximum),
                                           unit: units.temperatureUnit, sessionStart: sessionStart, sessionEnd: sessionEnd)
                        .accessibilityIdentifier("charge.battery-temperature")
                    HStack(spacing: 12) {
                        legend("MIN", color: HistoryTheme.blue, dashed: false)
                        legend("MAX", color: HistoryTheme.red, dashed: false)
                    }
                }
            }
        }
    }

    // MARK: Other telemetry

    @ViewBuilder private var telemetryCards: some View {
        let energy = clippedTelemetry("EnergyRemaining") { $0.energyRemainingKwh }
        if energy.points.count >= 2 {
            traceCard("Energy remaining", "bolt.batteryblock.fill", unit: "kWh", digits: 1, minPad: 0.5,
                      traces: [.init(label: "Energy", color: HistoryTheme.mint, points: ChargeCurve.reduced(energy.points))],
                      telemetry: [energy.series])
        }
        let inside = clippedTelemetry("InsideTemp") { $0.insideTempC.map { units.temperatureValue(celsius: $0) } }
        let outside = clippedTelemetry("OutsideTemp") { $0.outsideTempC.map { units.temperatureValue(celsius: $0) } }
        if inside.points.count >= 2 || outside.points.count >= 2 {
            traceCard("Cabin & outside", "thermometer.sun.fill", unit: units.temperatureUnit, digits: 0, minPad: 2,
                      traces: [.init(label: "Inside", color: HistoryTheme.amber, points: ChargeCurve.reduced(inside.points)),
                               .init(label: "Outside", color: HistoryTheme.blue, points: ChargeCurve.reduced(outside.points))]
                          .filter { $0.points.count >= 2 },
                      telemetry: [inside.series, outside.series], legend: true)
        }
    }

    /// A telemetry-only signal, clipped to the session.
    private func clippedTelemetry(_ field: String, _ value: (FleetTelemetrySample) -> Double?)
        -> (series: TelemetryMetricSeries, points: [ChargeCurvePoint]) {
        let series = TelemetryMetricSeries(telemetry, field: field, value: value).clipped(start: sessionStart, end: sessionEnd)
        return (series, ChargeCurve.points(series, start: sessionStart, end: sessionEnd))
    }

    private func traceCard(_ title: String, _ icon: String, unit: String, digits: Int, minPad: Double,
                           traces: [ChargeTrace], telemetry: [TelemetryMetricSeries], legend showsLegend: Bool = false) -> some View {
        HistoryChartCard(title: title, systemImage: icon) {
            if showsLegend {
                HStack(spacing: 12) {
                    ForEach(traces) { legend($0.label.uppercased(), color: $0.color, dashed: false) }
                }
            }
        } chart: {
            VStack(alignment: .leading, spacing: 8) {
                ChargeTraceChart(traces: traces, unit: unit, digits: digits, minPad: minPad,
                                 sessionStart: sessionStart, sessionEnd: sessionEnd)
                telemetryNote(telemetry)
            }
        }
    }

    // MARK: Voltage and current

    /// Shown only when the signal actually moved during the session; DC
    /// sessions often report a stale AC reading or nothing at all.
    @ViewBuilder private var electricalCard: some View {
        let voltage = curve(field: "ChargerVoltage", telemetryValue: { $0.voltage }, sampleValue: { $0.voltage })
        let current = curve(field: "ChargeAmps", telemetryValue: { $0.currentA }, sampleValue: { $0.currentA })
        let available = [
            ChargeCurve.isMeaningful(voltage.points, above: 50, requireVariation: summary.fastCharger) ? Electrical.voltage : nil,
            ChargeCurve.isMeaningful(current.points, above: 1, requireVariation: summary.fastCharger) ? Electrical.current : nil,
        ].compactMap { $0 }
        if let first = available.first {
            let shown = available.contains(electrical) ? electrical : first
            let curve = shown == .voltage ? voltage : current
            HistoryChartCard(title: "Charger", systemImage: "powerplug.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    if available.count > 1 {
                        SegmentedRangePicker(selection: $electrical, options: available) { $0.rawValue }
                    }
                    ChargeTraceChart(traces: [.init(label: shown.rawValue, color: shown == .voltage ? HistoryTheme.blue : HistoryTheme.amber,
                                                    points: curve.points)],
                                     unit: shown == .voltage ? "V" : "A", sessionStart: sessionStart, sessionEnd: sessionEnd)
                    sourceNote(curve)
                }
            }
        }
    }

    // MARK: Provenance

    private func telemetryNote(_ series: TelemetryMetricSeries) -> some View { telemetryNote([series]) }

    private func telemetryNote(_ series: [TelemetryMetricSeries]) -> some View {
        let count = series.reduce(0) { $0 + $1.points.count }
        let gapCount = Set(series.flatMap(\.gaps)).count
        let downsampled = series.contains { $0.downsampled }
        let truncated = series.contains { $0.truncated }
        var note = "Fleet Telemetry · \(count.formatted()) recorded sample\(count == 1 ? "" : "s")"
        if gapCount > 0 { note += " · \(gapCount) known gap\(gapCount == 1 ? "" : "s") not joined" }
        if downsampled { note += " · downsampled" }
        if truncated { note += " · history truncated" }
        return Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("charge.telemetry.provenance")
    }
}

// MARK: - Pieces

private struct ChargeBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
    }
}

private struct ChargePin: View {
    var systemImage: String
    var tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22)).frame(width: 50, height: 50)
            Circle().fill(tint).frame(width: 26, height: 26)
                .shadow(color: tint.opacity(0.6), radius: 8)
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
        }
    }
}

/// Grid energy and battery energy as two proportional bars; the gap between
/// them is the loss.
private struct ChargeEnergyBars: View {
    var flow: ChargeEnergyFlow
    var accent: Color

    var body: some View {
        let top = max(flow.gridKwh, flow.addedKwh, 0.001)
        VStack(alignment: .leading, spacing: 8) {
            bar("Grid", value: flow.gridKwh, fraction: flow.gridKwh / top, color: HistoryTheme.amber, dimmed: flow.isEstimated)
            bar("Battery", value: flow.addedKwh, fraction: flow.addedKwh / top, color: accent, dimmed: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(VoltaFormat.energy(flow.gridKwh)) from the grid, \(VoltaFormat.energy(flow.addedKwh)) added to the battery")
    }

    private func bar(_ label: String, value: Double, fraction: Double, color: Color, dimmed: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(HistoryTheme.tertiary)
                .frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                SweepIn { p in
                    ZStack(alignment: .leading) {
                        Capsule().fill(HistoryTheme.track)
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(dimmed ? 0.35 : 0.55), color.opacity(dimmed ? 0.6 : 1)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * min(1, fraction) * p))
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

/// Full-screen interactive map of the charge location (private MapKit tiles only).
struct ChargeLocationMap: View {
    var coordinate: CLLocationCoordinate2D
    var title: String
    var subtitle: String?
    var systemImage: String
    var tint: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1800, heading: 0, pitch: 45))) {
            Annotation("", coordinate: coordinate) { ChargePin(systemImage: systemImage, tint: tint) }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapPitchToggle() }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            HStack(alignment: .center, spacing: 12) {
                GlassCircleButton(systemImage: "xmark", size: 48, accessibilityLabel: "Close map") { dismiss() }
                    .accessibilityIdentifier("charge.map.close")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16).frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Charge detail · home") {
    NavigationStack { ChargingDetailView(charge: MockDataSource.previewCharge()) }
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Charge detail · supercharger") {
    NavigationStack { ChargingDetailView(charge: MockDataSource.previewCharge(fast: true)) }
        .environment(\.dataSource, MockDataSource())
        .preferredColorScheme(.dark)
}

#Preview("Charge detail · error") {
    NavigationStack { ChargingDetailView(charge: MockDataSource.previewCharge()) }
        .environment(\.dataSource, HistoryPreviewFailingSource())
        .preferredColorScheme(.dark)
}
