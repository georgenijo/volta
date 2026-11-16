import Charts
import SwiftUI

/// What a comparison opens with: the sessions to show first and, from a
/// session's own page, that session as the anchor (it enables "This place"
/// and fills the comparison with similar sessions until the owner picks).
struct ChargeComparisonRequest: Hashable, Sendable {
    var sessions: [ChargeSummary]
    var anchor: ChargeSummary? = nil

    static func comparing(_ session: ChargeSummary) -> Self { Self(sessions: [session], anchor: session) }
}

/// Charge curves of up to five sessions on one chart: power against charge
/// level (how batteries are compared) or against minutes since each session
/// began. Each session's curve is fetched from its own detail endpoint. When
/// fast and slow sessions are compared, the slow ones get their own panel.
struct ChargeComparisonView: View {
    var request: ChargeComparisonRequest

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var model = ChargeComparisonModel()
    @State private var axis: ChargeComparison.Axis = .soc
    @State private var picking = false
    @State private var selectedX: Double?
    @State private var highlighted: Int?

    /// Session colours, in slot order. Red is left out: it reads as a fault.
    static let palette: [Color] = [Color.voltaBlue, Color.voltaAmber, Color.voltaTextPrimary, Color.voltaGreen, HistoryTheme.purple]
    static func color(slot: Int) -> Color { palette[slot % palette.count] }

    static let changeLabel = "Change sessions"

