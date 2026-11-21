import Charts
import SwiftUI

/// Period totals plus distance / energy / cost charts, computed from drives and charges.
struct StatsView: View {
    enum Period: String, CaseIterable, Hashable, Sendable {
        case week, month, quarter, year
        var days: Int { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365 } }
        var bucket: Calendar.Component { switch self { case .week, .month: .day; case .quarter: .weekOfYear; case .year: .month } }
        /// "30 days", spelled out for the picker.
        var title: String { switch self { case .week: "7 days"; case .month: "30 days"; case .quarter: "90 days"; case .year: "1 year" } }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period: Period = .month
    @State private var state: Loadable<Snapshot> = .loading
    /// A date the owner tapped on the distance chart; nil follows the latest bucket.
    @State private var selected: Date?

    var body: some View {
        // Wide: the period, distance and totals beside the energy and cost charts.
        ScreenKit.Page(scroll: "stats", splits: hasActivity) {
            ScreenKit.Segmented(options: Period.allCases.map { ($0, $0.title) }, selection: $period)
            LoadableContent(state: state, retry: load, placeholder: Self.placeholder, errorTitle: "Couldn't load stats") { snapshot in
                // Shown with or without content: an empty page can be incomplete too.
                if !snapshot.isComplete {
                    InlineBanner(systemImage: "exclamationmark.triangle",
                                 message: "Partial history: the server returned more pages than Volta could load, so these totals are incomplete.",
                                 tint: ScreenKit.amber)
                }
                if snapshot.drives.isEmpty && snapshot.charges.isEmpty {
                    EmptyState(systemImage: "chart.xyaxis.line", title: "No activity in \(period.title)",
                               message: "Drives and charges from the last \(period.title) are summarized here.",
                               action: period == .year ? nil : .init("Show 1 year", systemImage: "calendar") { period = .year })
                } else {
                    overview(snapshot)
                }
            }
        } secondary: {
            if hasActivity, let snapshot = state.value { breakdown(snapshot) }
        }
        .screenKitPage("Stats", screen: "stats")
        .task(id: TaskKey(vehicleID: vehicleID, period: period)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var period: Period }

    private var hasActivity: Bool {
        guard let s = state.value else { return false }
        return !(s.drives.isEmpty && s.charges.isEmpty)
    }

    /// Distance as the one headline, efficiency on its own gauge, then energy and cost.
    @ViewBuilder
    private func overview(_ s: Snapshot) -> some View {
        let totals = AnalyticsMath.totals(drives: s.drives, charges: s.charges, fallbackCurrency: units.currency)
        // Per-bucket cost bars only make sense in one currency.
        let buckets = buckets(s, costCurrency: totals.singleCost?.currency)
        distanceCard(s, totals: totals, buckets: buckets).voltaFocusIn(0)
        efficiencyCard(totals).voltaFocusIn(1)
        ScreenKit.MetricGroup(title: "Energy and cost") {
            ScreenKit.Metric(label: "Energy used", value: totals.energyUsedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—",
                             unit: "kWh", caption: totals.energyUsedCoverage.qualifier ?? "Driving", symbol: "bolt")
            ScreenKit.Metric(label: "Energy added", value: totals.energyAddedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "kWh",
                             caption: totals.energyAddedCoverage.qualifier ?? "\(s.charges.count) session\(s.charges.count == 1 ? "" : "s")",
                             symbol: "bolt.batteryblock")
            ScreenKit.Metric(label: "Charging cost", value: costValue(totals.costs), caption: costCaption(totals),
                             symbol: "dollarsign.circle")
            ScreenKit.Metric(label: "Drives", value: "\(s.drives.count)",
                             caption: VoltaFormat.duration(minutes: totals.driveMinutes) + " driving", symbol: "car")
        }
        .voltaFocusIn(2)
    }

    private func distanceCard(_ s: Snapshot, totals: AnalyticsMath.Totals, buckets: [Bucket]) -> some View {
        let focus = focusBucket(buckets)
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Distance", trailing: "Last \(period.title)")
                ScreenKit.RollingNumeral(value: units.distanceValue(km: totals.distanceKm), unit: units.distanceUnit, size: 52)
                Text("\(s.drives.count) drive\(s.drives.count == 1 ? "" : "s") · \(VoltaFormat.duration(minutes: totals.driveMinutes)) behind the wheel")
                    .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                Chart(buckets) { b in
                    BarMark(x: .value("Date", b.start, unit: period.bucket),
                            y: .value("Distance", units.distanceValue(km: b.distanceKm)))
                        // Selection is blue; the rest of the history is neutral.
                        .foregroundStyle(b.start == focus?.start ? AnyShapeStyle(ScreenKit.blue) : AnyShapeStyle(Self.historyBar))
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartXSelection(value: $selected.animation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)))
                .chartStyled()
                .frame(height: 150)
                .voltaFeedback(.selection, trigger: focus?.start)
                .accessibilityLabel("Distance per \(bucketNoun)")
                if let focus {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bucketTitle(focus.start)).font(.footnote).foregroundStyle(ScreenKit.secondary)
                        Spacer(minLength: 8)
                        Text(units.formatDistance(focus.distanceKm, fractionDigits: 0))
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Color.voltaTextPrimary)
                            .voltaRolling(focus.distanceKm)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 30-day efficiency on the Dashboard's scale: both ends labelled, filled from the efficient end.
    private func efficiencyCard(_ totals: AnalyticsMath.Totals) -> some View {
        let range = DashboardView.efficiencyRange
        let eff = totals.efficiencyWhPerKm
        let fraction = eff.map { ($0 - range.lowerBound) / (range.upperBound - range.lowerBound) }
        let end = { (whPerKm: Double) in VoltaFormat.number(units.efficiencyValue(whPerKm: whPerKm), digits: 0) }
        let heavy = (fraction ?? 0) > 0.7
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "leaf.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(eff == nil ? ScreenKit.secondary : heavy ? ScreenKit.amber : ScreenKit.green)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((eff == nil ? ScreenKit.secondary : heavy ? ScreenKit.amber : ScreenKit.green).opacity(0.16)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Efficiency").voltaLabelStyle()
                        ScreenKit.RollingNumeral(value: eff.map { units.efficiencyValue(whPerKm: $0) }, unit: units.efficiencyUnit,
                                                 size: 28, weight: .bold)
                    }
                    Spacer(minLength: 0)
                }
                LevelBar(value: fraction, color: heavy ? .voltaAmber : .voltaGreen,
                         lowLabel: "\(end(range.lowerBound)) efficient", highLabel: "\(end(range.upperBound)) heavy")
                Text(totals.energyUsedCoverage.isPartial
                     ? "From \(totals.energyUsedCoverage.measured) of \(totals.energyUsedCoverage.total) drives with recorded energy"
                     : eff == nil ? "No drive recorded its energy" : "Average over the drives in this period")
                    .font(.caption).foregroundStyle(ScreenKit.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func focusBucket(_ buckets: [Bucket]) -> Bucket? {
        guard let selected else { return buckets.last }
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: period.bucket, for: selected)?.start
        return buckets.first { $0.start == start } ?? buckets.last
    }

    private var bucketNoun: String {
        switch period.bucket { case .day: "day"; case .weekOfYear: "week"; default: "month" }
    }

    private func bucketTitle(_ date: Date) -> String {
        switch period.bucket {
        case .day: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .weekOfYear: "Week of " + date.formatted(.dateTime.month(.abbreviated).day())
        default: date.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Neutral bars for the history behind the selected one.
    static let historyBar = Color.voltaTextTertiary.opacity(0.55)

    /// Energy and charging cost charts.
    @ViewBuilder
    private func breakdown(_ s: Snapshot) -> some View {
        let totals = AnalyticsMath.totals(drives: s.drives, charges: s.charges, fallbackCurrency: units.currency)
        let single = totals.singleCost
        let buckets = buckets(s, costCurrency: single?.currency)

        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Energy", trailing: "kWh")
                HStack(spacing: 14) {
                    // Green is energy going in; what driving used is neutral.
                    legend(ScreenKit.green, "Added")
                    legend(Self.usedBar, "Used")
                }
                Chart {
                    ForEach(buckets) { b in
                        if let added = b.energyAddedKwh {
                            BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", added))
                                .foregroundStyle(by: .value("Kind", "Added"))
                                .position(by: .value("Kind", "Added"))
                        }
                        if let used = b.energyUsedKwh {
                            BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", used))
                                .foregroundStyle(by: .value("Kind", "Used"))
                                .position(by: .value("Kind", "Used"))
                        }
                    }
                }
                .chartForegroundStyleScale(["Added": ScreenKit.green, "Used": Self.usedBar])
                .chartLegend(.hidden)
                .chartStyled()
                .frame(height: 150)
            }
        }
        .voltaFocusIn(0)

        if let single {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Charging cost", trailing: VoltaFormat.money(single.amount, currency: single.currency))
                    Chart(buckets.filter { $0.cost != nil }) { b in
                        BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("Cost", b.cost ?? 0))
                            .foregroundStyle(Self.usedBar)
                            .clipShape(.rect(cornerRadius: 3))
                    }
                    .chartStyled()
                    .frame(height: 130)
                    if let qualifier = totals.costCoverage.qualifier {
                        Text(qualifier + ". Sessions without a cost aren't included.")
                            .font(.caption).foregroundStyle(ScreenKit.amber)
                    }
                }
            }
            .voltaFocusIn(1)
        } else if totals.costs.count > 1 {
            ScreenKit.GroupCard(title: "Charging cost",
                                footer: "Sessions were billed in more than one currency, so totals are shown separately."
                                    + (totals.costCoverage.qualifier.map { " \($0)." } ?? "")) {
                ForEach(Array(totals.costs.enumerated()), id: \.element) { index, entry in
                    ScreenKit.ValueRow(title: entry.currency, showsDivider: index < totals.costs.count - 1) {
                        Text(VoltaFormat.money(entry.amount, currency: entry.currency))
                            .font(.callout.weight(.semibold)).foregroundStyle(.voltaTextPrimary).monospacedDigit()
                    }
                }
            }
            .voltaFocusIn(1)
        }

        SpeedEfficiencyCard(drives: s.drives).voltaFocusIn(2)
    }

    /// Neutral bars for energy used and money spent: neither is energy going in.
    static let usedBar = Color.voltaTextSecondary.opacity(0.7)

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(ScreenKit.secondary)
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
        selected = nil
        let source = dataSource, id = vehicleID
        let from = Calendar.current.date(byAdding: .day, value: -period.days + 1, to: Calendar.current.startOfDay(for: .now))
        let range = DateRange(from: from, to: nil)
        do {
            async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: range, cursor: $0) }
            async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: range, cursor: $0) }
            let (d, c) = try await (drives, charges)
            let snapshot = Snapshot(drives: d.items, charges: c.items, isComplete: d.isComplete && c.isComplete)
            withAnimation(VoltaMotion.animation(VoltaMotion.arrive, reduceMotion: reduceMotion)) { state = .loaded(snapshot) }
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
                    AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(ScreenKit.hairline)
                    AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.caption2)
                }
            }
    }
}

extension StatsView {
    /// Sample period for the loading skeleton: the real layout, drawn as placeholders.
    static let placeholder: Snapshot = {
        let now = Date.now
        let drives = (0..<6).map { i in
            DriveSummary(id: -i - 1, start: now.addingTimeInterval(Double(-i) * 86_400 * 4), end: nil, startAddress: nil, endAddress: nil,
                         distanceKm: 20 + Double(i) * 6, durationMin: 30, startBatteryLevel: nil, endBatteryLevel: nil,
                         energyUsedKwh: 3 + Double(i), efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: 50,
                         outsideTempAvgC: nil)
        }
        return Snapshot(drives: drives, charges: [])
    }()
}

#Preview("Populated") {
    NavigationStack { StatsView() }
}

#Preview("Empty") {
    NavigationStack { StatsView() }
        .environment(\.dataSource, MockDataSource(empty: true))
}
