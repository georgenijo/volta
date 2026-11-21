import Charts
import SwiftUI

/// Degradation overview: health %, capacity now vs new, rated range at 100% trend, idle drain.
struct BatteryHealthView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<BatteryHealth> = .loading
    /// Every recorded charge, for the cycle estimate. nil while loading or if it
    /// failed: the estimate is then hidden, the rest of the screen unaffected.
    @State private var charges: PagedResult<ChargeSummary>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Wide: health and capacity beside the range trend and drain.
        ScreenKit.Page(scroll: "battery-health", splits: hasData) {
            LoadableContent(state: state, retry: load, placeholder: Self.placeholder, errorTitle: "Couldn't load battery health") { health in
                if health.healthPercent == nil && health.history.isEmpty {
                    EmptyState(systemImage: "battery.100percent", title: "Not enough data yet",
                               message: "Battery health appears after a few charges to a high state of charge. Charge to 90% or more now and then to give it a reading.")
                } else {
                    hero(health).voltaFocusIn(0)
                    capacity(health).voltaFocusIn(1)
                }
            }
        } secondary: {
            if hasData, let health = state.value { details(health) }
        }
        .screenKitPage("Battery health", screen: "battery-health")
        .task(id: vehicleID) { await load() }
        .task(id: vehicleID) { await loadCharges() }
    }

    private var hasData: Bool {
        guard let h = state.value else { return false }
        return !(h.healthPercent == nil && h.history.isEmpty)
    }

    @ViewBuilder
    private func details(_ h: BatteryHealth) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if h.history.count > 1 { trend(h).voltaFocusIn(0) }
            ScreenKit.MetricGroup {
                ScreenKit.Metric(label: "Range at 100%",
                                 value: h.ratedRangeAt100Km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                                 unit: units.distanceUnit, caption: "Rated, latest full charge", symbol: "road.lanes")
                ScreenKit.Metric(label: "Idle drain",
                                 value: h.avgIdleDrainPctPerDay.map { VoltaFormat.number($0, digits: 1) } ?? "—",
                                 unit: "% a day", caption: drainCaption(h.avgIdleDrainPctPerDay),
                                 captionColor: (h.avgIdleDrainPctPerDay ?? 0) > 2 ? ScreenKit.amber : ScreenKit.secondary,
                                 symbol: "moon.zzz")
            }
            .voltaFocusIn(1)
            if let charges, let estimate = CycleEstimate.make(charges: charges.items, usableCapacityKwh: h.capacityNowKwh,
                                                              isComplete: charges.isComplete) {
                cycleCard(estimate).voltaFocusIn(2)
            }
            Text("Health is estimated from rated range at a full charge over time, the same method as TeslaMate's Battery Health dashboard. Short-term swings are normal.")
                .font(.caption).foregroundStyle(ScreenKit.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// The lowest health the gauge shows: Tesla's battery warranty covers
    /// capacity below 70% within its term, so the scale runs from there to new.
    static let gaugeFloor = 70.0

    private func hero(_ h: BatteryHealth) -> some View {
        let pct = h.healthPercent
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery health").voltaLabelStyle().accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let word = healthLabel(pct) {
                        Text(word).font(.footnote.weight(.semibold)).foregroundStyle(healthWordColor(pct))
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    ScreenKit.RollingNumeral(value: pct, digits: 1, unit: "%", size: 64)
                    Spacer(minLength: 8)
                    if let pct {
                        Text("−\(VoltaFormat.number(100 - pct, digits: 1))% since new")
                            .font(.footnote.weight(.medium)).foregroundStyle(ScreenKit.secondary)
                    }
                }
                LevelBar(value: pct.map { ($0 - Self.gaugeFloor) / (100 - Self.gaugeFloor) }, color: healthTint(pct),
                         lowLabel: "\(Int(Self.gaugeFloor))% warranty level", highLabel: "100% new")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Capacity today as the one reading, measured against capacity when new.
    private func capacity(_ h: BatteryHealth) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Usable capacity")
                ScreenKit.RollingNumeral(value: h.capacityNowKwh, digits: 1, unit: "kWh", size: 36, weight: .bold)
                LevelBar(value: h.capacityNowKwh.flatMap { now in h.capacityNewKwh.map { now / max($0, 1) } },
                         color: ScreenKit.blue,
                         lowLabel: "0 kWh",
                         highLabel: h.capacityNewKwh.map { "\(VoltaFormat.number($0, digits: 1)) kWh new" } ?? "New unknown")
                if let now = h.capacityNowKwh, let new = h.capacityNewKwh {
                    Text("\(VoltaFormat.number(new - now, digits: 1)) kWh less than when new")
                        .font(.footnote).foregroundStyle(ScreenKit.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
                        .foregroundStyle(LinearGradient(colors: [ScreenKit.blue.opacity(0.25), ScreenKit.blue.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", p.date), y: .value("Range", units.distanceValue(km: p.ratedRangeAt100Km)))
                        .foregroundStyle(ScreenKit.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartStyled()
                .frame(height: 180)
                .accessibilityLabel("Rated range at 100% over time")
            }
        }
    }

    /// Equivalent full cycles: energy added over today's usable capacity.
    private func cycleCard(_ e: CycleEstimate) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Charge cycles", trailing: "Estimate")
                ScreenKit.RollingNumeral(value: e.cycles, digits: e.cycles < 10 ? 1 : 0, unit: "cycles", size: 40,
                                         prefix: e.isComplete ? "" : "≥ ")
                Text("\(VoltaFormat.energy(e.energyAddedKwh, fractionDigits: 0)) added over \(e.sessionsCounted) session\(e.sessionsCounted == 1 ? "" : "s"), divided by the estimated usable capacity of \(VoltaFormat.number(e.capacityKwh, digits: 1)) kWh.")
                    .font(.footnote).foregroundStyle(ScreenKit.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(cycleQualifier(e))
                    .font(.caption).foregroundStyle(ScreenKit.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.battery.cycles")
    }

    private func cycleQualifier(_ e: CycleEstimate) -> String {
        var text = "Counts only sessions TeslaMate recorded"
        if e.sessionsCounted < e.sessionsTotal {
            let missing = e.sessionsTotal - e.sessionsCounted
            text += "; \(missing) session\(missing == 1 ? "" : "s") without recorded energy \(missing == 1 ? "isn't" : "aren't") included"
        }
        if !e.isComplete { text += "; not every page of history loaded, so this is a lower bound" }
        return text + ". Partial charges add up to cycles, so one cycle is a battery's worth of energy, not one session."
    }

    private func healthLabel(_ pct: Double?) -> String? {
        guard let pct else { return nil }
        return pct >= 90 ? "Excellent" : pct >= 80 ? "Good" : pct >= Self.gaugeFloor ? "Fair" : "Below 70%"
    }

    /// The battery at rest is blue; amber asks for attention near the
    /// warranty floor and red is below it.
    private func healthTint(_ pct: Double?) -> Color {
        guard let pct else { return ScreenKit.secondary }
        return pct >= 80 ? ScreenKit.blue : pct >= Self.gaugeFloor ? ScreenKit.amber : ScreenKit.red
    }

    private func healthWordColor(_ pct: Double?) -> Color {
        guard let pct, pct < 80 else { return ScreenKit.secondary }
        return healthTint(pct)
    }

    private func drainCaption(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value <= 1 ? "Typical" : value <= 2 ? "Elevated" : "High"
    }

    private func loadCharges() async {
        charges = nil
        let source = dataSource, id = vehicleID
        let all = DateRange(from: nil, to: nil)
        guard let result = try? await fetchAllPages({ try await source.charges(vehicleID: id, range: all, cursor: $0) }),
              !Task.isCancelled else { return }
        withAnimation(VoltaMotion.animation(VoltaMotion.arrive, reduceMotion: reduceMotion)) { charges = result }
    }

    private func load() async {
        do { state = .loaded(try await dataSource.battery(vehicleID: vehicleID)) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

extension BatteryHealthView {
    /// Sample reading for the loading skeleton.
    static let placeholder = BatteryHealth(capacityNewKwh: 75, capacityNowKwh: 70, healthPercent: 93,
                                           ratedRangeAt100Km: 480, history: [], avgIdleDrainPctPerDay: 0.8)
}

#Preview("Populated") {
    NavigationStack { BatteryHealthView() }
}

#Preview("Empty") {
    NavigationStack { BatteryHealthView() }
        .environment(\.dataSource, MockDataSource(empty: true))
}
