import Charts
import SwiftUI

/// Where charging energy and money go: home against away, AC against DC fast,
/// and charging cost per 100 mi / km over time. Uses only costs the server
/// recorded; a session without one is counted and left out, never priced at
/// zero, and amounts in different currencies are never added together.
struct ChargingInsightsView: View {
    enum Period: String, CaseIterable, Hashable, Sendable {
        case quarter = "90D", year = "1Y", all = "All"
        var days: Int? { switch self { case .quarter: 90; case .year: 365; case .all: nil } }
        var bucket: Calendar.Component { self == .quarter ? .weekOfYear : .month }
        var bucketNoun: String { self == .quarter ? "week" : "month" }
        var title: String {
            switch self {
            case .quarter: "Last 90 days"
            case .year: "Last 12 months"
            case .all: "All recorded history"
            }
        }
    }

    struct Snapshot: Sendable {
        /// The period these sessions were loaded for. A snapshot is only shown
        /// under its own period, never relabelled as another.
        var period: Period
        var charges: [ChargeSummary]
        var drives: [DriveSummary]
        var isComplete: Bool
    }

    /// Series colours: green stays for energy going in, not a generic series.
    static let homeColor = Color.voltaBlue
    /// Pale grey on the dark card, mid grey on the light one (3.8:1).
    static let awayColor = Color(light: 0x7D838C, dark: 0xC9CED6)
    static let acColor = Color.voltaGreen
    static let dcColor = Color.voltaAmber

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var model = ChargingInsightsModel()
    private var period: Period { model.period }

    /// What the screen shows for the selected period: a snapshot loaded for
    /// another period reads as loading until the selected one arrives.
    static func shown(_ state: Loadable<Snapshot>, period: Period) -> Loadable<Snapshot> {
        if case .loaded(let snapshot) = state, snapshot.period != period { return .loading }
        return state
    }

    private var shownState: Loadable<Snapshot> { model.shown }
    private var hasCharges: Bool { !(shownState.value?.charges.isEmpty ?? true) }

