import MapKit
import SwiftUI

/// Loads one detail record; shared by the three detail screens.
@MainActor @Observable
final class HistoryDetailLoader<Detail: Sendable> {
    private(set) var detail: Detail?
    private(set) var error: String?

    func load(_ fetch: @Sendable () async throws -> Detail) async {
        error = nil
        do {
            detail = try await fetch()
        } catch {
            // Cancelled: leave the state for the reappearing view's task to reload.
            if error is CancellationError || Task.isCancelled { return }
            self.error = error.localizedDescription
        }
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
        return HistoryChartCard(title: "Charge curve", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: 14) {
                SegmentedRangePicker(selection: $series, options: Series.allCases) { $0.rawValue }
                chartBody(points: points, color: color, unit: unit, digits: series == .power ? 1 : 0)
            }
        }
    }

    private var socCard: some View {
        let points = samples.compactMap { s in s.batteryLevel.map { HistoryChartPoint(t: s.t, value: Double($0)) } }
        return HistoryChartCard(title: "State of charge", systemImage: "battery.75percent",
                                value: charge.endBatteryLevel.map(String.init), unit: "%") {
            chartBody(points: points, color: HistoryTheme.blue, unit: "%", yDomain: 0...100)
        }
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
