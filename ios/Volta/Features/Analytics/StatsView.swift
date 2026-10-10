import Charts
import SwiftUI

/// Period totals plus distance / energy / cost charts, computed from drives and charges.
struct StatsView: View {
    enum Period: String, CaseIterable, Hashable, Sendable {
        case week = "7D", month = "30D", quarter = "90D", year = "1Y"
        var days: Int { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365 } }
        var bucket: Calendar.Component { switch self { case .week, .month: .day; case .quarter: .weekOfYear; case .year: .month } }
        var bucketNoun: String { switch self { case .week, .month: "day"; case .quarter: "week"; case .year: "month" } }
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
            VStack(alignment: .leading, spacing: 22) {
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
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.stats")
        .voltaArrivalScope(isReady: state.isSettled)
        .screenKitPage("Stats")
        .task(id: TaskKey(vehicleID: vehicleID, period: period)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var period: Period }

    @ViewBuilder
    private func content(_ s: Snapshot) -> some View {
        let totals = AnalyticsMath.totals(drives: s.drives, charges: s.charges, fallbackCurrency: units.currency)
        let single = totals.singleCost
        // Per-bucket cost bars only make sense in one currency.
        let buckets = buckets(s, costCurrency: single?.currency)

        VStack(alignment: .leading, spacing: 0) {
            AnalyticsHero(eyebrow: "Distance · last \(period.days) days",
                          value: VoltaFormat.number(units.distanceValue(km: totals.distanceKm), digits: 0),
                          unit: units.distanceUnit, identifier: "screen.stats")
            AnalyticsStatStrip(items: [
                ("\(s.drives.count)", s.drives.count == 1 ? "Drive" : "Drives"),
                (VoltaFormat.duration(minutes: totals.driveMinutes), "Driving"),
                // Efficiency is a ratio over drives where both energy and distance are known.
                (totals.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", units.efficiencyUnit),
                (costValue(totals.costs), "Spent"),
            ])
            .padding(.top, 22)
            if totals.energyUsedCoverage.isPartial {
                AnalyticsFootnote("Efficiency from \(totals.energyUsedCoverage.measured) of \(totals.energyUsedCoverage.total) drives").padding(.top, 10)
            }
            distanceRhythm(buckets).padding(.top, 24)

            AnalyticsSectionHeader("Energy") {
                HStack(spacing: 12) {
                    AnalyticsLegendDot(color: AnalyticsStyle.mint, label: "Used")
                    AnalyticsLegendDot(color: AnalyticsStyle.blue, label: "Added")
                }
            }
            .padding(.top, AnalyticsStyle.sectionGap)
            energyCard(buckets, totals: totals, sessions: s.charges.count)
                .voltaCascade(index: 1)

            if let single {
                AnalyticsSectionHeader("Charging cost").padding(.top, AnalyticsStyle.sectionGap)
                costCard(buckets, single: single, totals: totals)
                    .voltaCascade(index: 2)
            } else if totals.costs.count > 1 {
                AnalyticsSectionHeader("Charging cost", trailing: "\(totals.costs.count) currencies").padding(.top, AnalyticsStyle.sectionGap)
                AnalyticsGroup {
                    ForEach(Array(totals.costs.enumerated()), id: \.element) { index, entry in
                        AnalyticsRow(title: entry.currency, value: VoltaFormat.money(entry.amount, currency: entry.currency),
                                     showsDivider: index < totals.costs.count - 1)
                    }
                }
                AnalyticsFootnote("Sessions were billed in more than one currency, so totals are shown separately."
                                  + (totals.costCoverage.qualifier.map { " \($0)." } ?? "")).padding(.top, 10)
            }
        }
    }

    private func distanceRhythm(_ buckets: [Bucket]) -> some View {
        let latest = buckets.last?.start
        let driven = buckets.filter { $0.distanceKm > 0 }
        let average = driven.reduce(0) { $0 + $1.distanceKm } / Double(max(driven.count, 1))
        // Both layers share one scale, or the ghost would stretch the lit bar.
        let top = max(units.distanceValue(km: buckets.map(\.distanceKm).max() ?? 0), 1)
        return VStack(alignment: .leading, spacing: 10) {
            AnalyticsGlowChart(height: 96) { ghost in
                Chart(buckets) { b in
                    let lit = b.start == latest
                    BarMark(x: .value("Date", b.start, unit: period.bucket),
                            y: .value("Distance", ghost && !lit ? 0 : units.distanceValue(km: b.distanceKm)),
                            width: .fixed(period == .month ? 5 : 7))
                        .foregroundStyle(lit ? AnyShapeStyle(LinearGradient(colors: [AnalyticsStyle.mint, AnalyticsStyle.blue], startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom)))
                        .clipShape(Capsule())
                }
                .chartYScale(domain: 0...top)
                .chartStyled(ghost: ghost, showsYAxis: false)
            }
            // Bars grow from the baseline on arrival.
            .voltaGrow(index: 0)
            HStack {
                Text("Per \(period.bucketNoun)")
                Spacer()
                Text("\(units.formatDistance(average)) per driving \(period.bucketNoun)")
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance per \(period.bucketNoun), last \(period.days) days")
    }

    private func energyCard(_ buckets: [Bucket], totals: AnalyticsMath.Totals, sessions: Int) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                AnalyticsGlowChart(height: 150) { ghost in
                    Chart {
                        ForEach(buckets) { b in
                            if let added = b.energyAddedKwh {
                                BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", added), width: .fixed(4))
                                    .foregroundStyle(LinearGradient(colors: [AnalyticsStyle.blue.opacity(0.85), AnalyticsStyle.blue.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                                    .clipShape(Capsule())
                            }
                        }
                        ForEach(buckets.filter { $0.energyUsedKwh != nil }) { b in
                            if !ghost {
                                AreaMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", b.energyUsedKwh ?? 0))
                                    .foregroundStyle(LinearGradient(colors: [AnalyticsStyle.mint.opacity(0.14), AnalyticsStyle.mint.opacity(0)], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("Date", b.start, unit: period.bucket), y: .value("kWh", b.energyUsedKwh ?? 0))
                                .foregroundStyle(AnalyticsStyle.mint)
                                .lineStyle(StrokeStyle(lineWidth: ghost ? 4 : 1.8, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartStyled(ghost: ghost)
                }
                Rectangle().fill(AnalyticsStyle.hairline).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    AnalyticsFigure(label: "Used", value: totals.energyUsedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "kWh",
                                    caption: totals.energyUsedCoverage.qualifier, tint: AnalyticsStyle.mint)
                    Rectangle().fill(AnalyticsStyle.hairline).frame(width: 1, height: 44).padding(.horizontal, 14)
                    AnalyticsFigure(label: "Added", value: totals.energyAddedKwh.map { VoltaFormat.number($0, digits: 0) } ?? "—", unit: "kWh",
                                    caption: totals.energyAddedCoverage.qualifier ?? "\(sessions) sessions", tint: AnalyticsStyle.blue)
                }
            }
        }
    }

    private func costCard(_ buckets: [Bucket], single: AnalyticsMath.CurrencyAmount, totals: AnalyticsMath.Totals) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(VoltaFormat.money(single.amount, currency: single.currency))
                        .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    if let caption = costCaption(totals) {
                        Text(caption).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.secondary)
                    }
                }
                AnalyticsGlowChart(height: 110) { ghost in
                    Chart(buckets.filter { $0.cost != nil }) { b in
                        BarMark(x: .value("Date", b.start, unit: period.bucket), y: .value("Cost", b.cost ?? 0), width: .fixed(5))
                            .foregroundStyle(LinearGradient(colors: [AnalyticsStyle.amber, AnalyticsStyle.amber.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                            .clipShape(Capsule())
                    }
                    .chartXScale(domain: (buckets.first?.start ?? .now)...(buckets.last.map { Calendar.current.date(byAdding: period.bucket, value: 1, to: $0.start) ?? $0.start } ?? .now))
                    .chartStyled(ghost: ghost)
                }
                if let qualifier = totals.costCoverage.qualifier {
                    Text(qualifier + " — sessions without a cost aren't included.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.amber)
                }
            }
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

// MARK: - Analytics visual kit
// "Quiet instrument" pieces shared by the Analytics screens and the drive
// overviews (Roadtrips, Heatmap): one open hero numeral, a hairline stat strip,
// data drawn as thin light, lit cards only for grouped detail.

enum AnalyticsStyle {
    static let mint = Color.voltaMint
    static let blue = Color.voltaBlue
    static let amber = Color.voltaAmber
    static let red = Color.voltaRed
    static let secondary = Color.voltaTextSecondary
    static let tertiary = Color.voltaTextTertiary
    static let hairline = Color.voltaHairline
    static let sectionGap: CGFloat = 30
    static let cardGap: CGFloat = 12
    static let energy = LinearGradient(colors: [mint, blue], startPoint: .leading, endPoint: .trailing)
    static let heroFill = LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom)
}

/// Expanded-width hero numeral with a white→70% vertical fade and a small unit.
struct AnalyticsNumeral: View {
    var value: String
    var unit: String? = nil
    var size: CGFloat = 84

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            CountUpNumber(text: value)
                .font(.system(size: size, weight: .bold)).fontWidth(.expanded).tracking(-size / 42)
                .foregroundStyle(AnalyticsStyle.heroFill)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            if let unit, !unit.isEmpty {
                Text(unit).font(.system(size: max(13, size * 0.24), weight: .medium)).foregroundStyle(AnalyticsStyle.secondary)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

/// Open hero: eyebrow, the one number that matters, optional trailing instrument.
/// Carries the screen's `screen.<name>` identifier, like `DrivesHero`.
struct AnalyticsHero<Trailing: View>: View {
    var eyebrow: String
    var value: String
    var unit: String?
    var size: CGFloat
    var identifier: String
    var trailing: Trailing

    init(eyebrow: String, value: String, unit: String? = nil, size: CGFloat = 84, identifier: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.value = value
        self.unit = unit
        self.size = size
        self.identifier = identifier
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow).voltaLabelStyle(color: AnalyticsStyle.tertiary).lineLimit(1)
                AnalyticsNumeral(value: value, unit: unit, size: size)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier)
    }
}

extension AnalyticsHero where Trailing == EmptyView {
    init(eyebrow: String, value: String, unit: String? = nil, size: CGFloat = 84, identifier: String) {
        self.init(eyebrow: eyebrow, value: value, unit: unit, size: size, identifier: identifier) { EmptyView() }
    }
}

/// Value-over-caption columns separated by 1px hairlines.
struct AnalyticsStatStrip: View {
    var items: [(value: String, caption: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(AnalyticsStyle.hairline).frame(width: 1, height: 28) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(item.caption).font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase)
                        .foregroundStyle(AnalyticsStyle.tertiary).lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : 12)
                .accessibilityElement(children: .combine)
                .voltaArrival(delay: VoltaMotion.statDelay(index))
            }
        }
    }
}

/// Section title in the drive-day header voice: 19pt semibold, quiet trailing note.
struct AnalyticsSectionHeader<Trailing: View>: View {
    var title: String
    var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.bottom, 12)
    }
}

extension AnalyticsSectionHeader where Trailing == AnalyticsTrailingNote {
    init(_ title: String, trailing: String? = nil) {
        self.init(title) { AnalyticsTrailingNote(text: trailing) }
    }
}

struct AnalyticsTrailingNote: View {
    var text: String?
    var body: some View {
        if let text {
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.secondary).lineLimit(1)
        }
    }
}

struct AnalyticsLegendDot: View {
    var color: Color
    var label: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.7), radius: 3)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary)
        }
    }
}