    var body: some View {
        ScreenKit.Page(scroll: "charging-insights", splits: hasCharges) {
            ScreenKit.Segmented(options: Period.allCases.map { ($0, $0.rawValue) }, selection: $model.period)
            LoadableContent(state: shownState, retry: load) { snapshot in
                if !snapshot.isComplete {
                    InlineBanner(systemImage: "exclamationmark.triangle",
                                 message: "Partial history: not every session could be loaded, so these figures cover only what did.",
                                 tint: ScreenKit.amber)
                }
                if snapshot.charges.isEmpty {
                    EmptyState(systemImage: "bolt.slash", title: "No charging sessions",
                               message: snapshot.period.days.map { "Sessions from the last \($0) days will be broken down here." }
                                   ?? "Your charging sessions will be broken down here.")
                        .padding(.top, 40)
                } else {
                    shares(snapshot)
                }
            }
        } secondary: {
            if hasCharges, let snapshot = shownState.value { costOverTime(snapshot) }
        }
        .screenKitPage("Charging Insights", screen: "charging-insights")
        .task(id: TaskKey(vehicleID: vehicleID, period: period)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var period: Period }

    // MARK: Shares

    @ViewBuilder
    private func shares(_ s: Snapshot) -> some View {
        let location = ChargingInsights.homeAway(s.charges)
        let current = ChargingInsights.acDc(s.charges)
        ShareCard(title: "Home and away", period: s.period.title, split: location,
                  colors: (Self.homeColor, Self.awayColor),
                  footnote: "Home is a charging place your TeslaMate geofence names exactly Home, whatever the charger type.")
        ShareCard(title: "AC and DC fast", period: s.period.title, split: current,
                  colors: (Self.acColor, Self.dcColor), footnote: nil)
    }

    // MARK: Cost per distance

    @ViewBuilder
    private func costOverTime(_ s: Snapshot) -> some View {
        let period = s.period
        let series = ChargingInsights.costPerDistance(charges: s.charges, drives: s.drives, bucket: period.bucket,
                                                      calendar: .current)
        let per = units.distance == .miles ? "100 mi" : "100 km"
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Cost per \(per)", trailing: series.currency)
                if let currency = series.currency, let perKm = series.costPerKm, !series.points.isEmpty {
                    ScreenKit.Numeral(value: VoltaFormat.money(per100(perKm), currency: currency), size: 40)
                    Text("Charging cost per \(per) driven, over the \(series.points.count) \(series.points.count == 1 ? period.bucketNoun : period.bucketNoun + "s") with every session priced.")
                        .font(.footnote).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Chart(series.points) { point in
                        BarMark(x: .value("Period", point.start, unit: period.bucket),
                                y: .value("Cost", per100(point.costPerKm)), width: .ratio(0.7))
                            .foregroundStyle(ScreenKit.amber.gradient)
                            .clipShape(.rect(cornerRadius: 3))
                            .accessibilityLabel(bucketTitle(point.start, period: period))
                            .accessibilityValue("\(VoltaFormat.money(per100(point.costPerKm), currency: currency)) per \(per), \(units.formatDistance(point.distanceKm, fractionDigits: 0)) driven, \(point.sessions) session\(point.sessions == 1 ? "" : "s")")
                        RuleMark(y: .value("Average", per100(perKm)))
                            .foregroundStyle(ScreenKit.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .accessibilityHidden(true)
                    }
                    .chartXScale(domain: chartDomain(series.points, period: period))
                    .chartXAxis {
                        AxisMarks(values: axisDates(series.points)) { _ in
                            AxisValueLabel(format: period.bucket == .month ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).day(),
                                           centered: true)
                                .foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(ScreenKit.hairline)
                            AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
                        }
                    }
                    .frame(height: 170)
                    .accessibilityLabel("Charging cost per \(per) by \(period.bucketNoun)")
                } else {
                    Text(ChargingInsights.costPerDistanceUnavailable(series, bucketNoun: period.bucketNoun))
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = exclusionNote(series, period: period) {
                    Text(note).font(.footnote).foregroundStyle(ScreenKit.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if !series.points.isEmpty, let currency = series.currency {
            ScreenKit.GroupCard(title: "By \(period.bucketNoun)",
                                footer: "Charges aren't tied to particular drives, so each \(period.bucketNoun) compares what you paid to charge with how far you drove in it.") {
                let rows = Array(series.points.reversed())
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, point in
                    ScreenKit.ValueRow(title: bucketTitle(point.start, period: period),
                                       subtitle: "\(VoltaFormat.money(point.cost, currency: currency)) · \(units.formatDistance(point.distanceKm, fractionDigits: 0))",
                                       showsDivider: index < rows.count - 1) {
                        Text(VoltaFormat.money(per100(point.costPerKm), currency: currency))
                            .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.voltaTextPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }

        Text("Costs are the prices your server recorded for each session. Set a cost per kWh on a TeslaMate geofence to price sessions there.")
            .font(.footnote).foregroundStyle(ScreenKit.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func per100(_ perKm: Double) -> Double { perKm / units.distanceValue(km: 1) * 100 }

    /// The plotted buckets, widened to at least four bucket lengths so one or
    /// two bars stay bar-shaped instead of filling the chart.
    private func chartDomain(_ points: [ChargingInsights.CostPoint], period: Period) -> ClosedRange<Date> {
        let calendar = Calendar.current
        guard let first = points.first?.start, let last = points.last?.start else { return Date.now...Date.now }
        let end = calendar.date(byAdding: period.bucket, value: 1, to: last) ?? last
        let earliest = calendar.date(byAdding: period.bucket, value: -4, to: end) ?? first
        return min(first, earliest)...end
    }

    /// Bucket starts to label, thinned to about five.
    private func axisDates(_ points: [ChargingInsights.CostPoint]) -> [Date] {
        let step = max(1, Int((Double(points.count) / 5).rounded(.up)))
        return points.enumerated().filter { $0.offset % step == 0 }.map(\.element.start)
    }

    private func exclusionNote(_ series: ChargingInsights.CostSeries, period: Period) -> String? {
        var parts: [String] = []
        let noun = period.bucketNoun
        func count(_ n: Int) -> String { "\(n) \(n == 1 ? noun : noun + "s")" }
        if series.unknownCostBuckets > 0 { parts.append("\(count(series.unknownCostBuckets)) with an unpriced session") }
        if series.unknownCurrencyBuckets > 0 { parts.append("\(count(series.unknownCurrencyBuckets)) with a session missing its currency") }
        if series.otherCurrencyBuckets > 0 { parts.append("\(count(series.otherCurrencyBuckets)) with sessions in another currency") }
        if series.noChargeBuckets > 0 { parts.append("\(count(series.noChargeBuckets)) with driving but no charging") }
        if series.noDistanceBuckets > 0 { parts.append("\(count(series.noDistanceBuckets)) with charging but no driving") }
        guard !parts.isEmpty else { return nil }
        return "Not shown: " + parts.joined(separator: "; ") + "."
    }

    private func bucketTitle(_ date: Date, period: Period) -> String {
        period.bucket == .month ? date.formatted(.dateTime.month(.wide).year())
                                : "Week of " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Charges and drives for `period`, tagged with it.
    static func fetch(source: any VoltaDataSource, vehicleID id: Int, period: Period, now: Date = .now,
                      calendar: Calendar = .current) async throws -> Snapshot {
        let from = period.days.flatMap { calendar.date(byAdding: .day, value: -$0 + 1, to: calendar.startOfDay(for: now)) }
        let range = DateRange(from: from, to: nil)
        async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: range, cursor: $0) }
        async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: range, cursor: $0) }
        let (c, d) = try await (charges, drives)
        return Snapshot(period: period, charges: c.items, drives: d.items, isComplete: c.isComplete && d.isComplete)
    }

    private func load() async { await model.load(source: dataSource, vehicleID: vehicleID) }
}

/// The selected period and what loaded for it. Every `load` (a period change
/// or a retry) takes a new generation; only the latest generation's success
/// or failure reaches `state`, so a slow older request can never overwrite a
/// newer one, even for the same period.
@MainActor @Observable
final class ChargingInsightsModel {
    var period: ChargingInsightsView.Period = .year
    private(set) var state: Loadable<ChargingInsightsView.Snapshot> = .loading
    private(set) var generation = 0

    var shown: Loadable<ChargingInsightsView.Snapshot> { ChargingInsightsView.shown(state, period: period) }

    func load(source: any VoltaDataSource, vehicleID: Int, now: Date = .now, calendar: Calendar = .current) async {
        generation += 1
        let mine = generation
        // A failure shown for an earlier request would read as this one's.
        if case .failed = state { state = .loading }
        do {
            let snapshot = try await ChargingInsightsView.fetch(source: source, vehicleID: vehicleID, period: period,
                                                                now: now, calendar: calendar)
            // Cancelled or superseded: a source that ignores cancellation still must not land here.
            guard !Task.isCancelled, mine == generation else { return }
            withAnimation(.smooth) { state = .loaded(snapshot) }
        } catch is CancellationError {
        } catch {
            // Cancelled or superseded: a source that ignores cancellation still must not land here.
            guard !Task.isCancelled, mine == generation else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// Energy and cost shares of one two-way split, each as a bar with both sides'
/// figures and the sessions behind them.
private struct ShareCard: View {
    var title: String
    var period: String
    var split: ChargingInsights.Split
    var colors: (Color, Color)
    var footnote: String?

    var body: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(title, trailing: "\(split.sessions) session\(split.sessions == 1 ? "" : "s")")
                share(kind: "Energy added", fraction: split.firstEnergyFraction,
                      first: VoltaFormat.energy(split.first.energySessions > 0 ? split.first.energyKwh : nil, fractionDigits: 0),
                      second: VoltaFormat.energy(split.second.energySessions > 0 ? split.second.energyKwh : nil, fractionDigits: 0),
                      firstDetail: sessions(split.first.energySessions),
                      secondDetail: sessions(split.second.energySessions))
                if split.energyUnknown > 0 {
                    note("\(sessions(split.energyUnknown).capitalizedFirst) without recorded energy aren't included.")
                }
                HairlineDivider()
                let costNote = ChargingInsights.costNote(split)
                if let currency = split.currency {
                    share(kind: "Cost", fraction: split.firstCostFraction,
                          first: VoltaFormat.money(split.first.cost, currency: currency),
                          second: VoltaFormat.money(split.second.cost, currency: currency),
                          firstDetail: priced(split.first), secondDetail: priced(split.second))
                    if let costNote { note(costNote) }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cost").voltaLabelStyle()
                        Text(costNote ?? "Unknown.")
                            .font(.subheadline)
                            .foregroundStyle(split.currencyUnknown > 0 ? ScreenKit.amber : ScreenKit.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let footnote {
                    Text(footnote).font(.caption).foregroundStyle(ScreenKit.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sessions(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }

    private func priced(_ side: ChargingInsights.Side) -> String {
        "\(side.costSessions) of \(side.sessions) priced"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(ScreenKit.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func share(kind: String, fraction: Double?, first: String, second: String,
                       firstDetail: String, secondDetail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind).voltaLabelStyle()
            ShareBar(fraction: fraction, colors: colors)
                .accessibilityElement()
                .accessibilityLabel("\(kind), \(title)")
                .accessibilityValue(fraction.map {
                    "\(split.first.label) \(percent($0)), \(first). \(split.second.label) \(percent(1 - $0)), \(second)."
                } ?? "Unknown")
            HStack(alignment: .top, spacing: 12) {
                column(split.first.label, color: colors.0, share: fraction.map { percent($0) }, value: first, detail: firstDetail)
                Spacer(minLength: 0)
                column(split.second.label, color: colors.1, share: fraction.map { percent(1 - $0) }, value: second,
                       detail: secondDetail, trailing: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func column(_ label: String, color: Color, share: String?, value: String, detail: String,
                        trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.voltaTextPrimary)
                if let share { Text(share).font(.subheadline).monospacedDigit().foregroundStyle(ScreenKit.secondary) }
            }
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(.voltaTextPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(ScreenKit.secondary)
                .multilineTextAlignment(trailing ? .trailing : .leading)
        }
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

/// A two-colour capsule; an unknown share draws an empty track.
private struct ShareBar: View {
    var fraction: Double?
    var colors: (Color, Color)

    var body: some View {
        GeometryReader { proxy in
            let f = min(1, max(0, fraction ?? 0))
            HStack(spacing: f > 0 && f < 1 ? 3 : 0) {
                if fraction != nil {
                    if f > 0 { Capsule().fill(colors.0).frame(width: max(6, (proxy.size.width - 3) * f)) }
                    if f < 1 { Capsule().fill(colors.1) }
                } else {
                    Capsule().fill(Color.voltaInk.opacity(0.08))
                }
            }
        }
        .frame(height: 10)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

#Preview("Populated") {
    NavigationStack { ChargingInsightsView() }.voltaPreviewEnvironment()
}

#Preview("Empty") {
    NavigationStack { ChargingInsightsView() }.voltaPreviewEnvironment(empty: true)
}
