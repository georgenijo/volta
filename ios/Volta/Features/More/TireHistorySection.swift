import Charts
import SwiftUI

/// Each wheel's recorded pressure over a period, under the Tires screen's
/// current readings: one line per wheel following the day's lowest reading
/// (or the day's mean), broken wherever a day has no readings, with the app's
/// low-pressure guide for reference. A wheel reading apart from the others is
/// focused by default; tapping a wheel focuses it and shows its daily range.
struct TireHistorySection: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var model = TireHistoryModel()
    @State private var choice: FocusChoice = .automatic
    @State private var selected: Date?
    @State private var attempt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The focused wheel follows the flagged one until the owner picks.
    private enum FocusChoice: Hashable { case automatic, none, wheel(TireWheel) }

    private typealias Series = [(wheel: TireWheel, plots: [TireHistoryMath.Plot])]

    /// Wheel series colours, from the chart colours the app already uses.
    static func color(_ wheel: TireWheel) -> Color {
        switch wheel {
        case .fl: Color.voltaBlue
        case .fr: Color.voltaGreen
        case .rl: HistoryTheme.purple
        case .rr: Color.voltaTextPrimary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Pressure history")
            ScreenKit.Segmented(options: TireHistoryMath.Period.allCases.map { ($0, $0.label) }, selection: $model.period)
            switch model.shown {
            case .loading:
                // The chart card's shape while the history loads.
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Daily lowest · psi").voltaLabelStyle()
                        RoundedRectangle(cornerRadius: 8).fill(Color.voltaTrack).frame(height: 180)
                        Text("FL FR RL RR").font(.caption)
                    }
                }
                .voltaSkeleton(true)
            case .failed(let message):
                ErrorState(title: "Couldn't load pressure history", message: message) { attempt += 1 }
            case .loaded(let snapshot):
                if snapshot.history.isEmpty {
                    EmptyState(systemImage: "gauge.with.dots.needle.33percent", title: "No pressure history",
                               message: "TeslaMate recorded no tire pressures in the \(snapshot.period.title). Readings arrive while the car is awake.")
                        .padding(.vertical, 24)
                        .accessibilityIdentifier("tires.history.empty")
                } else {
                    content(snapshot.history, period: snapshot.period)
                }
            }
        }
        .voltaFeedback(.selection, trigger: choice)
        // Try again bumps `attempt`, so the retried load is this task too and is
        // cancelled with the screen.
        .task(id: TaskKey(vehicleID: vehicleID, period: model.period, attempt: attempt)) { await load() }
    }

    private struct TaskKey: Hashable { var vehicleID: Int; var period: TireHistoryMath.Period; var attempt: Int }

    private func load() async { await model.load(source: dataSource, vehicleID: vehicleID) }

    private func focus(flagged: TireWheel?) -> TireWheel? {
        switch choice {
        case .automatic: flagged
        case .none: nil
        case .wheel(let wheel): wheel
        }
    }

    // MARK: Loaded

    @ViewBuilder
    private func content(_ history: TirePressureHistory, period: TireHistoryMath.Period) -> some View {
        let calendar = TireHistoryMath.calendar(for: history)
        let statistic = model.statistic
        let series = TireWheel.allCases.map { wheel in
            (wheel: wheel, plots: TireHistoryMath.plots(history.wheels[wheel], bucket: history.bucket,
                                                        statistic: statistic, calendar: calendar))
        }
        let apart = TireHistoryMath.apart(history, calendar: calendar)
        let focus = focus(flagged: apart?.wheel).flatMap { wheel in series.contains { $0.wheel == wheel && !$0.plots.isEmpty } ? wheel : nil }
        if let apart {
            InlineBanner(systemImage: "exclamationmark.triangle", message: banner(apart, history: history, calendar: calendar),
                         tint: Color.voltaAmber)
                .accessibilityIdentifier("tires.history.apart")
        }
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(statistic.title(history.bucket)) · \(units.pressureUnit)")
                        .voltaLabelStyle()
                    Spacer(minLength: 8)
                    Menu {
                        Picker("Line", selection: $model.statistic) {
                            ForEach(TireHistoryMath.Statistic.allCases, id: \.self) { Text($0.title(history.bucket)).tag($0) }
                        }
                    } label: {
                        Label(statistic.title(history.bucket), systemImage: "chevron.up.chevron.down")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
                    .accessibilityLabel("Line follows")
                    .accessibilityValue(statistic.title(history.bucket))
                }
                chart(series, history: history, focus: focus, calendar: calendar)
                legend(series, focus: focus, flagged: apart?.wheel, bucket: history.bucket)
            }
        }
        wheelRows(history, series: series, calendar: calendar, period: period)
        Text(footnote(history, statistic: statistic))
            .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func banner(_ apart: TireHistoryMath.Apart, history: TirePressureHistory, calendar: Calendar) -> String {
        let change = TireHistoryMath.change(history.wheels[apart.wheel], statistic: model.statistic, calendar: calendar)
        let next = calendar.date(byAdding: .day, value: history.bucket == .week ? 7 : 1, to: apart.on) ?? apart.on
        return TireHistoryMath.apartMessage(apart, change: change, isCurrent: history.to < next,
                                            bucket: history.bucket, units: units)
    }

    private func chart(_ series: Series, history: TirePressureHistory, focus: TireWheel?, calendar: Calendar) -> some View {
        let all = series.flatMap(\.plots)
        let guide = TireReading.lowGuideBar
        let focused = focus.flatMap { wheel in series.first { $0.wheel == wheel }?.plots }
        let domain = TireHistoryMath.yDomain(focused ?? all, guide: guide)
        let first = all.map(\.start).min() ?? history.to, last = all.map(\.start).max() ?? history.to
        let xDomain = first...max(last, first.addingTimeInterval(86_400))
        let ticks = ChartDateTicks.ticks(xDomain, calendar: calendar)
        let readings = selected.map { date in
            series.compactMap { entry -> (wheel: TireWheel, plot: TireHistoryMath.Plot)? in
                guard let plot = entry.plots.min(by: { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }),
                      abs(plot.start.timeIntervalSince(date)) < (history.bucket == .week ? 4 : 0.75) * 86_400 else { return nil }
                return (entry.wheel, plot)
            }
        } ?? []
        return Chart {
            if let focus, let focused { bandMarks(focused, focus: focus) }
            ForEach(series, id: \.wheel) { entry in wheelMarks(entry.wheel, plots: entry.plots, focus: focus) }
            // The focused line's latest value, named at its end (see `endLabel`).
            if let focus, readings.isEmpty, let end = focused?.last {
                PointMark(x: .value("Day", end.start), y: .value("Pressure", y(end.bar)))
                    .foregroundStyle(Self.color(focus))
                    .symbolSize(24)
                    .accessibilityHidden(true)
            }
            guideMark(guide)
            if let first = readings.first { readoutMark(first.plot.start, readings: readings) }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: y(domain.lowerBound)...y(domain.upperBound))
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: ticks.map(\.value)) { _ in
                AxisGridLine().foregroundStyle(Color.voltaHairline)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.voltaHairline)
                AxisValueLabel().font(.caption2).foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .chartOverlay { proxy in
            ZStack(alignment: .topLeading) {
                ChartAxisLabels(proxy: proxy, ticks: ticks)
                if let focus, readings.isEmpty, let end = focused?.last {
                    endLabel("\(focus.short) \(number(end.bar))", color: Self.color(focus), at: end.start, value: y(end.bar), proxy: proxy)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 210)
        // Room for the x labels below and the end label to the right.
        .padding(.bottom, ChartAxisLabels<Date>.height)
        .padding(.trailing, 40)
        .accessibilityLabel("Tire pressure by \(history.bucket == .week ? "week" : "day"), in \(units.pressureUnit)")
        .accessibilityValue(chartValue(readings: readings, focus: focus, focused: focused))
        .accessibilityIdentifier("tires.history.chart")
        .onAppear { preselect(history) }
    }

    // Chart content in typed pieces: one builder holding every mark is more
    // than the type checker in CI's Xcode will solve in time.

    private typealias Reading = (wheel: TireWheel, plot: TireHistoryMath.Plot)

    private func y(_ bar: Double) -> Double { units.pressureValue(bar: bar) }

    @ChartContentBuilder
    private func bandMarks(_ plots: [TireHistoryMath.Plot], focus: TireWheel) -> some ChartContent {
        ForEach(plots) { p in
            AreaMark(x: .value("Day", p.start), yStart: .value("Low", y(p.lowBar)), yEnd: .value("High", y(p.highBar)),
                     series: .value("Band", "band-\(p.segment)"))
                .foregroundStyle(Self.color(focus).opacity(0.18))
                .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private func wheelMarks(_ wheel: TireWheel, plots: [TireHistoryMath.Plot], focus: TireWheel?) -> some ChartContent {
        let style: Color = Self.color(wheel).opacity(focus != nil && focus != wheel ? 0.35 : 1)
        let stroke = StrokeStyle(lineWidth: focus == wheel ? 3 : 1.8, lineCap: .round, lineJoin: .round)
        ForEach(plots) { (p: TireHistoryMath.Plot) in
            let series: String = "\(wheel.rawValue)-\(p.segment)"
            LineMark(x: .value("Day", p.start), y: .value("Pressure", y(p.bar)), series: .value("Wheel", series))
                .foregroundStyle(style)
                .lineStyle(stroke)
                .interpolationMethod(.linear)
                .accessibilityLabel("\(wheel.title), \(p.start.formatted(date: .abbreviated, time: .omitted))")
                .accessibilityValue(pressure(p.bar))
        }
        ForEach(TireHistoryMath.isolated(plots)) { (p: TireHistoryMath.Plot) in
            PointMark(x: .value("Day", p.start), y: .value("Pressure", y(p.bar)))
                .foregroundStyle(style)
                .symbolSize(18)
                .accessibilityHidden(true)
        }
    }

    private func guideMark(_ guide: Double) -> some ChartContent {
        RuleMark(y: .value("Low guide", y(guide)))
            .foregroundStyle(Color.voltaAmber.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .annotation(position: .top, alignment: .leading, spacing: 2) {
                Text("Low guide").font(.caption2.weight(.medium)).foregroundStyle(Color.voltaAmber)
            }
            .accessibilityLabel("Low-pressure guide")
            .accessibilityValue(pressure(guide))
    }

    private func readoutMark(_ date: Date, readings: [Reading]) -> some ChartContent {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(Color.voltaTextTertiary.opacity(0.6))
            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                readout(date, readings: readings)
            }
    }

    private func readout(_ date: Date, readings: [Reading]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2.weight(.medium)).foregroundStyle(Color.voltaTextSecondary)
            ForEach(readings, id: \.wheel) { reading in
                Text("\(reading.wheel.short) \(pressure(reading.plot.bar))")
                    .foregroundStyle(Self.color(reading.wheel))
            }
            .font(.caption2.weight(.bold)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.voltaRaised, in: .rect(cornerRadius: 8))
    }

    /// A label just right of a line's last point. An overlay, not a Charts
    /// annotation: an annotation at the plot's right edge is dropped rather
    /// than drawn into the space beside it.
    private func endLabel(_ text: String, color: Color, at date: Date, value: Double, proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame, let x = proxy.position(forX: date), let y = proxy.position(forY: value) {
                let frame = geo[anchor]
                Text(text)
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(color)
                    .fixedSize()
                    .offset(x: frame.minX + x + 6, y: min(max(frame.minY + y - 7, frame.minY), frame.maxY - 14))
            }
        }
        .accessibilityHidden(true)
    }

    /// What the chart shows beyond its lines: the readout, or the focused wheel.
    private func chartValue(readings: [(wheel: TireWheel, plot: TireHistoryMath.Plot)], focus: TireWheel?,
                            focused: [TireHistoryMath.Plot]?) -> String {
        if let first = readings.first {
            return "Selected \(first.plot.start.formatted(.dateTime.month(.abbreviated).day())): "
                + readings.map { "\($0.wheel.title) \(pressure($0.plot.bar))" }.joined(separator: ", ")
        }
        guard let focus, let end = focused?.last else { return "" }
        return "\(focus.title) focused, latest \(pressure(end.bar))"
    }

    /// Screenshot aid (DEBUG): `-demoTireSelectDaysAgo N` opens the chart with
    /// the readout on the day N days before the newest bucket.
    private func preselect(_ history: TirePressureHistory) {
        #if DEBUG
        guard selected == nil, UserDefaults.standard.string(forKey: "demoTireSelectDaysAgo") != nil else { return }
        let newest = TireWheel.allCases.compactMap { history.wheels[$0].last?.start }.max() ?? history.to
        selected = newest.addingTimeInterval(-Double(UserDefaults.standard.integer(forKey: "demoTireSelectDaysAgo")) * 86_400)
        #endif
    }

    /// One chip per wheel with readings; tapping one focuses it, shows its
    /// daily range and dims the rest. A wheel with none says so and is inert.
    private func legend(_ series: Series, focus: TireWheel?, flagged: TireWheel?, bucket: TirePressureHistory.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(series, id: \.wheel) { entry in
                    if entry.plots.isEmpty {
                        Text("\(entry.wheel.short) · no data")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.voltaTextSecondary)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 44)
                            .accessibilityLabel("\(entry.wheel.title), no data")
                            .accessibilityIdentifier("tires.history.legend.\(entry.wheel.rawValue)")
                    } else {
                        chip(entry.wheel, on: focus == entry.wheel)
                    }
                }
                Spacer(minLength: 0)
            }
            if let focus {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(focus).opacity(0.18)).frame(width: 14, height: 10)
                    Text("\(focus.short) lowest to highest reading each \(bucket == .week ? "week" : "day")")
                        .font(.caption).foregroundStyle(Color.voltaTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tires.history.bandLegend")
            }
        }
    }

    private func chip(_ wheel: TireWheel, on: Bool) -> some View {
        Button {
            withAnimation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion)) { choice = on ? .none : .wheel(wheel) }
        } label: {
            HStack(spacing: 6) {
                Capsule().fill(Self.color(wheel)).frame(width: 12, height: 3)
                Text(wheel.short).font(.caption.weight(.semibold)).foregroundStyle(Color.voltaTextPrimary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? Color.voltaRaised : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.voltaHairline, lineWidth: 1))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wheel.title)
        .accessibilityHint(on ? "Shows every tire" : "Shows this tire's daily range")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("tires.history.legend.\(wheel.rawValue)")
    }

    private func wheelRows(_ history: TirePressureHistory, series: Series, calendar: Calendar, period: TireHistoryMath.Period) -> some View {
        let unusual = TireHistoryMath.unusualDrops(history, statistic: model.statistic)
        return ScreenKit.GroupCard {
            ForEach(Array(series.enumerated()), id: \.element.wheel) { index, entry in
                let change = TireHistoryMath.change(history.wheels[entry.wheel], statistic: model.statistic, calendar: calendar)
                ScreenKit.ValueRow(title: entry.wheel.title, subtitle: subtitle(entry.plots.last, period: period, bucket: history.bucket),
                                   showsDivider: index < series.count - 1) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let change {
                            Text(pressure(change.deltaBar, signed: true))
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(unusual.contains(entry.wheel) ? Color.voltaAmber : Color.voltaTextPrimary)
                            Text("in \(change.days) day\(change.days == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(Color.voltaTextSecondary)
                        } else {
                            Text("—").font(.callout.weight(.semibold)).foregroundStyle(Color.voltaTextSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tires.history.\(entry.wheel.rawValue)")
            }
        }
    }

    /// The latest value of the plotted line, named for its bucket.
    private func subtitle(_ last: TireHistoryMath.Plot?, period: TireHistoryMath.Period, bucket: TirePressureHistory.Bucket) -> String {
        guard let last else { return "No readings in the \(period.title)" }
        let what = "Latest " + model.statistic.title(bucket).lowercased()
        let date = last.start.formatted(.dateTime.month(.abbreviated).day())
        return "\(what) \(pressure(last.bar)) · \(bucket == .week ? "week of \(date)" : date)"
    }

    private func footnote(_ history: TirePressureHistory, statistic: TireHistoryMath.Statistic) -> String {
        let unit = history.bucket == .week ? "week" : "day"
        let line = statistic == .low
            ? "Lines follow each \(unit)’s lowest reading, the closest the record gets to a cold pressure."
            : "Lines follow each \(unit)’s mean reading, which includes tires warmed by driving."
        return "From TeslaMate’s tire pressure readings. \(line) A line breaks where a \(unit) has no readings. The dashed line is the app’s \(pressure(TireReading.lowGuideBar)) low guide. A wheel is compared with the others using readings taken at the same moments."
    }

    /// Bar to one decimal (TeslaMate's resolution), psi whole; `signed` marks a change.
    private func pressure(_ bar: Double, signed: Bool = false) -> String {
        TireHistoryMath.pressureText(bar, units: units, signed: signed)
    }

    /// The number alone, as the chart's end label shows it.
    private func number(_ bar: Double) -> String {
        VoltaFormat.number(TireHistoryMath.displayed(bar, units: units), digits: units.pressure == .bar ? 1 : 0)
    }
}

/// The selected period and what loaded for it, with request generations so
/// a slow older request never replaces a newer one (see `ChargingInsightsModel`).
@MainActor @Observable
final class TireHistoryModel {
    struct Snapshot: Sendable {
        var period: TireHistoryMath.Period
        var history: TirePressureHistory
    }

    var period: TireHistoryMath.Period = .quarter
    var statistic: TireHistoryMath.Statistic = .low
    private(set) var state: Loadable<Snapshot> = .loading
    private(set) var generation = 0

    /// A snapshot loaded for another period reads as loading.
    var shown: Loadable<Snapshot> {
        if case .loaded(let snapshot) = state, snapshot.period != period { return .loading }
        return state
    }

    static let unsupportedMessage = "This server doesn’t keep tire pressure history yet. Update volta-api to see it."

    func load(source: any VoltaDataSource, vehicleID: Int, now: Date = .now, calendar: Calendar = .current) async {
        generation += 1
        let mine = generation, period = period
        if case .failed = state { state = .loading }
        do {
            let range = DateRange(from: period.from(now: now, calendar: calendar), to: nil)
            let history = try await source.tireHistory(vehicleID: vehicleID, range: range)
            guard !Task.isCancelled, mine == generation else { return }
            state = .loaded(Snapshot(period: period, history: history))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, mine == generation else { return }
            state = .failed((error as? VoltaError) == .notFound ? Self.unsupportedMessage : error.localizedDescription)
        }
    }
}

/// The rotation reminder the owner keeps in Maintenance, if any, as a row
/// that opens Maintenance. The app sends no notifications.
struct TireRotationRow: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.pushMoreRoute) private var push
    @State private var item: Loadable<ServiceItem?> = .loading

    var body: some View {
        if let push {
            Button { push(.maintenance) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.medium)).foregroundStyle(ScreenKit.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tire rotation").font(.callout.weight(.medium)).foregroundStyle(Color.voltaTextPrimary)
                        Text(status).font(.footnote).foregroundStyle(statusTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ScreenKit.Chevron()
                }
                .padding(16)
                .contentShape(.rect)
                .voltaCardBackground()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens Maintenance")
            .accessibilityIdentifier("tires.rotation")
            .task(id: vehicleID) { await load() }
        }
    }

    private var status: String {
        switch item {
        case .loading: "Checking Maintenance…"
        case .failed: "Maintenance couldn’t load. Open it to set a reminder."
        case .loaded(nil): "No reminder yet. Add one in Maintenance."
        case .loaded(let item?): rotation(item).text
        }
    }

    private func rotation(_ item: ServiceItem) -> TireHistoryMath.RotationStatus {
        TireHistoryMath.rotationStatus(remainingKm: item.remainingKm, remainingDays: item.remainingDays) {
            units.formatDistance($0, fractionDigits: 0)
        }
    }

    private var statusTint: Color {
        if case .loaded(let item?) = item, rotation(item).isDue || (item.progress ?? 0) >= 1 { return Color.voltaAmber }
        return Color.voltaTextSecondary
    }

    private func load() async {
        do {
            let state = try await dataSource.service(vehicleID: vehicleID)
            guard !Task.isCancelled else { return }
            item = .loaded(TireHistoryMath.rotationItem(state.items))
        } catch {
            guard !Task.isCancelled else { return }
            item = .failed(error.localizedDescription)
        }
    }
}

#Preview("Tire history") {
    NavigationStack { ScrollView { TireHistorySection().padding() } }.voltaPreviewEnvironment()
}
