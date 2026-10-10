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
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.battery-health")
        .voltaArrivalScope(isReady: state.isSettled)
        .screenKitPage("Battery Health")
        .task(id: vehicleID) { await load() }
    }

    @ViewBuilder
    private func content(_ h: BatteryHealth) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hero(h)
            AnalyticsStatStrip(items: [
                (h.healthPercent.map { "−\(VoltaFormat.number(100 - $0, digits: 1))%" } ?? "—", "Since new"),
                (lostKwh(h).map { VoltaFormat.number($0, digits: 1) } ?? "—", "kWh lost"),
                (h.ratedRangeAt100Km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "\(units.distanceUnit) at 100%"),
                (h.avgIdleDrainPctPerDay.map { VoltaFormat.number($0, digits: 1) } ?? "—", "%/day idle"),
            ])
            .padding(.top, 28)
            if let caption = drainCaption(h.avgIdleDrainPctPerDay) {
                Text("Idle drain is \(caption.lowercased()).")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(caption == "Typical" ? AnalyticsStyle.tertiary : AnalyticsStyle.amber)
                    .padding(.top, 10)
            }

            AnalyticsSectionHeader("Usable capacity", trailing: lostKwh(h).map { "\(VoltaFormat.number($0, digits: 1)) kWh less than new" })
                .padding(.top, AnalyticsStyle.sectionGap)
            AnalyticsGroup {
                capacityRow("Now", h.capacityNowKwh, of: h.capacityNewKwh, colors: [AnalyticsStyle.mint.opacity(0.6), healthTint(h.healthPercent)], divider: true)
                capacityRow("When new", h.capacityNewKwh, of: h.capacityNewKwh, colors: [.white.opacity(0.22), .white.opacity(0.4)], divider: false)
            }

            if h.history.count > 1 { trend(h).padding(.top, AnalyticsStyle.sectionGap) }

            AnalyticsFootnote("Health is estimated from rated range at a full charge over time, the same method as TeslaMate's Battery Health dashboard. Short-term swings are normal.")
                .padding(.top, 22)
        }
    }

    /// Open dial scaled from 70% (Tesla's battery warranty floor) to 100%.
    private func hero(_ h: BatteryHealth) -> some View {
        let tint = healthTint(h.healthPercent)
        return VStack(spacing: 4) {
            Text("Battery health").voltaLabelStyle(color: AnalyticsStyle.tertiary)
            ZStack(alignment: .bottom) {
                AnalyticsDial(fraction: h.healthPercent.map { ($0 - 70) / 30 },
                              value: h.healthPercent.map { VoltaFormat.number($0, digits: 1) } ?? "—", unit: "%",
                              caption: healthLabel(h.healthPercent), colors: [tint.opacity(0.25), AnalyticsStyle.mint.opacity(0.8), tint], size: 236)
                HStack {
                    Text("70")
                    Spacer()
                    Text("100")
                }
                .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(AnalyticsStyle.tertiary)
                .frame(width: 150).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(h.healthPercent.map { "Battery health \(VoltaFormat.number($0, digits: 1)) percent, \(healthLabel($0) ?? "")" } ?? "Battery health unavailable")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("screen.battery-health")
    }

    private func lostKwh(_ h: BatteryHealth) -> Double? {
        guard let now = h.capacityNowKwh, let new = h.capacityNewKwh else { return nil }
        return new - now
    }

    private func capacityRow(_ label: String, _ value: Double?, of max: Double?, colors: [Color], divider: Bool) -> some View {
        AnalyticsRow(title: label, value: value.map { "\(VoltaFormat.number($0, digits: 1)) kWh" } ?? "—", showsDivider: divider) {
            AnalyticsBar(fraction: value.map { $0 / Swift.max(max ?? 1, 1) }, colors: colors)
        }
    }

    private func trend(_ h: BatteryHealth) -> some View {
        let points = h.history.sorted { $0.date < $1.date }
        let values = points.map { units.distanceValue(km: $0.ratedRangeAt100Km) }
        let lo = (values.min() ?? 0), hi = (values.max() ?? 1)
        let pad = Swift.max((hi - lo) * 0.25, 2)
        let span = values.first.flatMap { first in values.last.map { "\(VoltaFormat.number(first, digits: 0)) → \(VoltaFormat.number($0, digits: 0)) \(units.distanceUnit)" } }
        return VStack(alignment: .leading, spacing: 0) {
            AnalyticsSectionHeader("Rated range at 100%", trailing: span)
            AnalyticsGlowChart(height: 180) { ghost in
                Chart(points, id: \.date) { p in
                    if !ghost {
                        AreaMark(x: .value("Date", p.date), yStart: .value("Base", lo - pad),
                                 yEnd: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                            .foregroundStyle(LinearGradient(colors: [AnalyticsStyle.blue.opacity(0.15), AnalyticsStyle.blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Date", p.date), y: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                        .foregroundStyle(AnalyticsStyle.energy)
                        .lineStyle(StrokeStyle(lineWidth: ghost ? 4 : 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    if p.date == points.last?.date {
                        PointMark(x: .value("Date", p.date), y: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                            .foregroundStyle(AnalyticsStyle.blue).symbolSize(ghost ? 120 : 36)
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartStyled(ghost: ghost)
            }
        }
    }

    private func healthLabel(_ pct: Double?) -> String? {
        guard let pct else { return nil }
        return pct >= 90 ? "Excellent" : pct >= 80 ? "Good" : "Fair"
    }

    private func healthTint(_ pct: Double?) -> Color {
        guard let pct else { return AnalyticsStyle.secondary }
        return pct >= 90 ? AnalyticsStyle.mint : pct >= 80 ? AnalyticsStyle.amber : AnalyticsStyle.red
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
