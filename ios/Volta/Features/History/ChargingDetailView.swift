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
    @State private var editingRate = false

    enum Electrical: String, CaseIterable, Hashable {
        case voltage = "Volts", current = "Amps"
    }

    /// The map runs under the status bar and header to about 40% of the screen.
    private static let mapHeight: CGFloat = 365
    /// The bottom of the map that fades into the page; MapKit's attribution sits above it.
    private static let mapFade: CGFloat = 56
    static let margin: CGFloat = 28

    /// The detail's summary when loaded (it may carry fields the list row lacks).
    private var summary: ChargeSummary { loader.detail?.summary ?? charge }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    mapBackdrop
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                        VStack(alignment: .leading, spacing: 52) {
                            energySection
                            curveSection
                                .background(alignment: .top) { Color.clear.frame(height: 0).offset(y: -24).id(ScrollTarget.curve) }
                            temperatureSection
                            telemetrySections
                            electricalSection
                            detailsSection
                        }
                        .padding(.top, 45)
                        Color.clear.frame(height: 1).id(ScrollTarget.bottom)
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 10)
                }
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.charge-detail")
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) { header }
            #if DEBUG
            .task(id: loader.detail != nil) { await debugScroll(proxy) }
            #endif
        }
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingMap) {
            if let coordinate = location.coordinate {
                ChargeLocationMap(coordinate: coordinate, title: ChargePlace.title(summary), subtitle: ChargePlace.subtitle(summary))
            }
        }
        .electricityRateSheet(isPresented: $editingRate, settings: model?.settings)
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
    private var rates: ElectricityRates { model?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency) }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [HistoryTheme.background.opacity(0.55), HistoryTheme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                ChargeBackButton()
                Spacer(minLength: 0)
                Button { editingRate = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tag").font(.system(size: 14, weight: .medium))
                        Text("Price").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 44)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Electricity rate")
                .accessibilityIdentifier("charge.price")
                if location.coordinate != nil {
                    GlassCircleButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 44, accessibilityLabel: "Expand map") {
                        showingMap = true
                    }
                    .accessibilityIdentifier("charge.map.expand")
                }
            }
            .padding(.horizontal, HistoryTheme.gutter - 6)
            .padding(.bottom, 8)
        }
    }

    // MARK: Map backdrop

    /// Private MapKit tiles centred on the recorded or geofence coordinate,
    /// under the header. Nothing is geocoded or searched.
    private var mapBackdrop: some View {
        Group {
            switch location {
            case .known:
                if let coordinate = location.coordinate {
                    // Centred below the header; the Maps logo and Legal link stay above the fade.
                    GreyTileMap(framing: .camera(coordinate, distance: 1500),
                                insets: EdgeInsets(top: 100, leading: 0, bottom: Self.mapFade, trailing: 0),
                                dim: 0.1) { ChargePin() }
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
                mapPlaceholder(nil)
            }
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [HistoryTheme.background.opacity(0), HistoryTheme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.mapFade)
                .allowsHitTesting(false)
        }
        .frame(height: Self.mapHeight)
        .clipped()
    }

    private func mapPlaceholder(_ message: String?, loading: Bool = false, retry: Bool = false) -> some View {
        ZStack {
            HistoryTheme.background
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
            .padding(.top, 40)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ChargePlace.title(summary))
                .font(.system(size: 17.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.charge-detail")
            HStack(spacing: 8) {
                ChargePlaceBadge(charge: summary, size: 16)
                Text(ChargePlace.subtitle(summary) ?? summary.currentLabel)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.top, 5)

            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.energyAddedKwh.map { "+" + VoltaFormat.number($0) } ?? "—")
                        .font(.system(size: 47, weight: .bold)).tracking(-0.5)
                        .monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("kWh").font(.system(size: 15, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                costBlock.padding(.top, 2.3)
            }
            .padding(.top, 28)

            if let bar = ChargeSocBar(start: summary.startBatteryLevel, end: summary.endBatteryLevel) {
                ChargeSocBarView(bar: bar, numberSize: 13.5).padding(.top, 14.7)
            }
            if let km = rangeAddedKm {
                Text("\(km < 0 ? "−" : "+")\(VoltaFormat.number(units.distanceValue(km: abs(km)), digits: 0)) \(units.distanceUnit) of range")
                    .font(.system(size: 10.5, weight: .regular)).monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, 5.3)
            }
            dateLine
                .padding(.top, 28)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.top, 21)
        }
    }

    /// Cost on the right of the energy numeral: the amount over its rate, or
    /// "—" with a way to add the missing rate.
    @ViewBuilder private var costBlock: some View {
        if let cost = costEstimate {
            VStack(alignment: .trailing, spacing: 1.7) {
                Text(VoltaFormat.money(cost.amount, currency: cost.currency))
                    .font(.system(size: 27, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .accessibilityIdentifier("charge.cost")
                HStack(spacing: 5) {
                    if cost.isEstimated { Text("Est.").foregroundStyle(HistoryTheme.amber) }
                    if let rate = cost.pricePerKwh {
                        Text(Self.rateText(rate, currency: cost.currency) + "/kWh").foregroundStyle(HistoryTheme.secondary)
                    }
                }
                .font(.system(size: 13.5, weight: .medium)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Text("—")
                    .font(.system(size: 27, weight: .bold)).foregroundStyle(HistoryTheme.secondary)
                    .accessibilityLabel("Cost unknown")
                    .accessibilityIdentifier("charge.cost")
                if summary.energyAddedKwh != nil { SetRateButton(settings: model?.settings, size: 13.5, link: true) }
            }
        }
    }

    /// Per-kWh prices read to a tenth of a cent, as "$0.300".
    static func rateText(_ rate: Double, currency: String) -> String {
        rate.formatted(.currency(code: currency).precision(.fractionLength(3)))
    }

    /// "Saturday, October 10 · 00:05 → 00:33 · 28 min" in the app's time format.
    private var dateLine: some View {
        let dot = Text("  ·  ").foregroundStyle(HistoryTheme.tertiary)
        let arrow = Text(" → ").foregroundStyle(HistoryTheme.tertiary)
        let day = Text(summary.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        let end = summary.end?.historyTime ?? "now"
        return Text("\(day)\(dot)\(summary.start.historyTime)\(arrow)\(end)\(dot)\(VoltaFormat.longDuration(summary.durationMin))")
            .font(.system(size: 10.5, weight: .regular)).monospacedDigit()
            .foregroundStyle(HistoryTheme.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
    }

    // MARK: Power

    private var averagePowerKw: Double? {
        if let avg = summary.avgPowerKw, avg.isFinite, avg > 0 { return avg }
        let powers = powerCurve.points.map(\.value).filter { $0 > 0.2 }
        if !powers.isEmpty { return powers.reduce(0, +) / Double(powers.count) }
        return summary.energyAddedKwh.map { $0 / max(summary.durationMin / 60, 0.01) }
    }

    private var peakPowerKw: Double? {
        [summary.maxPowerKw, ChargeCurve.peak(powerCurve.points)?.value].compactMap { $0 }.filter(\.isFinite).max()
    }

    private func kw(_ value: Double) -> String { VoltaFormat.number(value, digits: value >= 20 ? 0 : 1) }

    // MARK: Cost

    private var costEstimate: ChargeCost? { ChargeCost.resolve(summary, rates: rates) }

    private func estimateNote(_ cost: ChargeCost) -> String {
        let rateText = VoltaFormat.money(cost.pricePerKwh, currency: cost.currency) + "/kWh"
        guard summary.fastCharger else {
            return "No price was recorded. Estimated from energy drawn from the grid at your home rate of \(rateText)."
        }
        return rates.dcFast != nil
            ? "No price was recorded for this fast charge. Estimated at your Supercharger / DC fast rate of \(rateText)."
            : "No price was recorded for this fast charge. Estimated at your home rate of \(rateText); network pricing is usually higher."
    }

    // MARK: Energy flow

    @ViewBuilder private var energySection: some View {
        if let flow = ChargeEnergyFlow.resolve(summary) {
            VStack(alignment: .leading, spacing: 0) {
                DetailSectionHeader(title: Text("ENERGY FLOW")) {
                    if flow.isEstimated {
                        Text("Estimated")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.amber)
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .overlay(Capsule().strokeBorder(HistoryTheme.amber.opacity(0.55), lineWidth: 1))
                            .accessibilityLabel("Estimated at \(Int(ChargeEnergyFlow.assumedEfficiency * 100))% charging efficiency")
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("From grid").font(.system(size: 10.5, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                    Spacer()
                    energyValue(flow.gridKwh, size: 15)
                }
                .padding(.top, 16)
                ChargeEnergyBar(flow: flow).padding(.top, 9)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        energyValue(flow.addedKwh, size: 13)
                        Text("Added to battery").font(.system(size: 10.5, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        energyValue(flow.lossKwh, size: 13, dim: true)
                        Text("Lost").font(.system(size: 10.5, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func energyValue(_ kwh: Double, size: CGFloat, dim: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(VoltaFormat.number(kwh)).font(.system(size: size, weight: .semibold)).monospacedDigit()
                .foregroundStyle(dim ? HistoryTheme.secondary : .white)
            Text("kWh").font(.system(size: 10.5, weight: .regular)).foregroundStyle(HistoryTheme.secondary)
        }
    }

    private var rangeAddedKm: Double? { ChargeMath.rangeAddedKm(samples) }

    // MARK: Details

    private var detailsSection: some View {
        let cost = costEstimate
        let flow = ChargeEnergyFlow.resolve(summary)
        let perDistance: String? = {
            guard let cost, let km = rangeAddedKm, km > 1 else { return nil }
            return VoltaFormat.money(cost.amount / units.distanceValue(km: km) * 100, currency: cost.currency) + " / 100 \(units.distanceUnit)"
        }()
        let peak: String = peakPowerKw.map { kw($0) + " kW" } ?? "—"
        let average: String = averagePowerKw.map { kw($0) + " kW" } ?? "—"
        var efficiency = "—"
        if let flow, let value = flow.efficiency {
            efficiency = VoltaFormat.number(value * 100, digits: 0) + "%" + (flow.isEstimated ? " est." : "")
        }
        var rows: [(String, String)] = [
            ("Duration", VoltaFormat.duration(summary.durationMin)),
            ("Peak power", peak),
            ("Average power", average),
            ("Charger", summary.currentLabel),
            ("Efficiency", efficiency),
        ]
        if let perDistance { rows.append(("Cost per distance", perDistance)) }
        return VStack(alignment: .leading, spacing: 0) {
            DetailSectionHeader(title: Text("DETAILS")) { EmptyView() }
                .padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0).font(.system(size: 16, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    Spacer()
                    Text(row.1).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                }
                .padding(.vertical, 14)
                if index < rows.count - 1 { Rectangle().fill(HistoryTheme.hairline).frame(height: 1) }
            }
            if let cost, cost.isEstimated {
                Text(estimateNote(cost))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }

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
        let chosen = ChargeCurve.curve(telemetry: telemetry, samples: samples, field: field, start: sessionStart, end: sessionEnd,
                                       telemetryValue: telemetryValue, sampleValue: sampleValue)
        return Curve(points: ChargeCurve.reduced(chosen.points), source: chosen.source, telemetry: chosen.series)
    }

    private var powerCurve: Curve { curve(field: "Power", telemetryValue: { $0.powerKw }, sampleValue: { $0.powerKw }) }
    private var socCurve: Curve {
        curve(field: "BatteryLevel", telemetryValue: { $0.batteryLevel }, sampleValue: { $0.batteryLevel.map(Double.init) })
    }

    private var curveSection: some View {
        let power = powerCurve, soc = socCurve
        let socAtPeak = peakPowerKw.flatMap { ChargeCurve.socAtPeak(power: power.points, soc: soc.points, shownPeak: $0) }
        let title = unitTitle("Charge curve", [("kW", HistoryTheme.green)] + (soc.points.count >= 2 ? [("%", HistoryTheme.blue)] : []))
        return VStack(alignment: .leading, spacing: 14) {
            DetailSectionHeader(title: title) {
                if let peakPowerKw, power.points.count >= 2 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        peakValue(kw(peakPowerKw), color: HistoryTheme.green)
                        if let socAtPeak { peakValue("\(Int(socAtPeak.rounded()))%", color: HistoryTheme.blue) }
                        Text("peak").font(.system(size: 15, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    }
                }
            }
            if let error = loader.error {
                HistoryChartPlaceholder(message: error) { Task { await load() } }
            } else if loader.detail == nil {
                HistoryChartPlaceholder()
            } else if power.points.count < 2 {
                HistoryChartPlaceholder(message: "Power wasn't recorded for this session.")
            } else {
                ChargeCurveChart(power: power.points, soc: soc.points.count >= 2 ? soc.points : [],
                                 sessionStart: sessionStart, sessionEnd: sessionEnd,
                                 powerColor: HistoryTheme.green, socColor: HistoryTheme.blue,
                                 summaryPeak: summary.maxPowerKw, height: 230)
                    .accessibilityIdentifier("charge.curve")
                sourceNote(power)
            }
        }
    }

    /// "Charge curve · kW · %": the section name, then each unit in its series color.
    private func unitTitle(_ title: String, _ parts: [(unit: String, color: Color)]) -> Text {
        parts.reduce(Text(title.uppercased())) { text, part in
            Text("\(text)\(Text("  ·  ").foregroundStyle(HistoryTheme.tertiary))\(Text(part.unit).foregroundStyle(part.color).tracking(0))")
        }
    }

    private func peakValue(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2)
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

    @ViewBuilder private var temperatureSection: some View {
        let minimum = ChargeCurve.points(TelemetryMetricSeries(telemetry, field: "ModuleTempMin") {
            $0.batteryTempMinC.map { units.temperatureValue(celsius: $0) }
        }, start: sessionStart, end: sessionEnd)
        let maximum = ChargeCurve.points(TelemetryMetricSeries(telemetry, field: "ModuleTempMax") {
            $0.batteryTempMaxC.map { units.temperatureValue(celsius: $0) }
        }, start: sessionStart, end: sessionEnd)
        if minimum.count >= 2 || maximum.count >= 2 {
            let peak = (maximum.count >= 2 ? maximum : minimum).map(\.value).max()
            let title = unitTitle("Battery temperature", [(units.temperatureUnit, HistoryTheme.amber)])
            VStack(alignment: .leading, spacing: 14) {
                DetailSectionHeader(title: title) {
                    if let peak {
                        Text("Peak \(VoltaFormat.number(peak, digits: 0))°")
                            .font(.system(size: 14, weight: .semibold)).tracking(2.4).textCase(.uppercase).monospacedDigit()
                            .foregroundStyle(HistoryTheme.amber)
                    }
                }
                ChargeTemperatureChart(minimum: ChargeCurve.reduced(minimum), maximum: ChargeCurve.reduced(maximum),
                                       unit: units.temperatureUnit, sessionStart: sessionStart, sessionEnd: sessionEnd)
                    .accessibilityIdentifier("charge.battery-temperature")
                if minimum.count >= 2 && maximum.count >= 2 {
                    HStack(spacing: 12) {
                        legend("WARMEST MODULE", color: HistoryTheme.amber)
                        legend("COOLEST", color: HistoryTheme.amber.opacity(0.45))
                    }
                }
            }
        }
    }

    // MARK: Other telemetry

    @ViewBuilder private var telemetrySections: some View {
        let energy = clippedTelemetry("EnergyRemaining") { $0.energyRemainingKwh }
        if energy.points.count >= 2 {
            traceSection("Energy remaining", unit: "kWh", digits: 1, minPad: 0.5,
                         traces: [.init(label: "Energy", color: HistoryTheme.green, points: ChargeCurve.reduced(energy.points))],
                         telemetry: [energy.series])
        }
        let inside = clippedTelemetry("InsideTemp") { $0.insideTempC.map { units.temperatureValue(celsius: $0) } }
        let outside = clippedTelemetry("OutsideTemp") { $0.outsideTempC.map { units.temperatureValue(celsius: $0) } }
        if inside.points.count >= 2 || outside.points.count >= 2 {
            traceSection("Cabin & outside", unit: units.temperatureUnit, digits: 0, minPad: 2,
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

    private func traceSection(_ title: String, unit: String, digits: Int, minPad: Double,
                              traces: [ChargeTrace], telemetry: [TelemetryMetricSeries], legend showsLegend: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSectionHeader(title: unitTitle(title, [(unit, traces.first?.color ?? HistoryTheme.secondary)])) {
                if showsLegend {
                    HStack(spacing: 12) {
                        ForEach(traces) { legend($0.label.uppercased(), color: $0.color) }
                    }
                }
            }
            ChargeTraceChart(traces: traces, unit: unit, digits: digits, minPad: minPad,
                             sessionStart: sessionStart, sessionEnd: sessionEnd, height: 140)
            telemetryNote(telemetry)
        }
    }

    // MARK: Voltage and current

    /// Shown only when the signal actually moved during the session; DC
    /// sessions often report a stale AC reading or nothing at all.
    @ViewBuilder private var electricalSection: some View {
        let voltage = curve(field: "ChargerVoltage", telemetryValue: { $0.voltage }, sampleValue: { $0.voltage })
        let current = curve(field: "ChargeAmps", telemetryValue: { $0.currentA }, sampleValue: { $0.currentA })
        let available = [
            ChargeCurve.isMeaningful(voltage.points, above: 50, requireVariation: summary.fastCharger) ? Electrical.voltage : nil,
            ChargeCurve.isMeaningful(current.points, above: 1, requireVariation: summary.fastCharger) ? Electrical.current : nil,
        ].compactMap { $0 }
        if let first = available.first {
            let shown = available.contains(electrical) ? electrical : first
            let curve = shown == .voltage ? voltage : current
            let tint = shown == .voltage ? HistoryTheme.blue : HistoryTheme.amber
            VStack(alignment: .leading, spacing: 14) {
                DetailSectionHeader(title: unitTitle("Charger", [(shown == .voltage ? "V" : "A", tint)])) { EmptyView() }
                if available.count > 1 {
                    SegmentedRangePicker(selection: $electrical, options: available) { $0.rawValue }
                }
                ChargeTraceChart(traces: [.init(label: shown.rawValue, color: tint, points: curve.points)],
                                 unit: shown == .voltage ? "V" : "A", sessionStart: sessionStart, sessionEnd: sessionEnd, height: 140)
                sourceNote(curve)
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
        GlassCircleButton(systemImage: "chevron.left", size: 44, accessibilityLabel: "Back") { dismiss() }
    }
}

/// Plain red location dot with a white ring.
private struct ChargePin: View {
    var body: some View {
        Circle().fill(HistoryTheme.pin)
            .frame(width: 29, height: 29)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }
}

/// Tracked section title with an optional trailing accessory. Callers pass the
/// name uppercased so units like "kW" keep their case.
private struct DetailSectionHeader<Trailing: View>: View {
    var title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            title
                .font(.system(size: 10, weight: .semibold)).tracking(2.5)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Grid energy as one bar: the share that reached the battery, labelled with
/// its percentage, then the loss as a grey remainder.
private struct ChargeEnergyBar: View {
    var flow: ChargeEnergyFlow

    var body: some View {
        let share = min(1, max(0, flow.efficiency ?? 1))
        GeometryReader { geo in
            let gap: CGFloat = share < 1 ? 6 : 0
            let filled = max(44, (geo.size.width - gap) * share)
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(HistoryTheme.green)
                    .frame(width: filled)
                    .overlay(alignment: .leading) {
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.black.opacity(0.8))
                            .padding(.leading, 8)
                    }
                if share < 1 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.2))
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(VoltaFormat.energy(flow.gridKwh)) from the grid, \(VoltaFormat.energy(flow.addedKwh)) added to the battery")
    }
}

/// Full-screen interactive map of the charge location (private MapKit tiles only).
struct ChargeLocationMap: View {
    var coordinate: CLLocationCoordinate2D
    var title: String
    var subtitle: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1800, heading: 0, pitch: 45))) {
            Annotation("", coordinate: coordinate) { ChargePin() }
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
