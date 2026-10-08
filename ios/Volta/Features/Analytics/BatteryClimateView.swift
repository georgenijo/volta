import Charts
import SwiftUI

/// How outside temperature affects efficiency and range, from drives' outsideTempAvgC.
struct BatteryClimateView: View {
    /// A temperature band in display units (°F or °C).
    struct Band: Identifiable, Hashable, Sendable {
        var lower: Double
        var width: Double
        var distanceKm: Double
        var energyKwh: Double
        var drives: Int
        var id: Double { lower }
        var mid: Double { lower + width / 2 }
        var whPerKm: Double { distanceKm > 0 ? energyKwh * 1000 / distanceKm : 0 }
    }

    struct Snapshot: Sendable {
        var drives: [DriveSummary]
        var capacityKwh: Double?
        var isComplete: Bool = true
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<Snapshot> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { snapshot in
                let usable = snapshot.drives.filter { $0.outsideTempAvgC != nil && ($0.energyUsedKwh ?? 0) > 0 && $0.distanceKm > 0.5 }
                VStack(alignment: .leading, spacing: 18) {
                    // Shown with or without content: an empty page can be incomplete too.
                    if !snapshot.isComplete {
                        InlineBanner(systemImage: "exclamationmark.triangle",
                                     message: "Partial history: not every drive from the past year could be loaded.",
                                     tint: ScreenKit.amber)
                    }
                    if usable.isEmpty {
                        EmptyState(systemImage: "thermometer.medium", title: "No climate data yet",
                                   message: "Drives with an outside temperature reading will show how weather changes your efficiency.")
                            .padding(.top, 60)
                    } else {
                        content(usable, capacity: snapshot.capacityKwh)
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Battery Climate")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ drives: [DriveSummary], capacity: Double?) -> some View {
        let bands = Self.bands(drives, units: units)
        let best = bands.filter { $0.drives >= 1 }.min { $0.whPerKm < $1.whPerKm }
        let worst = bands.filter { $0.drives >= 1 }.max { $0.whPerKm < $1.whPerKm }

        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 20, tint: ScreenKit.blue) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Sweet spot", trailing: "\(drives.count) drives")
                    if let best {
                        ScreenKit.Numeral(value: bandLabel(best, withUnit: false), unit: units.temperatureUnit, size: 48)
                        Text("Most efficient at \(units.formatEfficiency(best.whPerKm)).")
                            .font(.system(size: 14)).foregroundStyle(ScreenKit.secondary)
                    }
                    if let best, let worst, worst.id != best.id, worst.whPerKm / best.whPerKm > 1.02 {
                        let penalty = (worst.whPerKm / best.whPerKm - 1) * 100
                        HStack(spacing: 8) {
                            Image(systemName: worst.mid < best.mid ? "snowflake" : "sun.max")
                                .foregroundStyle(worst.mid < best.mid ? ScreenKit.blue : ScreenKit.amber)
                            Text("Uses \(VoltaFormat.number(penalty, digits: 0))% more energy at \(bandLabel(worst, withUnit: true)).")
                                .foregroundStyle(.white)
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                }
            }

            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Efficiency by temperature", trailing: units.efficiencyUnit)
                    Chart(bands) { band in
                        BarMark(x: .value("Temp", bandLabel(band, withUnit: false)),
                                y: .value("Efficiency", units.efficiencyValue(whPerKm: band.whPerKm)))
                            .foregroundStyle(Self.tint(forC: celsius(band.mid)).gradient)
                            .clipShape(.rect(cornerRadius: 4))
                            .annotation(position: .top, spacing: 4) {
                                Text(VoltaFormat.number(units.efficiencyValue(whPerKm: band.whPerKm), digits: 0))
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(ScreenKit.secondary)
                            }
                    }
                    .chartStyled()
                    .frame(height: 190)
                    Text("Outside temperature, \(units.temperatureUnit)")
                        .font(.system(size: 11)).foregroundStyle(ScreenKit.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Every drive")
                    Chart(drives) { d in
                        PointMark(x: .value("Temp", units.temperatureValue(celsius: d.outsideTempAvgC ?? 0)),
                                  y: .value("Efficiency", units.efficiencyValue(whPerKm: (d.energyUsedKwh ?? 0) * 1000 / d.distanceKm)))
                            .foregroundStyle(Self.tint(forC: d.outsideTempAvgC ?? 15).opacity(0.85))
                            .symbolSize(min(140, 18 + d.distanceKm))
                    }
                    .chartXScale(domain: scatterDomain(drives.compactMap { $0.outsideTempAvgC.map(units.temperatureValue(celsius:)) }))
                    .chartYScale(domain: scatterDomain(drives.map { units.efficiencyValue(whPerKm: ($0.energyUsedKwh ?? 0) * 1000 / $0.distanceKm) }))
                    .chartStyled()
                    .frame(height: 170)
                    Text("Dot size reflects distance.").font(.system(size: 11)).foregroundStyle(ScreenKit.tertiary)
                }
            }

            if let capacity {
                ScreenKit.GroupCard(title: "Estimated full-charge range",
                                    footer: "Based on \(VoltaFormat.number(capacity, digits: 1)) kWh usable capacity and your real efficiency in each band.") {
                    ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                        ScreenKit.ValueRow(title: bandLabel(band, withUnit: true), subtitle: "\(band.drives) drive\(band.drives == 1 ? "" : "s")",
                                           showsDivider: index < bands.count - 1) {
                            Text(units.formatDistance(band.whPerKm > 0 ? capacity * 1000 / band.whPerKm : nil, fractionDigits: 0))
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func celsius(_ display: Double) -> Double {
        units.temperature == .fahrenheit ? (display - 32) * 5 / 9 : display
    }

    private func scatterDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, abs(hi) * 0.1, 1)
        return (lo - pad)...(hi + pad)
    }

    private func bandLabel(_ band: Band, withUnit: Bool) -> String {
        let lo = band.lower, hi = band.lower + band.width
        let text = "\(VoltaFormat.number(lo, digits: 0))–\(VoltaFormat.number(hi, digits: 0))"
        return withUnit ? text + units.temperatureUnit : text
    }

    /// Buckets drives into 10°F or 5°C bands.
    static func bands(_ drives: [DriveSummary], units: UnitPreferences) -> [Band] {
        let width = units.temperature == .fahrenheit ? 10.0 : 5.0
        var map: [Double: Band] = [:]
        for d in drives {
            guard let c = d.outsideTempAvgC, let e = d.energyUsedKwh else { continue }
            let lower = (units.temperatureValue(celsius: c) / width).rounded(.down) * width
            map[lower, default: Band(lower: lower, width: width, distanceKm: 0, energyKwh: 0, drives: 0)].distanceKm += d.distanceKm
            map[lower]!.energyKwh += e
            map[lower]!.drives += 1
        }
        return map.values.sorted { $0.lower < $1.lower }
    }

    /// Cold → blue, mild → green, hot → amber.
    static func tint(forC c: Double) -> Color {
        c < 5 ? ScreenKit.blue : c < 25 ? ScreenKit.green : ScreenKit.amber
    }

    private func load() async {
        let source = dataSource, id = vehicleID
        let from = Calendar.current.date(byAdding: .year, value: -1, to: .now)
        do {
            async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: DateRange(from: from, to: nil), cursor: $0) }
            let capacity = try? await source.battery(vehicleID: id).capacityNowKwh
            let paged = try await drives
            let snapshot = Snapshot(drives: paged.items, capacityKwh: capacity, isComplete: paged.isComplete)
            withAnimation(.smooth) { state = .loaded(snapshot) }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

#Preview("Populated") {
    NavigationStack { BatteryClimateView() }.preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack { BatteryClimateView() }
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}