struct AnalyticsFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small-caps label with a tint dot over an expanded figure; for inside lit cards.
struct AnalyticsFigure: View {
    var label: String
    var value: String
    var unit: String? = nil
    var caption: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let tint { Circle().fill(tint).frame(width: 5, height: 5).shadow(color: tint.opacity(0.7), radius: 3) }
                Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.2).textCase(.uppercase).foregroundStyle(AnalyticsStyle.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .bold)).fontWidth(.expanded).tracking(-0.6).monospacedDigit().foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit {
                    Text(unit.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(AnalyticsStyle.secondary)
                }
            }
            if let caption {
                Text(caption).font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Lit surface holding hairline-separated rows.
struct AnalyticsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground()
    }
}

/// One row of grouped detail: title (and quiet subtitle) left, value right.
struct AnalyticsRow<Accessory: View>: View {
    var title: String
    var subtitle: String?
    var value: String
    var valueColor: Color
    var showsDivider: Bool
    var accessory: Accessory

    init(title: String, subtitle: String? = nil, value: String, valueColor: Color = .white, showsDivider: Bool = true, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueColor = valueColor
        self.showsDivider = showsDivider
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(valueColor)
                        .multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.7)
                }
                accessory
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            if showsDivider { Rectangle().fill(AnalyticsStyle.hairline).frame(height: 1).padding(.leading, 18) }
        }
    }
}

