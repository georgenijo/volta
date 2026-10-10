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
                VStack(alignment: .leading, spacing: 22) {
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
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.battery-climate")
        .voltaArrivalScope(isReady: state.isSettled)
        .screenKitPage("Battery Climate")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ drives: [DriveSummary], capacity: Double?) -> some View {
        let bands = Self.bands(drives, units: units)
        let best = bands.filter { $0.drives >= 1 }.min { $0.whPerKm < $1.whPerKm }
        let worst = bands.filter { $0.drives >= 1 }.max { $0.whPerKm < $1.whPerKm }
        let penalty: Double? = {
            guard let best, let worst, worst.id != best.id, worst.whPerKm / best.whPerKm > 1.02 else { return nil }
            return (worst.whPerKm / best.whPerKm - 1) * 100
        }()

        VStack(alignment: .leading, spacing: 0) {
            AnalyticsHero(eyebrow: "Sweet spot · \(drives.count) drives", value: best.map { bandLabel($0, withUnit: false) } ?? "—",
                          unit: units.temperatureUnit, size: 72, identifier: "screen.battery-climate")
            if let best {
                Text("Most efficient at \(units.formatEfficiency(best.whPerKm)).")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary)
                    .padding(.top, 4)
            }
            AnalyticsStatStrip(items: [
                (best.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0.whPerKm), digits: 0) } ?? "—", "Best"),
                (worst.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0.whPerKm), digits: 0) } ?? "—", "Worst"),
                (penalty.map { "+\(VoltaFormat.number($0, digits: 0))%" } ?? "—", "Penalty"),
                ("\(bands.count)", bands.count == 1 ? "Band" : "Bands"),
            ])
            .padding(.top, 22)
            if let best, let worst, let penalty {
                HStack(spacing: 8) {
                    Image(systemName: worst.mid < best.mid ? "snowflake" : "sun.max")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(worst.mid < best.mid ? AnalyticsStyle.blue : AnalyticsStyle.amber)
                    Text("Uses \(VoltaFormat.number(penalty, digits: 0))% more energy at \(bandLabel(worst, withUnit: true)).")
                        .foregroundStyle(.white.opacity(0.85))
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 16)
            }

            AnalyticsSectionHeader("Efficiency by temperature", trailing: units.efficiencyUnit).padding(.top, AnalyticsStyle.sectionGap)
            bandChart(bands, best: best)

            AnalyticsSectionHeader("Every drive", trailing: "Dot size reflects distance").padding(.top, AnalyticsStyle.sectionGap)
            scatter(drives)

            if let capacity {
                AnalyticsSectionHeader("Full-charge range").padding(.top, AnalyticsStyle.sectionGap)
                let ranges = bands.map { $0.whPerKm > 0 ? capacity * 1000 / $0.whPerKm : nil }
                let longest = ranges.compactMap { $0 }.max() ?? 1
                AnalyticsGroup {
                    ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                        AnalyticsRow(title: bandLabel(band, withUnit: true), subtitle: "\(band.drives) drive\(band.drives == 1 ? "" : "s")",
                                     value: units.formatDistance(ranges[index], fractionDigits: 0), showsDivider: index < bands.count - 1) {
                            let tint = Self.tint(forC: celsius(band.mid))
                            AnalyticsBar(fraction: ranges[index].map { $0 / longest }, colors: [tint.opacity(0.35), tint], height: 3)
                        }
                    }
                }
                AnalyticsFootnote("Estimated from \(VoltaFormat.number(capacity, digits: 1)) kWh usable capacity and your real efficiency in each band.")
                    .padding(.top, 10)
            }
        }
    }

    private func bandChart(_ bands: [Band], best: Band?) -> some View {
        VStack(spacing: 8) {
            AnalyticsGlowChart(height: 140) { ghost in
                Chart(bands) { band in
                    let tint = Self.tint(forC: celsius(band.mid))
                    BarMark(x: .value("Temp", bandLabel(band, withUnit: false)),
                            y: .value("Efficiency", units.efficiencyValue(whPerKm: band.whPerKm)), width: .fixed(8))
                        .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(ghost ? 0 : 0.18)], startPoint: .top, endPoint: .bottom))
                        .clipShape(Capsule())
                        .annotation(position: .top, spacing: 6) {
                            Text(VoltaFormat.number(units.efficiencyValue(whPerKm: band.whPerKm), digits: 0))
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(ghost ? .clear : band.id == best?.id ? .white : AnalyticsStyle.secondary)
                        }
                }
                .chartStyled(ghost: ghost, showsYAxis: false)
            }
            Text("Outside temperature, \(units.temperatureUnit)")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(AnalyticsStyle.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func scatter(_ drives: [DriveSummary]) -> some View {
        let xDomain = scatterDomain(drives.compactMap { $0.outsideTempAvgC.map(units.temperatureValue(celsius:)) })
        let yDomain = scatterDomain(drives.map { units.efficiencyValue(whPerKm: ($0.energyUsedKwh ?? 0) * 1000 / $0.distanceKm) })
        return AnalyticsGlowChart(height: 170, radius: 4) { ghost in
            Chart(drives) { d in
                PointMark(x: .value("Temp", units.temperatureValue(celsius: d.outsideTempAvgC ?? 0)),
                          y: .value("Efficiency", units.efficiencyValue(whPerKm: (d.energyUsedKwh ?? 0) * 1000 / d.distanceKm)))
                    .foregroundStyle(Self.tint(forC: d.outsideTempAvgC ?? 15).opacity(ghost ? 1 : 0.8))
                    .symbolSize(min(110, 14 + d.distanceKm * 0.8))
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartStyled(ghost: ghost)
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

    /// Cold → blue, mild → mint, hot → amber.
    static func tint(forC c: Double) -> Color {
        c < 5 ? AnalyticsStyle.blue : c < 25 ? AnalyticsStyle.mint : AnalyticsStyle.amber
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
