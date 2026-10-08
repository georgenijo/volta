import Charts
import SwiftUI

/// Period totals plus distance / energy / cost charts, computed from drives and charges.
struct StatsView: View {
    enum Period: String, CaseIterable, Hashable, Sendable {
        case week = "7D", month = "30D", quarter = "90D", year = "1Y"
        var days: Int { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365 } }
        var bucket: Calendar.Component { switch self { case .week, .month: .day; case .quarter: .weekOfYear; case .year: .month } }
    }

    struct Bucket: Identifiable, Hashable, Sendable {
        var start: Date
        var distanceKm: Double = 0
        /// nil = nothing measured in this bucket (drawn as no bar, never as zero).
        var energyUsedKwh: Double?
        var energyAddedKwh: Double?
        var cost: Double?
        var id: Date { start }
    }

    struct Snapshot: Sendable {
        var drives: [DriveSummary]
        var charges: [ChargeSummary]
        /// False if paging stopped early; totals then cover only what loaded.
        var isComplete: Bool = true
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var period: Period = .month
    @State private var state: Loadable<Snapshot> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenKit.Segmented(options: Period.allCases.map { ($0, $0.rawValue) }, selection: $period)
                LoadableContent(state: state, retry: load) { snapshot in
                    // Shown with or without content: an empty page can be incomplete too.
                    if !snapshot.isComplete {
                        InlineBanner(systemImage: "exclamationmark.triangle",
                                     message: "Partial history: the server returned more pages than Volta could load, so these totals are incomplete.",
                                     tint: ScreenKit.amber)
                    }
                    if snapshot.drives.isEmpty && snapshot.charges.isEmpty {
                        EmptyState(systemImage: "chart.xyaxis.line", title: "No activity",
                                        message: "Drives and charges in the last \(period.days) days will be summarized here.")
                    } else {
                        content(snapshot)
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Stats")
        .task(id: TaskKey(vehicleID: vehicleID, period: period)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var period: Period }

    @ViewBuilder
    private func content(_ s: Snapshot) -> some View {
        let totals = AnalyticsMath.totals(drives: s.drives, charges: s.charges, fallbackCurrency: units.currency)
        let distance = totals.distanceKm
        let single = totals.singleCost
        // Per-bucket cost bars only make sense in one currency.
        let buckets = buckets(s, costCurrency: single?.currency)

        // Hero: total distance
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Distance", trailing: "Last \(period.days) days")
                ScreenKit.Numeral(value: VoltaFormat.number(units.distanceValue(km: distance), digits: 0), unit: units.distanceUnit, size: 52)
                HStack(spacing: 18) {
                    inline("\(s.drives.count)", "drives")
                    inline(VoltaFormat.duration(minutes: totals.driveMinutes), "behind the wheel")
                }
                Chart(buckets) { b in
                    BarMark(x: .value("Date", b.start, unit: period.bucket),
                            y: .value("Distance", units.distanceValue(km: b.distanceKm)))
                        .foregroundStyle(ScreenKit.blue.gradient)
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartStyled()
                .frame(height: 150)
            }
        }

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            // Efficiency is a ratio over drives where both energy and distance are known.
            ScreenKit.Metric(label: "Efficiency", value: totals.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—",
                             unit: units.efficiencyUnit,
                             caption: totals.energyUsedCoverage.isPartial ? "From \(totals.energyUsedCoverage.measured) of \(totals.energyUsedCoverage.total) drives" : nil,
                             symbol: "leaf")
            ScreenKit.Metric(label: "Energy used", value: totals.energyUsedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—",
                             unit: "kWh", caption: totals.energyUsedCoverage.qualifier, symbol: "bolt")
            ScreenKit.Metric(label: "Energy added", value: totals.energyAddedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "kWh",
                             caption: totals.energyAddedCoverage.qualifier ?? "\(s.charges.count) sessions", symbol: "bolt.batteryblock")
            ScreenKit.Metric(label: "Charge cost", value: costValue(totals.costs), caption: costCaption(totals),
                             symbol: "dollarsign.circle")
        }

        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Energy")
                HStack(spacing: 14) {
                    legend(ScreenKit.green, "Used")
                    legend(ScreenKit.blue.opacity(0.7), "Added")
                }
                Chart {
                    ForEach(buckets) { b in
                        if let used = b.energyUsedKwh {
                            BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", used))
                                .foregroundStyle(by: .value("Kind", "Used"))
                                .position(by: .value("Kind", "Used"))
                        }
                        if let added = b.energyAddedKwh {
                            BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", added))
                                .foregroundStyle(by: .value("Kind", "Added"))
                                .position(by: .value("Kind", "Added"))
                        }
                    }
                }
                .chartForegroundStyleScale(["Used": ScreenKit.green, "Added": ScreenKit.blue.opacity(0.7)])
                .chartLegend(.hidden)
                .chartStyled()
                .frame(height: 150)
            }
        }

        if let single {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Charging cost", trailing: VoltaFormat.money(single.amount, currency: single.currency))
                    Chart(buckets.filter { $0.cost != nil }) { b in
                        BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("Cost", b.cost ?? 0))
                            .foregroundStyle(ScreenKit.amber.gradient)
                            .clipShape(.rect(cornerRadius: 3))
                    }
                    .chartStyled()
                    .frame(height: 130)
                    if let qualifier = totals.costCoverage.qualifier {
                        Text(qualifier + " — sessions without a cost aren't included.")
                            .font(.system(size: 12)).foregroundStyle(ScreenKit.amber)
                    }
                }
            }
        } else if totals.costs.count > 1 {
            ScreenKit.GroupCard(title: "Charging cost",
                                footer: "Sessions were billed in more than one currency, so totals are shown separately."
                                    + (totals.costCoverage.qualifier.map { " \($0)." } ?? "")) {
                ForEach(Array(totals.costs.enumerated()), id: \.element) { index, entry in
                    ScreenKit.ValueRow(title: entry.currency, showsDivider: index < totals.costs.count - 1) {
                        Text(VoltaFormat.money(entry.amount, currency: entry.currency))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                    }
                }
            }
        }
    }

    private func inline(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text(label).font(.system(size: 14)).foregroundStyle(ScreenKit.secondary)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
        }
    }

    /// "—" when every cost is unknown; "Mixed" when costs span currencies.
    private func costValue(_ costs: [AnalyticsMath.CurrencyAmount]) -> String {
        switch costs.count {
        case 0: "—"
        case 1: VoltaFormat.money(costs[0].amount, currency: costs[0].currency)
        default: "Mixed"
        }
    }

    /// Partial qualifier first; cost per distance only when every charge's cost is known.
    private func costCaption(_ totals: AnalyticsMath.Totals) -> String? {
        if let qualifier = totals.costCoverage.qualifier { return qualifier }
        if totals.costs.count > 1 { return "\(totals.costs.count) currencies" }
        guard let perKm = totals.costPerKm, perKm.amount > 0 else { return nil }
        let per = perKm.amount / units.distanceValue(km: 1) * 100
        return "\(VoltaFormat.money(per, currency: perKm.currency)) / 100 \(units.distanceUnit)"
    }

    private func buckets(_ s: Snapshot, costCurrency: String?) -> [Bucket] {
        let calendar = Calendar.current
        let now = Date.now
        let from = calendar.date(byAdding: .day, value: -period.days + 1, to: calendar.startOfDay(for: now)) ?? now
        var map: [Date: Bucket] = [:]
        // Seed every bucket so gaps render as zero-height bars.
        var cursor = calendar.dateInterval(of: period.bucket, for: from)?.start ?? from
        while cursor <= now {
            map[cursor] = Bucket(start: cursor)
            guard let next = calendar.date(byAdding: period.bucket, value: 1, to: cursor) else { break }
            cursor = next
        }
        func key(_ d: Date) -> Date { calendar.dateInterval(of: period.bucket, for: d)?.start ?? d }
        for d in s.drives {
            let k = key(d.start)
            map[k, default: Bucket(start: k)].distanceKm += d.distanceKm
            if let used = d.energyUsedKwh { map[k, default: Bucket(start: k)].energyUsedKwh = (map[k]?.energyUsedKwh ?? 0) + used }
        }
        for c in s.charges {
            let k = key(c.start)
            if let added = c.energyAddedKwh { map[k, default: Bucket(start: k)].energyAddedKwh = (map[k]?.energyAddedKwh ?? 0) + added }
            if let cost = c.cost, let costCurrency, (c.currency ?? units.currency) == costCurrency {
                map[k, default: Bucket(start: k)].cost = (map[k]?.cost ?? 0) + cost
            }
        }
        return map.values.sorted { $0.start < $1.start }
    }

    private func load() async {
        let source = dataSource, id = vehicleID
        let from = Calendar.current.date(byAdding: .day, value: -period.days + 1, to: Calendar.current.startOfDay(for: .now))
        let range = DateRange(from: from, to: nil)
        do {
            async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: range, cursor: $0) }
            async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: range, cursor: $0) }
            let (d, c) = try await (drives, charges)
            let snapshot = Snapshot(drives: d.items, charges: c.items, isComplete: d.isComplete && c.isComplete)
            withAnimation(.smooth) { state = .loaded(snapshot) }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

extension View {
    /// Shared dark chart chrome: faint grid, gray axis labels.
    func chartStyled() -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(ScreenKit.hairline)
                    AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                }
            }
    }
}

#Preview("Populated") {
    NavigationStack { StatsView() }.preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack { StatsView() }
        .environment(\.dataSource, MockDataSource(empty: true))
        .preferredColorScheme(.dark)
}
