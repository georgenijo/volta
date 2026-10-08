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
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    HistoryLocationCard(location: charge.location(places.state), address: charge.address,
                                        systemImage: charge.kindIcon, tint: charge.kindTint) {
                        Task { await places.retry(dataSource: dataSource, vehicleID: vehicleID) }
                    }
                    stats
                    curveCard
                    socCard
                    telemetryCards
                    costCard
                }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HistoryIconTile(systemImage: charge.kindIcon, tint: charge.kindTint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(charge.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("screen.charge-detail")
                        if charge.fastCharger {
                            HistoryBadge(title: "DC Fast", systemImage: "bolt.fill", tint: HistoryTheme.amber)
                        }
                    }
                    Text(timeLine)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            HStack(alignment: .lastTextBaseline) {
                BigNumber(charge.energyAddedKwh.map { "+" + VoltaFormat.number($0) } ?? "—", unit: "kWh", size: 56)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("COST").voltaLabelStyle()
                    BigNumber(VoltaFormat.money(charge.cost, currency: charge.currency ?? units.currency), size: 26)
                }
            }
            BatteryRangeView(from: charge.batteryEndpoints.from, to: charge.batteryEndpoints.to, tint: HistoryTheme.green)
        }
        .padding(.vertical, 6)
    }

    private var timeLine: String {
        let day = charge.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let end = charge.end.map { " – " + $0.historyTime } ?? " – now"
        let place = charge.address.flatMap { $0 == charge.title ? nil : " · " + $0 } ?? ""
        return "\(day) · \(charge.start.historyTime)\(end)\(place)"
    }

    // MARK: Stats

    private var stats: some View {
        let powers = samples.compactMap(\.powerKw).filter { $0 > 0.2 }
        let avgPower = powers.isEmpty ? (charge.energyAddedKwh.map { $0 / max(charge.durationMin / 60, 0.01) }) : powers.reduce(0, +) / Double(powers.count)
        let rangeAdded = rangeAddedKm
        let efficiency = loader.detail?.efficiency ?? efficiencyFromSummary
        return HistoryStatGrid(items: [
            .init(label: "Duration", value: VoltaFormat.duration(charge.durationMin), systemImage: "clock"),
            .init(label: "Max", value: charge.maxPowerKw.map { VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1) } ?? "—", unit: "kW", systemImage: "gauge.with.dots.needle.67percent"),
            .init(label: "Avg", value: avgPower.map { VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1) } ?? "—", unit: "kW", systemImage: "gauge.with.dots.needle.33percent"),
            .init(label: "Range", value: rangeAdded.map { ($0 < 0 ? "−" : "+") + VoltaFormat.number(units.distanceValue(km: abs($0)), digits: 0) } ?? "—", unit: units.distanceUnit, systemImage: "road.lanes"),
            .init(label: "Outside", value: charge.outsideTempAvgC.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—", unit: units.temperatureUnit, systemImage: "thermometer.medium"),
            .init(label: "Efficiency", value: efficiency.map { VoltaFormat.number($0 * 100, digits: 0) } ?? "—", unit: "%", systemImage: "leaf"),
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
        let color = switch series { case .power: HistoryTheme.green; case .voltage: HistoryTheme.blue; case .current: HistoryTheme.amber }
        let useTelemetry = telemetry?.shouldPrefer(
            metric: metric,
            over: .dates(points.map(\.t), sessionStart: charge.start, sessionEnd: sessionEnd)
        ) == true
        return HistoryChartCard(title: "Charge curve", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: 14) {
                SegmentedRangePicker(selection: $series, options: Series.allCases) { $0.rawValue }
                if useTelemetry, !telemetrySeries.isEmpty {
                    TelemetryMetricChart(traces: [.init(label: series.rawValue, color: color, series: telemetrySeries)],
                                         unit: unit, domain: TripChartDomain.zeroBased(telemetrySeries.values),
                                         sessionStart: charge.start, sessionEnd: sessionEnd,
                                         digits: series == .power ? 1 : 0, showsZero: series == .power)
                    telemetryNote(telemetrySeries)
                } else {
                    chartBody(points: points, color: color, unit: unit, digits: series == .power ? 1 : 0)
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
                          traces: [.init(label: "Energy", color: HistoryTheme.green, series: energy)], digits: 1)
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
    private func chartBody(points: [HistoryChartPoint], color: Color, unit: String, yDomain: ClosedRange<Double>? = nil, digits: Int = 0) -> some View {
        if let error = loader.error {
            HistoryChartPlaceholder(message: error) { Task { await load() } }
        } else if loader.detail == nil {
            HistoryChartPlaceholder()
        } else if points.count < 2 {
            HistoryChartPlaceholder(message: "Not recorded for this session.")
        } else {
            HistoryLineChart(points: points, color: color, unit: unit, yDomain: yDomain, digits: digits)
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
        return HistoryCard {
            VStack(alignment: .leading, spacing: 0) {
                HistorySectionLabel(title: "Cost breakdown", systemImage: "dollarsign.circle")
                    .padding(.bottom, 10)
                costRow("Energy added", VoltaFormat.energy(charge.energyAddedKwh))
                HairlineDivider()
                costRow("Drawn from charger", VoltaFormat.energy(charge.energyUsedKwh))
                HairlineDivider()
                costRow("Charging losses", lost.map { l in
                    let pct = charge.energyUsedKwh.map { $0 > 0 ? " · \(VoltaFormat.number(l / $0 * 100, digits: 0))%" : "" } ?? ""
                    return VoltaFormat.energy(l) + pct
                } ?? "—", secondary: true)
                HairlineDivider()
                costRow("Rate", rate.map { VoltaFormat.money($0, currency: currency) + " / kWh" } ?? "—")
                if let perDistance {
                    HairlineDivider()
                    costRow("Cost per distance", perDistance, secondary: true)
                }
                HairlineDivider()
                HStack {
                    Text("Total")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    BigNumber(VoltaFormat.money(charge.cost, currency: currency), size: 22)
                }
                .padding(.top, 14)
            }
        }
    }

    private var rangeAddedKm: Double? { ChargeMath.rangeAddedKm(samples) }

    private func costRow(_ label: String, _ value: String, secondary: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(secondary ? HistoryTheme.secondary : .white.opacity(0.9))
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
