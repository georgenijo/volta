import Charts
import SwiftUI

/// Degradation overview: health %, capacity now vs new, rated range at 100% trend, idle drain.
struct BatteryHealthView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<BatteryHealth> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { health in
                if health.healthPercent == nil && health.history.isEmpty {
                    EmptyState(systemImage: "battery.100percent", title: "Not enough data yet",
                                    message: "Battery health appears after a few charges to a high state of charge.")
                } else {
                    content(health)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Battery Health")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ h: BatteryHealth) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            hero(h)
            capacity(h)
            if h.history.count > 1 { trend(h) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ScreenKit.Metric(label: "Range at 100%",
                                 value: h.ratedRangeAt100Km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                                 unit: units.distanceUnit, caption: "Rated", symbol: "road.lanes")
                ScreenKit.Metric(label: "Idle drain",
                                 value: h.avgIdleDrainPctPerDay.map { VoltaFormat.number($0, digits: 1) } ?? "—",
                                 unit: "%/day", caption: drainCaption(h.avgIdleDrainPctPerDay), symbol: "moon.zzz")
            }
            Text("Health is estimated from rated range at a full charge over time, the same method as TeslaMate's Battery Health dashboard. Short-term swings are normal.")
                .font(.system(size: 12)).foregroundStyle(ScreenKit.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func hero(_ h: BatteryHealth) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Battery health", trailing: healthLabel(h.healthPercent))
                HStack(alignment: .firstTextBaseline) {
                    ScreenKit.Numeral(value: h.healthPercent.map { VoltaFormat.number($0, digits: 1) } ?? "—", unit: "%", size: 64)
                    Spacer()
                    if let pct = h.healthPercent {
                        Text("−\(VoltaFormat.number(100 - pct, digits: 1))% since new")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                    }
                }
                ScreenKit.ProgressBar(fraction: (h.healthPercent ?? 0) / 100, tint: healthTint(h.healthPercent))
            }
        }
    }

    private func capacity(_ h: BatteryHealth) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Usable capacity")
                capacityRow("Now", h.capacityNowKwh, of: h.capacityNewKwh, tint: ScreenKit.green)
                capacityRow("When new", h.capacityNewKwh, of: h.capacityNewKwh, tint: Color.white.opacity(0.35))
                if let now = h.capacityNowKwh, let new = h.capacityNewKwh {
                    Text("\(VoltaFormat.number(new - now, digits: 1)) kWh less than new")
                        .font(.system(size: 13)).foregroundStyle(ScreenKit.secondary)
                }
            }
        }
    }

    private func capacityRow(_ label: String, _ value: Double?, of max: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                Spacer()
                ScreenKit.Numeral(value: value.map { VoltaFormat.number($0, digits: 1) } ?? "—", unit: "kWh", size: 22)
            }
            ScreenKit.ProgressBar(fraction: (value ?? 0) / Swift.max(max ?? 1, 1), tint: tint, height: 8)
        }
    }

    private func trend(_ h: BatteryHealth) -> some View {
        let points = h.history.sorted { $0.date < $1.date }
        let values = points.map { units.distanceValue(km: $0.ratedRangeAt100Km) }
        let lo = (values.min() ?? 0), hi = (values.max() ?? 1)
        let pad = Swift.max((hi - lo) * 0.25, 2)
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Rated range at 100%", trailing: units.distanceUnit)
                Chart(points, id: \.date) { p in
                    AreaMark(x: .value("Date", p.date), yStart: .value("Base", lo - pad),
                             yEnd: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                        .foregroundStyle(LinearGradient(colors: [ScreenKit.blue.opacity(0.35), ScreenKit.blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", p.date), y: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                        .foregroundStyle(ScreenKit.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartStyled()
                .frame(height: 180)
            }
        }
    }

    private func healthLabel(_ pct: Double?) -> String? {
        guard let pct else { return nil }
        return pct >= 90 ? "Excellent" : pct >= 80 ? "Good" : "Fair"
    }

    private func healthTint(_ pct: Double?) -> Color {
        guard let pct else { return ScreenKit.secondary }
        return pct >= 90 ? ScreenKit.green : pct >= 80 ? ScreenKit.amber : ScreenKit.red
    }

    private func drainCaption(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value <= 1 ? "Typical" : value <= 2 ? "Elevated" : "High"
    }

    private func load() async {
        do { state = .loaded(try await dataSource.battery(vehicleID: vehicleID)) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

#Preview("Populated") {
    NavigationStack { BatteryHealthView() }.preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack { BatteryHealthView() }
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}