    var body: some View {
        ScreenKit.Page(scroll: "charge-comparison", splits: !model.selection.isEmpty) {
            if model.selection.isEmpty {
                VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                    EmptyState(systemImage: "chart.xyaxis.line", title: "Nothing to compare yet",
                               message: "Choose up to \(ChargeComparison.maxSessions) charging sessions to put their curves on one chart.")
                        .accessibilityIdentifier("comparison.empty")
                    PillButton(Self.changeLabel, systemImage: "checklist", style: .accent) { picking = true }
                        .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
                        .accessibilityIdentifier("comparison.choose")
                }
                .padding(.top, 40)
            } else {
                ScreenKit.Segmented(options: ChargeComparison.Axis.allCases.map { ($0, $0.rawValue) }, selection: $axis)
                chartCard
            }
        } secondary: {
            if !model.selection.isEmpty {
                windowCard
                sessionsCard
                Text(footnote)
                    .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .screenKitPage("Compare Curves", screen: "charge-comparison")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { picking = true } label: { Label(Self.changeLabel, systemImage: "checklist") }
                    .tint(Color.voltaTextPrimary)
                    .accessibilityIdentifier("comparison.edit")
            }
        }
        .sheet(isPresented: $picking) {
            ChargeSessionPicker(model: model, anchor: request.anchor)
                .presentationDetents([.large])
        }
        // Retries only bump an attempt counter; these tasks do the loading,
        // so every load (first or retried) is cancelled with the screen.
        .task(id: [vehicleID, model.candidateAttempt]) {
            model.start(request)
            await model.loadCandidates(source: dataSource, vehicleID: vehicleID)
        }
        .task(id: DetailsKey(ids: model.selection.map(\.id), attempt: model.detailAttempt)) {
            await model.loadDetails(source: dataSource)
        }
        .onChange(of: axis) { selectedX = nil }
        .onChange(of: model.selection.map(\.id)) { if let id = highlighted, !model.selection.contains(where: { $0.id == id }) { highlighted = nil } }
    }

    // MARK: Chart

    private struct Entry: Identifiable {
        var session: ChargeSummary
        var slot: Int
        var points: [ChargeComparison.Point]
        var id: Int { session.id }
        var color: Color { ChargeComparisonView.color(slot: slot) }
    }

    private var entries: [Entry] {
        model.ordered.compactMap { session in
            guard let slot = model.slots[session.id], let curve = model.curves[session.id]?.value else { return nil }
            let points = axis == .soc ? curve.bySoc : curve.byTime
            return points.count >= 2 ? Entry(session: session, slot: slot, points: points) : nil
        }
    }

    private var loadedCurves: [ChargeComparison.SessionCurve] {
        model.ordered.compactMap { model.curves[$0.id]?.value }
    }

    private var names: [Int: String] { ChargeComparison.shortNames(model.ordered.map { ($0.id, $0.start) }) }

    private var chartCard: some View {
        let shown = entries
        let curves = loadedCurves
        let names = names
        let split = ChargeComparison.panels(shown.compactMap { entry in entry.points.map(\.kW).max().map { (entry.id, $0) } })
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(axis == .soc ? "Power by charge level · kW" : "Power over time · kW",
                                 trailing: "\(shown.count) curve\(shown.count == 1 ? "" : "s")")
                    verdictLine(names)
                }
                if shown.isEmpty {
                    chartPlaceholder(curves)
                } else if let split {
                    let high = shown.filter { split.high.contains($0.id) }, low = shown.filter { split.low.contains($0.id) }
                    chart(high, xDomain: domain(for: axis == .soc ? shown : high, curves: curves), height: 180, names: names)
                    Text("Slower sessions, on their own scale · kW")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.voltaTextSecondary)
                        .accessibilityIdentifier("comparison.chart.lowLabel")
                    chart(low, xDomain: domain(for: axis == .soc ? shown : low, curves: curves), height: 120, names: names)
                        .accessibilityIdentifier("comparison.chart.low")
                } else {
                    chart(shown, xDomain: domain(for: shown, curves: curves), height: 240, names: names)
                }
            }
        }
    }

    /// Charge % shares one range across panels; Time gives each its own.
    private func domain(for shown: [Entry], curves: [ChargeComparison.SessionCurve]) -> ClosedRange<Double> {
        let ids = Set(shown.map(\.id))
        let mine = model.ordered.filter { ids.contains($0.id) }.compactMap { model.curves[$0.id]?.value }
        return ChargeComparison.xDomain((mine.isEmpty ? curves : mine).filter { axis == .soc ? $0.hasSoc : $0.hasPower }, axis: axis)
    }

    @ViewBuilder private func chartPlaceholder(_ curves: [ChargeComparison.SessionCurve]) -> some View {
        let pending = model.ordered.contains { model.curves[$0.id] == nil || model.curves[$0.id]?.isLoading == true }
        Group {
            if pending {
                ProgressView().tint(Color.voltaTextSecondary)
            } else if axis == .soc, curves.contains(where: \.hasPower) {
                Text("These sessions recorded power but no charge level, so they can't be lined up by charge level. Switch to Time to see them.")
            } else {
                Text("None of these sessions recorded a power curve.")
            }
        }
        .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityIdentifier("comparison.chart.placeholder")
    }

    private func chart(_ shown: [Entry], xDomain: ClosedRange<Double>, height: CGFloat, names: [Int: String]) -> some View {
        let yDomain = ChargeCurve.powerDomain(shown.flatMap { $0.points.map(\.kW) })
        let tolerance = axis == .soc ? 1.5 : max(1, (xDomain.upperBound - xDomain.lowerBound) / 60)
        let readings = selectedX.map { x in
            shown.compactMap { entry in ChargeComparison.value(near: x, in: entry.points, tolerance: tolerance).map { (entry: entry, point: $0) } }
        } ?? []
        let ticks = ChargeComparison.xTicks(xDomain, axis: axis).map { (value: $0, text: xText($0)) }
        return Chart {
            ForEach(shown) { entry in sessionMarks(entry) }
            if let first = readings.first { readoutMark(first.point.x, readings: readings, names: names) }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedX)
        .chartXAxis {
            AxisMarks(values: ticks.map(\.value)) { _ in
                AxisGridLine().foregroundStyle(Color.voltaHairline)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: yDomain.upperBound, by: ChargeCurve.tickStep(yDomain.upperBound)))) { value in
                AxisGridLine().foregroundStyle(Color.voltaHairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(VoltaFormat.number(v, digits: 0)) }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .chartOverlay { proxy in
            ZStack(alignment: .topLeading) {
                ChartAxisLabels(proxy: proxy, ticks: ticks)
                if readings.isEmpty { endLabels(shown, proxy: proxy, names: names) }
            }
            .allowsHitTesting(false)
        }
        .frame(height: height)
        // Room for the x labels below and the line labels to the right.
        .padding(.bottom, ChartAxisLabels<Double>.height)
        .padding(.trailing, 44)
        // Charge level and minutes share no scale, so swap the chart rather
        // than morph one axis into the other.
        .id(axis)
        .accessibilityLabel(axis == .soc ? "Charging power by charge level, one line per session" : "Charging power over time, one line per session")
        .accessibilityValue(readings.first.map { first in
            "Selected \(xText(first.point.x)): " + readings.map { "\(names[$0.entry.id] ?? "") \(kw($0.point.kW)) kW" }.joined(separator: ", ")
        } ?? "")
        .accessibilityIdentifier("comparison.chart")
        .onAppear(perform: preselect)
    }

    // Chart content in typed pieces: one builder holding every mark is more
    // than the type checker in CI's Xcode will solve in time.

    private typealias Reading = (entry: Entry, point: ChargeComparison.Point)

    @ChartContentBuilder
    private func sessionMarks(_ entry: Entry) -> some ChartContent {
        let style: Color = entry.color.opacity(highlighted != nil && highlighted != entry.id ? 0.3 : 1)
        let stroke = StrokeStyle(lineWidth: highlighted == entry.id ? 3 : 2.2, lineCap: .round, lineJoin: .round)
        let xName = axis == .soc ? "Charge level" : "Minutes"
        ForEach(entry.points) { (p: ChargeComparison.Point) in
            let series: String = "\(entry.slot)-\(p.segment)"
            LineMark(x: .value(xName, p.x), y: .value("Power", p.kW), series: .value("Session", series))
                .foregroundStyle(style)
                .lineStyle(stroke)
                .interpolationMethod(.linear)
                .accessibilityLabel(label(entry.session))
                .accessibilityValue("\(xText(p.x)), \(kw(p.kW)) kW")
        }
        ForEach(isolated(entry.points)) { (p: ChargeComparison.Point) in
            PointMark(x: .value("x", p.x), y: .value("Power", p.kW))
                .foregroundStyle(style).symbolSize(20)
                .accessibilityHidden(true)
        }
    }

    private func readoutMark(_ x: Double, readings: [Reading], names: [Int: String]) -> some ChartContent {
        RuleMark(x: .value("Selected", x))
            .foregroundStyle(Color.voltaTextTertiary.opacity(0.6))
            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                readout(x, readings: readings, names: names)
            }
    }

    private func readout(_ x: Double, readings: [Reading], names: [Int: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(xText(x)).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
            ForEach(readings, id: \.entry.id) { reading in
                Text("\(names[reading.entry.id] ?? "") \(kw(reading.point.kW)) kW").foregroundStyle(reading.entry.color)
            }
            .font(.system(size: 12, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.voltaRaised, in: .rect(cornerRadius: 8))
    }

    /// Each line's short date at its right end, in its colour, moved apart
    /// where ends crowd together.
    private func endLabels(_ shown: [Entry], proxy: ChartProxy, names: [Int: String]) -> some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let frame = geo[anchor]
                let ends = shown.compactMap { entry -> (entry: Entry, x: CGFloat, y: CGFloat)? in
                    guard let last = entry.points.max(by: { $0.x < $1.x }), let x = proxy.position(forX: last.x),
                          let y = proxy.position(forY: last.kW) else { return nil }
                    return (entry, frame.minX + x, frame.minY + y)
                }
                let ys = ChargeComparison.nudged(ends.map { Double($0.y) }, minGap: 13, within: Double(frame.minY + 6)...Double(frame.maxY - 6))
                ForEach(Array(ends.enumerated()), id: \.element.entry.id) { index, end in
                    let dim = highlighted != nil && highlighted != end.entry.id
                    Text(names[end.entry.id] ?? "")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(end.entry.color.opacity(dim ? 0.3 : 1))
                        .fixedSize()
                        .offset(x: end.x + 4, y: ys[index] - 6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Screenshot aid (DEBUG): `-demoComparisonSelect X` opens the chart with
    /// the readout at X (percent, or minutes on the Time axis).
    private func preselect() {
        #if DEBUG
        guard selectedX == nil, let value = UserDefaults.standard.string(forKey: "demoComparisonSelect").flatMap(Double.init) else { return }
        selectedX = value
        #endif
    }

    private func isolated(_ points: [ChargeComparison.Point]) -> [ChargeComparison.Point] {
        let counts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        return points.filter { counts[$0.segment] == 1 }
    }

    // MARK: Verdict

    @ViewBuilder private func verdictLine(_ names: [Int: String]) -> some View {
        if let data = windowData, let verdict = ChargeComparison.verdict(data.rows.map { ($0.session.id, $0.span?.minutes) }),
           let leader = names[verdict.leader], let runnerUp = names[verdict.runnerUp] {
            let color = Self.color(slot: model.slots[verdict.leader] ?? 0)
            Text("\(Text(leader).foregroundStyle(color))\(ChargeComparison.verdictTail(verdict, window: data.window, runnerUp: runnerUp))")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.voltaTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("comparison.verdict")
        }
    }

    // MARK: Sessions

    private var sessionsCard: some View {
        ScreenKit.GroupCard(title: "Sessions") {
            let ordered = model.ordered
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                sessionRow(session, slot: model.slots[session.id] ?? index)
                if index < ordered.count - 1 { HairlineDivider(leadingInset: 16) }
            }
            Button { picking = true } label: {
                HStack {
                    Image(systemName: "checklist").foregroundStyle(Color.voltaBlue)
                    Text(Self.changeLabel)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaBlue)
                    Spacer()
                }
                .padding(16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { HairlineDivider() }
            .accessibilityIdentifier("comparison.sessions.edit")
        }
    }

    private func sessionRow(_ session: ChargeSummary, slot: Int) -> some View {
        let state = model.curves[session.id]
        let on = highlighted == session.id
        return HStack(alignment: .center, spacing: 12) {
            Capsule().fill(Self.color(slot: slot)).frame(width: on ? 6 : 4, height: 34).accessibilityHidden(true)
            ChargerBadge(kind: ChargerKind(session), size: 24, monochrome: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(VoltaFormat.dayTime(session.start))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                Text(detailLine(session))
                    .font(.system(size: 12)).foregroundStyle(Color.voltaTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            sessionStatus(session, state: state)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(on ? Color.voltaRaised : Color.clear)
        .contentShape(.rect)
        // Tapping a row picks out its line; tapping it again shows them all.
        .onTapGesture { withAnimation(.snappy) { highlighted = on ? nil : session.id } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(on ? "Shows every line" : "Highlights this session's line")
        .accessibilityAction { highlighted = on ? nil : session.id }
        .accessibilityIdentifier("comparison.session.\(session.id)")
    }

    /// A session's peak, its loading state, or why it has no curve.
    private func sessionStatus(_ session: ChargeSummary, state: Loadable<ChargeComparison.SessionCurve>?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch state {
            case nil, .loading?:
                ProgressView().controlSize(.small).tint(Color.voltaTextSecondary)
            case .failed?:
                Text("Couldn’t load").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaAmber)
                Button("Retry") { model.retry(session.id) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.voltaBlue)
            case .loaded(let curve)?:
                if let peak = curve.peakKw, curve.hasPower {
                    Text("\(kw(peak)) kW").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.voltaTextPrimary)
                    Text(curve.socAtPeak.map { "peak at \(Int($0.rounded()))%" } ?? "peak")
                        .font(.system(size: 11)).foregroundStyle(Color.voltaTextSecondary)
                    if axis == .soc, !curve.hasSoc {
                        Text("No charge level recorded").font(.system(size: 11)).foregroundStyle(Color.voltaAmber)
                    }
                } else {
                    Text("No curve recorded").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                }
            }
        }
        .multilineTextAlignment(.trailing)
        // Wraps the status rather than squeezing the place and charge line.
        .frame(maxWidth: 100, alignment: .trailing)
    }

    private func detailLine(_ s: ChargeSummary) -> String {
        var parts = [ChargePlace.title(s)]
        if let start = s.startBatteryLevel, let end = s.endBatteryLevel { parts.append("\(start)→\(end)%") }
        if let energy = s.energyAddedKwh { parts.append(VoltaFormat.energy(energy)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Same window

    private struct WindowRow {
        var session: ChargeSummary
        var span: ChargeComparison.WindowSpan?
    }

    /// The charge window every recorded curve with a charge level shares, and
    /// each such session's time and average across it.
    private var windowData: (window: ClosedRange<Int>, rows: [WindowRow])? {
        let withSoc = model.ordered.compactMap { s in model.curves[s.id]?.value.map { (session: s, curve: $0) } }.filter { $0.curve.hasSoc }
        guard withSoc.count >= 2, let window = ChargeComparison.commonWindow(withSoc.map(\.curve)) else { return nil }
        return (window, withSoc.map { WindowRow(session: $0.session, span: ChargeComparison.span($0.curve, across: window)) })
    }

    @ViewBuilder private var windowCard: some View {
        let loaded = model.ordered.compactMap { s in model.curves[s.id]?.value.map { (session: s, curve: $0) } }
        let withSoc = loaded.filter { $0.curve.hasSoc }
        if let data = windowData {
            let count = ["Both", "All three", "All four", "All five"][min(max(data.rows.count - 2, 0), 3)]
            let range = "\(data.window.lowerBound)–\(data.window.upperBound)%"
            ScreenKit.GroupCard(title: "Same charge window · \(range)",
                                footer: "\(count) recorded curves cover \(range), so this compares like with like.\n\nAverage power over the time spent in the window. Lines break where the record has a gap.") {
                HStack {
                    Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Average").frame(width: 78, alignment: .trailing)
                    Text("Time").frame(width: 64, alignment: .trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Color.voltaTextSecondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                ForEach(data.rows, id: \.session.id) { row in
                    windowRow(row.session) {
                        if let span = row.span {
                            Text(span.averageKw.map { "\(kw($0)) kW" } ?? "—").frame(width: 78, alignment: .trailing)
                            Text(VoltaFormat.duration(span.minutes)).frame(width: 64, alignment: .trailing)
                        } else {
                            // The record breaks inside the window: no figure is made up.
                            Text("Gap in record").foregroundStyle(Color.voltaTextSecondary).frame(width: 142, alignment: .trailing)
                        }
                    }
                }
                ForEach(loaded.filter { !$0.curve.hasSoc }, id: \.session.id) { item in
                    windowRow(item.session) {
                        Text(item.curve.hasPower ? "No charge level" : "No curve")
                            .foregroundStyle(Color.voltaTextSecondary).frame(width: 142, alignment: .trailing)
                    }
                }
            }
            .accessibilityIdentifier("comparison.window")
        } else if withSoc.count >= 2 {
            Text("These sessions share less than ten points of charge level, so they can’t be timed against each other.")
                .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func windowRow<Trailing: View>(_ session: ChargeSummary, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(Self.color(slot: model.slots[session.id] ?? 0)).frame(width: 8, height: 8)
                Text(names[session.id] ?? "").foregroundStyle(Color.voltaTextPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(Color.voltaTextPrimary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var footnote: String {
        axis == .soc
            ? "Each line is the session’s own recorded curve (the one its page shows), as the average power at each whole percent. Charge level is the car’s reported battery level."
            : "Each line is the session’s own recorded curve against minutes since that session began."
    }

    // MARK: Formatting

    private func kw(_ value: Double) -> String { VoltaFormat.number(value, digits: value >= 20 ? 0 : 1) }
    private func xText(_ x: Double) -> String { axis == .soc ? "\(Int(x.rounded()))%" : "\(Int(x.rounded())) min" }
    private func label(_ s: ChargeSummary) -> String { "\(VoltaFormat.dayTime(s.start)), \(ChargePlace.title(s))" }
}

private extension Loadable {
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

private struct DetailsKey: Hashable {
    var ids: [Int]
    var attempt: Int
}

// MARK: - Model

/// The chosen sessions, their curves and the sessions offered in the picker.
/// Curves load per session through `charge(id:)` (at most `maxSessions` at a
/// time); each load takes a generation, and a result lands only if it is
/// still the latest request and the session is still chosen.
@MainActor @Observable
final class ChargeComparisonModel {
    private(set) var selection: [ChargeSummary] = []
    private(set) var slots: [Int: Int] = [:]
    private(set) var curves: [Int: Loadable<ChargeComparison.SessionCurve>] = [:]
    private(set) var candidates: Loadable<[ChargeSummary]> = .loading
    private(set) var candidatesComplete = true
    private(set) var generation = 0
    /// Bumped by a retry; the screen's load tasks are keyed on these.
    private(set) var candidateAttempt = 0
    private(set) var detailAttempt = 0
    private var candidateGeneration = 0
    private var started = false
    private var edited = false
    private var anchor: ChargeSummary?

    /// Selection in colour-slot order.
    var ordered: [ChargeSummary] { selection.sorted { (slots[$0.id] ?? .max) < (slots[$1.id] ?? .max) } }

    func start(_ request: ChargeComparisonRequest) {
        guard !started else { return }
        started = true
        anchor = request.anchor
        setSelection(ChargeComparison.capped(request.sessions))
    }

    func toggle(_ session: ChargeSummary) {
        edited = true
        setSelection(ChargeComparison.toggled(selection, session))
    }

    func isChosen(_ session: ChargeSummary) -> Bool { selection.contains { $0.id == session.id } }

    private func setSelection(_ sessions: [ChargeSummary]) {
        selection = sessions
        slots = ChargeComparison.slots(sessions.map(\.id), previous: slots)
        let ids = Set(sessions.map(\.id))
        curves = curves.filter { ids.contains($0.key) }
    }

    /// Recent sessions for the picker (the last 12 months, plus anything
    /// already chosen). From a session's page, also fills the comparison with
    /// similar sessions unless the owner has already changed it.
    func loadCandidates(source: any VoltaDataSource, vehicleID: Int, now: Date = .now, calendar: Calendar = .current) async {
        candidateGeneration += 1
        let mine = candidateGeneration
        let from = calendar.date(byAdding: .month, value: -12, to: now)
        do {
            let result = try await fetchAllPages(maxPages: 20) {
                try await source.charges(vehicleID: vehicleID, range: DateRange(from: from, to: nil), cursor: $0)
            }
            guard !Task.isCancelled, mine == candidateGeneration else { return }
            let known = Set(result.items.map(\.id))
            candidates = .loaded(result.items + selection.filter { !known.contains($0.id) })
            candidatesComplete = result.isComplete
            if let anchor, !edited, selection.map(\.id) == [anchor.id] {
                setSelection(ChargeComparison.capped([anchor] + ChargeComparison.suggestions(for: anchor, among: result.items)))
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, mine == candidateGeneration else { return }
            candidates = .failed(error.localizedDescription)
        }
    }

    /// Loads every chosen session's curve that hasn't loaded, concurrently.
    func loadDetails(source: any VoltaDataSource) async {
        generation += 1
        let mine = generation
        let pending = selection.filter { curves[$0.id]?.value == nil }.map(\.id)
        for id in pending { curves[id] = .loading }
        await withTaskGroup(of: (Int, Result<ChargeComparison.SessionCurve, Error>).self) { group in
            for id in pending {
                group.addTask {
                    do { return (id, .success(ChargeComparison.curve(try await source.charge(id: id)))) }
                    catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard !Task.isCancelled, mine == generation, selection.contains(where: { $0.id == id }) else { continue }
                switch result {
                case .success(let curve): curves[id] = .loaded(curve)
                case .failure(let error):
                    if error is CancellationError { continue }
                    curves[id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Marks one session's curve for loading again; the screen's details
    /// task reruns because `detailAttempt` changed.
    func retry(_ id: Int) {
        curves[id] = nil
        detailAttempt += 1
    }

    /// Shows the picker as loading and reruns the screen's candidates task.
    func retryCandidates() {
        candidates = .loading
        candidateAttempt += 1
    }
}

// MARK: - Picker

/// Chooses up to five sessions, filtered by place or charger kind. The
/// filters and the count stay pinned above the list.
struct ChargeSessionPicker: View {
    @Bindable var model: ChargeComparisonModel
    var anchor: ChargeSummary?
    @State private var filter: ChargeComparison.Filter
    @Environment(\.dismiss) private var dismiss

    init(model: ChargeComparisonModel, anchor: ChargeSummary?) {
        self.model = model
        self.anchor = anchor
        let hasPlace = anchor.flatMap(ChargeComparison.placeKey) != nil
        _filter = State(initialValue: hasPlace ? .samePlace : .all)
    }

    private var filters: [(ChargeComparison.Filter, String)] {
        var options: [(ChargeComparison.Filter, String)] = []
        if anchor.flatMap(ChargeComparison.placeKey) != nil { options.append((.samePlace, "This place")) }
        options += ChargeComparison.KindGroup.allCases.map { (.kind($0), $0.title) }
        options.append((.all, "All"))
        return options
    }

    private var countText: String {
        let n = model.selection.count, cap = ChargeComparison.maxSessions
        return n >= cap ? "\(n) of \(cap) chosen. Remove one to add another." : "\(n) of \(cap) chosen"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadableContent(state: model.candidates, retry: { model.retryCandidates() }) { candidates in
                    let shown = ChargeComparison.filtered(candidates, by: filter, anchor: anchor)
                    VStack(alignment: .leading, spacing: 14) {
                        if shown.isEmpty {
                            Text("No sessions here in the last 12 months.")
                                .font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                                .padding(.vertical, 24)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                                    row(session)
                                    if index < shown.count - 1 { HairlineDivider(leadingInset: 56) }
                                }
                            }
                            .voltaCardBackground()
                        }
                        if !model.candidatesComplete {
                            Text("Only part of the last 12 months could be loaded.")
                                .font(.footnote).foregroundStyle(Color.voltaAmber)
                        }
                    }
                }
                .column()
                .padding(.vertical, 12)
            }
            // Named before the pinned header joins it, so the header keeps its own names.
            .accessibilityIdentifier("scroll.comparison-picker")
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .voltaScreenBackground()
            .navigationTitle("Change Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("comparison.picker.done")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowRow(spacing: 8) {
                ForEach(filters, id: \.0) { option in
                    chip(option.1, on: filter == option.0) { filter = option.0 }
                }
            }
            Text(countText)
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(model.selection.count >= ChargeComparison.maxSessions ? Color.voltaAmber : Color.voltaTextSecondary)
                .accessibilityIdentifier("comparison.picker.count")
        }
        .column()
        .padding(.vertical, 10)
        .background(Color.voltaBackground)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.voltaTextPrimary : Color.voltaTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? Color.voltaRaised : Color.clear, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.voltaHairline, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ session: ChargeSummary) -> some View {
        let chosen = model.isChosen(session)
        let full = model.selection.count >= ChargeComparison.maxSessions
        let slot = model.slots[session.id]
        return Button { withAnimation(.snappy) { model.toggle(session) } } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.voltaTextTertiary, lineWidth: 1.5).opacity(chosen ? 0 : 1)
                    if chosen, let slot {
                        Circle().fill(ChargeComparisonView.color(slot: slot))
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.voltaBackground)
                    }
                }
                .frame(width: 24, height: 24)
                ChargerBadge(kind: ChargerKind(session), size: 22, monochrome: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(VoltaFormat.dayTime(session.start)).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                    Text([ChargePlace.title(session), session.energyAddedKwh.map { VoltaFormat.energy($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Color.voltaTextSecondary).lineLimit(2)
                    if session.id == anchor?.id {
                        Text("This session").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.voltaBlue)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(session.maxPowerKw.map { "\(VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1)) kW" } ?? "—")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Color.voltaTextPrimary)
                    Text("peak").font(.system(size: 11)).foregroundStyle(Color.voltaTextSecondary)
                }
                .frame(minWidth: 56, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(.rect)
            .opacity(!chosen && full ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!chosen && full)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(!chosen && full ? "Up to \(ChargeComparison.maxSessions) sessions; remove one first" : "")
        .accessibilityIdentifier("comparison.pick.\(session.id)")
    }
}

private extension View {
    /// The picker's content column: the comparison's width, centred on wide
    /// screens such as the Duo's, with the screen's side insets.
    func column() -> some View {
        padding(.horizontal, ScreenKit.horizontalPadding)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// Lays its children out in rows, wrapping to a new row when the next one
/// would not fit, so no filter is cut off at the edge.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

// MARK: - Charging Insights shortcuts

/// Ready-made comparisons from the sessions Charging Insights loaded.
struct ChargeCurveShortcuts: View {
    var charges: [ChargeSummary]
    @Environment(\.pushMoreRoute) private var push

    private var shortcuts: [(title: String, detail: String, symbol: String, sessions: [ChargeSummary], id: String)] {
        let home = ChargeComparison.latest(charges, group: .home)
        let away = ChargeComparison.latest(charges, group: .away)
        let fast = ChargeComparison.latest(charges, group: .fast)
        let mixed = ChargeComparison.homeAgainstAway(charges)
        return [
            ("Home against away", "Your newest home and away sessions", "arrow.left.arrow.right", mixed, "home-away"),
            ("Latest home sessions", "The \(home.count) newest at home", "house.fill", home, "home"),
            ("Latest away AC", "The \(away.count) newest public AC sessions", "powerplug.fill", away, "away"),
            ("Latest DC fast", "The \(fast.count) newest fast charges", "bolt.fill", fast, "fast"),
        ].filter { $0.3.count >= 2 }
    }

    var body: some View {
        if let push {
            ScreenKit.GroupCard(title: "Compare charge curves",
                                footer: "Puts several sessions’ curves on one chart, by charge level or time. Choose any sessions from there.") {
                let items = shortcuts
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { push(.chargeComparison(ChargeComparisonRequest(sessions: item.sessions))) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.voltaTextSecondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.voltaTextPrimary)
                                Text(item.detail).font(.system(size: 13)).foregroundStyle(Color.voltaTextSecondary)
                            }
                            Spacer(minLength: 8)
                            ScreenKit.Chevron()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("insights.compare.\(item.id)")
                    if index < items.count - 1 { HairlineDivider(leadingInset: 54) }
                }
                if items.isEmpty {
                    Button { push(.chargeComparison(ChargeComparisonRequest(sessions: []))) } label: {
                        HStack {
                            Text(ChargeComparisonView.changeLabel).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.voltaTextPrimary)
                            Spacer()
                            ScreenKit.Chevron()
                        }
                        .padding(16).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("insights.compare.choose")
                }
            }
        }
    }
}

#Preview("Comparison") {
    NavigationStack {
        ChargeComparisonView(request: .comparing(MockDataSource.previewCharge(fast: true)))
    }
    .voltaPreviewEnvironment()
}
