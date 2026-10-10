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
    @State private var loader = HistoryDetailLoader<ChargeDetail>()
    @State private var places = HistoryPlaces()
    @State private var series: Series = .power

    enum Series: String, CaseIterable, Hashable {
        case power = "Power", voltage = "Volts", current = "Amps"
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryDetailHeader(title: "Charge")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero.padding(.bottom, 16)
                    HistoryLocationCard(location: charge.location(places.state), address: charge.address,
                                        systemImage: charge.kindIcon, tint: charge.kindTint) {
                        Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
                    }
                    .voltaCascade(index: 0)
                    curveCard.voltaCascade(index: 1)
                    socCard.voltaCascade(index: 2)
                    telemetryCards.voltaCascade(index: 3)
                    costCard.voltaCascade(index: 4)
                }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .voltaArrivalScope()
        }
        .historyGlow(charge.fastCharger ? HistoryTheme.blue : HistoryTheme.mint, charge.fastCharger ? HistoryTheme.mint : HistoryTheme.blue, strength: 0.14)
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .task { if charge.needsPlaces { await places.load(dataSource: dataSource, vehicleID: vehicleID) } }
    }

    private func load() async {
        let ds = dataSource, id = charge.id
        await loader.load { try await ds.charge(id: id) }
    }

    private var samples: [ChargeSample] { loader.detail?.samples ?? [] }
    private var telemetry: FleetTelemetrySeries? { loader.detail?.telemetry }
    private var sessionEnd: Date { charge.end ?? charge.start.addingTimeInterval(charge.durationMin * 60) }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow).voltaLabelStyle(color: HistoryTheme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 8) {
                    Text(charge.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.charge-detail")
                    currentChip
                }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HistoryHeroNumeral(value: charge.energyAddedKwh.map { VoltaFormat.number($0) } ?? "—", unit: "kWh")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(HistoryTheme.amber).frame(width: 5, height: 5).shadow(color: HistoryTheme.amber, radius: 3)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(VoltaFormat.money(charge.cost, currency: charge.currency ?? units.currency))
                            .font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        if let rate = ratePerKwh {
                            Text("· \(rate) / kWh").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                SocDial(from: charge.startBatteryLevel, to: charge.endBatteryLevel, size: 96,
                        caption: charge.startBatteryLevel.map { "from \($0)%" } ?? "Battery",
                        colors: charge.fastCharger ? [HistoryTheme.mint, HistoryTheme.blue] : [HistoryTheme.mint.opacity(0.6), HistoryTheme.mint])
                    .padding(.trailing, 4)
            }
            stats
        }
        .padding(.top, 6)
    }

    private var currentChip: some View {
        HStack(spacing: 4) {
            Image(systemName: charge.fastCharger ? "bolt.fill" : "powerplug.portrait.fill").font(.system(size: 9, weight: .bold))
            Text(charge.fastCharger ? "DC FAST" : "AC").font(.system(size: 10, weight: .bold)).tracking(1)
        }
        .foregroundStyle(charge.currentTint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(charge.currentTint.opacity(0.1), in: .capsule)
        .overlay(Capsule().strokeBorder(charge.currentTint.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }

    private var eyebrow: String {
        let day = charge.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let end = charge.end.map { " – " + $0.historyTime } ?? " – now"
        return "\(day) · \(charge.start.historyTime)\(end)"
    }

    private var ratePerKwh: String? {
        guard let cost = charge.cost, let kwh = charge.energyUsedKwh ?? charge.energyAddedKwh, kwh > 0 else { return nil }
        return VoltaFormat.money(cost / kwh, currency: charge.currency ?? units.currency)
    }

    // MARK: Stats

    private var averagePowerKw: Double? {
        let powers = samples.compactMap(\.powerKw).filter { $0 > 0.2 }
        return powers.isEmpty ? (charge.energyAddedKwh.map { $0 / max(charge.durationMin / 60, 0.01) }) : powers.reduce(0, +) / Double(powers.count)
    }

    private var stats: some View {
        let rangeAdded = rangeAddedKm
        return HistoryStatStrip(items: [
            .init(value: VoltaFormat.duration(charge.durationMin), caption: "Duration"),
            .init(value: charge.maxPowerKw.map { VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1) } ?? "—", caption: "Peak kW",
                  accent: charge.fastCharger ? HistoryTheme.blue : HistoryTheme.mint),
            .init(value: rangeAdded.map { ($0 < 0 ? "−" : "+") + VoltaFormat.number(units.distanceValue(km: abs($0)), digits: 0) } ?? "—",
                  caption: "Range \(units.distanceUnit)"),
            .init(value: charge.outsideTempAvgC.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) + "°" } ?? "—", caption: "Outside"),
        ])
    }

    private var efficiencyFromSummary: Double? {
        guard let added = charge.energyAddedKwh, let used = charge.energyUsedKwh, used > 0 else { return nil }
        return added / used
    }

    // MARK: Charts

    private var curveCard: some View {
        let field = switch series { case .power: "Power"; case .voltage: "ChargerVoltage"; case .current: "ChargeAmps" }
        let metric = switch series { case .power: "powerKw"; case .voltage: "voltage"; case .current: "currentA" }
        let telemetrySeries = TelemetryMetricSeries(telemetry, field: field) { sample in
            switch series {
            case .power: sample.powerKw
            case .voltage: sample.voltage
            case .current: sample.currentA
            }
        }
        let points: [HistoryChartPoint] = samples.compactMap { s in
            let v: Double? = switch series {
            case .power: s.powerKw
            case .voltage: s.voltage
            case .current: s.currentA
            }
            return v.map { HistoryChartPoint(t: s.t, value: $0) }
        }
        let unit = switch series { case .power: "kW"; case .voltage: "V"; case .current: "A" }
        let color = switch series { case .power: charge.fastCharger ? HistoryTheme.blue : HistoryTheme.mint; case .voltage: HistoryTheme.blue; case .current: HistoryTheme.amber }
        let useTelemetry = telemetry?.shouldPrefer(
            metric: metric,
            over: .dates(points.map(\.t), sessionStart: charge.start, sessionEnd: sessionEnd)
        ) == true
        return HistoryChartCard(title: "Charge curve", systemImage: "bolt.fill") {
            if series == .power, let avg = averagePowerKw {
                Text("avg \(VoltaFormat.number(avg, digits: avg >= 20 ? 0 : 1)) kW").voltaLabelStyle(color: HistoryTheme.tertiary).tracking(1)
            }
        } chart: {
            VStack(alignment: .leading, spacing: 14) {
                SegmentedRangePicker(selection: $series, options: Series.allCases) { $0.rawValue }
                if useTelemetry, !telemetrySeries.isEmpty {
                    TelemetryMetricChart(traces: [.init(label: series.rawValue, color: color, series: telemetrySeries)],
                                         unit: unit, domain: TripChartDomain.zeroBased(telemetrySeries.values),
                                         sessionStart: charge.start, sessionEnd: sessionEnd,
                                         digits: series == .power ? 1 : 0, showsZero: series == .power)
                    telemetryNote(telemetrySeries)
                } else {
                    chartBody(points: points, color: color, unit: unit, digits: series == .power ? 1 : 0,
                              gradient: series == .power && charge.fastCharger ? [HistoryTheme.mint, HistoryTheme.blue] : nil)
                }
            }
        }
    }

    private var socCard: some View {
        let telemetrySeries = TelemetryMetricSeries(telemetry, field: "BatteryLevel") { $0.batteryLevel }
        let points = samples.compactMap { s in s.batteryLevel.map { HistoryChartPoint(t: s.t, value: Double($0)) } }
        let useTelemetry = telemetry?.shouldPrefer(
            metric: "batteryLevel",
            over: .dates(points.map(\.t), sessionStart: charge.start, sessionEnd: sessionEnd)
        ) == true
        return HistoryChartCard(title: "State of charge", systemImage: "battery.75percent",
                                value: charge.endBatteryLevel.map(String.init), unit: "%") {
            if useTelemetry, !telemetrySeries.isEmpty {
                TelemetryMetricChart(traces: [.init(label: "Battery", color: HistoryTheme.blue, series: telemetrySeries)],
                                     unit: "%", domain: 0...100, sessionStart: charge.start,
                                     sessionEnd: sessionEnd, digits: 0)
                telemetryNote(telemetrySeries)
            } else {
                chartBody(points: points, color: HistoryTheme.blue, unit: "%", yDomain: 0...100)
            }
        }
    }

    @ViewBuilder private var telemetryCards: some View {
        let energy = TelemetryMetricSeries(telemetry, field: "EnergyRemaining") { $0.energyRemainingKwh }
        if !energy.isEmpty {
            telemetryCard("Energy remaining", "bolt.batteryblock.fill", "kWh",
                          traces: [.init(label: "Energy", color: HistoryTheme.mint, series: energy)], digits: 1)
        }
        let minimum = TelemetryMetricSeries(telemetry, field: "ModuleTempMin") { $0.batteryTempMinC.map { units.temperatureValue(celsius: $0) } }
        let maximum = TelemetryMetricSeries(telemetry, field: "ModuleTempMax") { $0.batteryTempMaxC.map { units.temperatureValue(celsius: $0) } }
        if !minimum.isEmpty || !maximum.isEmpty {
            telemetryCard("Battery temperature", "thermometer.medium", units.temperatureUnit,
                          traces: [.init(label: "Min", color: HistoryTheme.blue, series: minimum),
                                   .init(label: "Max", color: HistoryTheme.red, series: maximum)], digits: 1)
        }
        let inside = TelemetryMetricSeries(telemetry, field: "InsideTemp") { $0.insideTempC.map { units.temperatureValue(celsius: $0) } }
        let outside = TelemetryMetricSeries(telemetry, field: "OutsideTemp") { $0.outsideTempC.map { units.temperatureValue(celsius: $0) } }
        if !inside.isEmpty || !outside.isEmpty {
            telemetryCard("Cabin & outside", "thermometer.sun.fill", units.temperatureUnit,
                          traces: [.init(label: "Inside", color: HistoryTheme.amber, series: inside),
                                   .init(label: "Outside", color: HistoryTheme.blue, series: outside)], digits: 1)
        }
    }

    private func telemetryCard(_ title: String, _ icon: String, _ unit: String,
                               traces: [TelemetryTrace], digits: Int) -> some View {
        let values = traces.flatMap(\.series.values)
        return HistoryChartCard(title: title, systemImage: icon) {
            VStack(alignment: .leading, spacing: 8) {
                TelemetryMetricChart(traces: traces, unit: unit,
                                     domain: TripChartDomain.padded(values, minPad: unit == "kWh" ? 0.5 : 2),
                                     sessionStart: charge.start, sessionEnd: sessionEnd, digits: digits)
                telemetryNote(traces.map(\.series))
            }
        }
    }

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

    @ViewBuilder
    private func chartBody(points: [HistoryChartPoint], color: Color, unit: String, yDomain: ClosedRange<Double>? = nil, digits: Int = 0,
                           gradient: [Color]? = nil) -> some View {
        if let error = loader.error {
            HistoryChartPlaceholder(message: error) { Task { await load() } }
        } else if loader.detail == nil {
            HistoryChartPlaceholder()
        } else if points.count < 2 {
            HistoryChartPlaceholder(message: "Not recorded for this session.")
        } else {
            HistoryLineChart(points: points, color: color, unit: unit, yDomain: yDomain, digits: digits, gradient: gradient)
        }
    }

    // MARK: Cost

    private var costCard: some View {
        let currency = charge.currency ?? units.currency
        let lost: Double? = {
            guard let used = charge.energyUsedKwh, let added = charge.energyAddedKwh else { return nil }
            return max(0, used - added)
        }()
        let rate: Double? = {
            guard let cost = charge.cost, let kwh = charge.energyUsedKwh ?? charge.energyAddedKwh, kwh > 0 else { return nil }
            return cost / kwh
        }()
        let perDistance: String? = {
            guard let cost = charge.cost, let samplesRange = rangeAddedKm, samplesRange > 1 else { return nil }
            let per100 = cost / units.distanceValue(km: samplesRange) * 100
            return VoltaFormat.money(per100, currency: currency) + " / 100 \(units.distanceUnit)"
        }()
        let efficiency = loader.detail?.efficiency ?? efficiencyFromSummary
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Energy & cost").voltaLabelStyle(color: HistoryTheme.tertiary)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(HistoryTheme.amber).frame(width: 4, height: 4)
                    Text("Total").font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(HistoryTheme.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(rate.map { VoltaFormat.money($0, currency: currency) + " / kWh" } ?? "Rate unknown")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                Spacer()
                Text(VoltaFormat.money(charge.cost, currency: currency))
                    .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.top, 10).padding(.bottom, 14)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            costRow("Energy added", VoltaFormat.energy(charge.energyAddedKwh))
            HairlineDivider()
            costRow("Drawn from charger", VoltaFormat.energy(charge.energyUsedKwh))
            HairlineDivider()
            costRow("Charging losses", lost.map { l in
                let pct = charge.energyUsedKwh.map { $0 > 0 ? " · \(VoltaFormat.number(l / $0 * 100, digits: 0))%" : "" } ?? ""
                return VoltaFormat.energy(l) + pct
            } ?? "—", secondary: true)
            HairlineDivider()
            costRow("Efficiency", efficiency.map { VoltaFormat.number($0 * 100, digits: 0) + "%" } ?? "—", secondary: true)
            if let perDistance {
                HairlineDivider()
                costRow("Cost per distance", perDistance, secondary: true)
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
        .driveSurface()
    }

    private var rangeAddedKm: Double? { ChargeMath.rangeAddedKm(samples) }

    private func costRow(_ label: String, _ value: String, secondary: Bool = false) -> some View {
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