extension AnalyticsRow where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, value: String, valueColor: Color = .white, showsDivider: Bool = true) {
        self.init(title: title, subtitle: subtitle, value: value, valueColor: valueColor, showsDivider: showsDivider) { EmptyView() }
    }
}

/// Thin glowing progress line; nil draws only the track.
struct AnalyticsBar: View {
    var fraction: Double?
    var colors: [Color] = [AnalyticsStyle.mint, AnalyticsStyle.blue]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                if let fraction {
                    SweepIn(delay: 0.1) { p in
                        let width = max(height, proxy.size.width * min(1, max(0, fraction)) * min(p, 1.02))
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: width)
                            .shadow(color: (colors.last ?? .white).opacity(0.55 + 0.35 * VoltaMotion.bloom(p)), radius: 5)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// ScoreDial-style open 270° gauge for any 0…1 fraction.
struct AnalyticsDial: View {
    var fraction: Double?
    var value: String
    var unit: String? = nil
    var caption: String? = nil
    var colors: [Color] = [AnalyticsStyle.mint.opacity(0.35), AnalyticsStyle.mint]
    var size: CGFloat = 86

    private var line: CGFloat { max(2.5, size * 0.04) }
    private var clamped: Double? { fraction.map { min(1, max(0, $0)) } }

    var body: some View {
        let tip = colors.last ?? .white
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let clamped, clamped > 0 {
                SweepIn { p in
                    Circle().trim(from: 0, to: min(0.75 * clamped * p, 0.765))
                        .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * clamped)),
                                style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(135))
                        .shadow(color: tip.opacity((size > 60 ? 0.5 : 0.25) * (1 + VoltaMotion.bloom(p))), radius: size > 60 ? size * 0.05 : 3)
                }
            }
            VStack(spacing: size * 0.025) {
                HStack(alignment: .firstTextBaseline, spacing: size * 0.012) {
                    CountUpNumber(text: value, alignment: .center)
                        .font(.system(size: size * 0.26, weight: .bold)).fontWidth(.expanded).tracking(-size * 0.006)
                        .monospacedDigit().foregroundStyle(AnalyticsStyle.heroFill)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if let unit {
                        Text(unit).font(.system(size: size * 0.09, weight: .semibold)).foregroundStyle(AnalyticsStyle.secondary)
                    }
                }
                if let caption {
                    Text(caption).font(.system(size: max(8, size * 0.05), weight: .semibold)).tracking(1.4)
                        .textCase(.uppercase).foregroundStyle(tip)
                }
            }
            .padding(.horizontal, size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

/// Draws a chart twice: a blurred copy underneath supplies the glow.
/// `ghost` is true for the glow copy; marks can thicken or drop fills there.
struct AnalyticsGlowChart<Content: View>: View {
    var height: CGFloat
    var radius: CGFloat = 5
    @ViewBuilder var content: (_ ghost: Bool) -> Content

    var body: some View {
        ZStack {
            content(true).blur(radius: radius).opacity(0.7)
                .allowsHitTesting(false).accessibilityHidden(true)
            content(false)
        }
        .frame(height: height)
    }
}

extension View {
    /// Quiet chart chrome: 10pt tertiary axis labels, hairline (6%) grid.
    /// `ghost` keeps the identical layout but hides chrome for glow layers.
    func chartStyled(ghost: Bool = false, showsYAxis: Bool = true) -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().foregroundStyle(ghost ? Color.clear : AnalyticsStyle.tertiary).font(.system(size: 10, weight: .medium))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(ghost ? Color.clear : Color.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(ghost ? Color.clear : AnalyticsStyle.tertiary).font(.system(size: 10, weight: .medium))
                }
            }
            .chartYAxis(showsYAxis ? .visible : .hidden)
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
