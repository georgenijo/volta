import MapKit
import SwiftUI

struct DriveDetailView: View {
    var drive: DriveSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.units) private var units
    @Environment(\.vehicleID) private var vehicleID
    /// Optional so previews without an app model still render; nil = no local persistence.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var loader = HistoryDetailLoader<DriveDetail>()
    @State private var snapshot: TripSnapshot?
    @State private var loadedKey: LoadKey?
    @State private var mode: TripMapMode = .speed
    /// Raw scrub position (elapsed minutes) from whichever chart is touched.
    @State private var scrub: Double?
    @State private var replayMinute: Double?
    @State private var replayTask: Task<Void, Never>?
    @State private var shareImage: Image?

    /// Identity of what's on screen. A change drops the old state and any in-flight result.
    struct LoadKey: Hashable {
        var driveID: Int
        var vehicleID: Int
        var server: String?
    }

    private var key: LoadKey { LoadKey(driveID: drive.id, vehicleID: vehicleID, server: model?.settings.serverURL) }
    private var summary: DriveSummary { loader.detail?.summary ?? drive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                routeMap
                VStack(alignment: .leading, spacing: 18) {
                    TripHero(summary: summary, units: units)
                    HairlineDivider()
                    TripStatsRow(summary: summary, units: units, regen: snapshot?.regen, maxSpeed: snapshot?.maxSpeed)
                    if let timeline = snapshot?.timeline, timeline.quality != .dense {
                        TripSamplingNote(timeline: timeline)
                    }
                    TripCostCard(energyKwh: summary.costableEnergyKwh, rate: DrivePricing.rate(summary, fallback: model?.settings.electricityRate ?? 0.20),
                                 lookup: nil, editable: false) {}
                    if summary.costableEnergyKwh != nil {
                        Text(summary.energyProvenance).font(.system(size: 12)).foregroundStyle(HistoryTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot {
                        TripScoreCard(result: snapshot.score)
                    }
                    charts
                    if supplementalTelemetryMissing {
                        TripUnrecordedCard(outsideAvg: summary.outsideTempAvgC.map { "\(VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0))\(units.temperatureUnit)" })
                    }
                    TripDetailsList(rows: detailRows)
                }
                .padding(.horizontal, HistoryTheme.gutter)
            }
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { header }
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: key) { await load(key) }
        .onChange(of: units) { rebuild() }
        .onDisappear { stopReplay() }
    }

    // MARK: Loading

    private func load(_ key: LoadKey) async {
        if loadedKey != key {
            stopReplay()
            loader.reset()
            snapshot = nil
            scrub = nil
            shareImage = nil
            loadedKey = key
        }
        let ds = dataSource, id = key.driveID
        await loader.load { try await ds.drive(id: id) }
        guard !Task.isCancelled, loadedKey == key else { return }
        rebuild()

    }

    private func reload() { Task { await load(key) } }

    private func rebuild() {
        snapshot = loader.detail.map { TripSnapshot($0, units: units) }
        shareImage = loader.detail.flatMap { TripShareCard.render($0.summary, units: units) }
    }

    // MARK: Replay

    private var isPlaying: Bool { replayTask != nil }

    private func toggleReplay() {
        if isPlaying { stopReplay(); return }
        guard let timeline = snapshot?.timeline, timeline.points.count > 1 else { return }
        scrub = nil
        let total = timeline.totalMinutes
        let startMinute = (replayMinute ?? 0) >= total ? 0 : (replayMinute ?? 0)
        replayTask = Task { @MainActor in
            // Whole trip in ~15 s by the clock, however slowly frames render.
            let clock = ContinuousClock(), began = clock.now
            var minute = startMinute
            while minute <= total, !Task.isCancelled {
                replayMinute = minute
                try? await Task.sleep(for: .milliseconds(33))
                let elapsed = clock.now - began
                minute = startMinute + total * (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / 15
            }
            // A cancelled task must not clear a newer one started after it.
            guard !Task.isCancelled else { return }
            replayMinute = total
            replayTask = nil
        }
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
    }

    /// The one resolved position the map and every chart show: a chart scrub
    /// wins over replay. Resolved against the full timeline, never a chart's
    /// reduced plotting points.
    private var focus: TripSelection? {
        guard let timeline = snapshot?.timeline, let minute = scrub ?? replayMinute else { return nil }
        return TripSelection(minute: minute, timeline: timeline)
    }

    private var focusMinute: Double? { scrub ?? replayMinute }

    private var highlight: DrivePoint? {
        guard let timeline = snapshot?.timeline, let index = focus?.index else { return nil }
        return timeline.points[index]
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: HistoryTheme.background, location: 0),
                                   .init(color: HistoryTheme.background.opacity(0.75), location: 0.55),
                                   .init(color: HistoryTheme.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                BackButton()
                Spacer(minLength: 0)
                // Not GlassPill: its interactive glass swallowed taps on these
                // buttons in this overlay (verified on the simulator).
                headerPill {
                    ForEach(TripMapMode.allCases) { m in
                        Button { mode = m } label: {
                            Image(systemName: m.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(mode == m ? Color.black : .white)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(mode == m ? HistoryTheme.green : .clear))
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("Color route by \(m.title.lowercased())")
                        .accessibilityAddTraits(mode == m ? .isSelected : [])
                        .accessibilityIdentifier("trip.mode.\(m.rawValue)")
                    }
                }
                Spacer(minLength: 0)
                headerPill {
                    Button(action: toggleReplay) {
                        headerIcon(isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled((snapshot?.timeline.points.count ?? 0) < 2)
                    .accessibilityLabel(isPlaying ? "Pause replay" : "Replay trip")
                    .accessibilityIdentifier("trip.play")
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("Trip summary", image: shareImage)) {
                            headerIcon("square.and.arrow.up")
                        }
                        .accessibilityLabel("Share trip summary")
                        .accessibilityIdentifier("trip.share")
                    } else {
                        headerIcon("square.and.arrow.up")
                            .foregroundStyle(HistoryTheme.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
    }

    private func headerPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 5)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
    }

    private func headerIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 38, height: 38)
            .contentShape(Circle())
    }

    // MARK: Map

    private var routeMap: some View {
        let state = RouteMapState(detail: loader.detail, error: loader.error,
                                  preferredPath: snapshot?.usesFleetTelemetry == true ? snapshot?.timeline.points : nil)
        return ZStack(alignment: .bottom) {
            switch state {
            case .route, .single:
                if let snapshot, let route = snapshot.routes[mode] {
                    TripMapView(timeline: snapshot.timeline, route: route, mode: mode, highlight: highlight)
                } else {
                    HistoryTheme.card
                }
            case .notRecorded:
                HistoryTheme.card
                HistoryChartPlaceholder(height: 300, message: "Route not recorded for this drive.")
            case .loading:
                HistoryTheme.card
                HistoryChartPlaceholder(height: 300)
            case .failed(let message):
                HistoryTheme.card
                HistoryChartPlaceholder(height: 300, message: message) { reload() }
            }
            LinearGradient(colors: [.clear, HistoryTheme.background], startPoint: .init(x: 0.5, y: 0.72), endPoint: .bottom)
                .allowsHitTesting(false)
            if let snapshot, case .route = state {
                mapCaption(snapshot)
                    .padding(.bottom, 10)
            }
        }
        .frame(height: 400)
    }

    private func mapCaption(_ snapshot: TripSnapshot) -> some View {
        let timeline = snapshot.timeline
        let text: String
        if let focus, focus.index == nil {
            text = "No sample at \(TripChart.minuteLabel(focus.minute))"
        } else if let focus {
            text = "\(TripChart.minuteLabel(focus.sampleMinute ?? focus.minute)) of \(TripChart.minuteLabel(timeline.totalMinutes))"
        } else if timeline.gapCount > 0 {
            text = "\(timeline.gapCount) gap\(timeline.gapCount == 1 ? "" : "s") · dashed lines are not the driven path"
        } else {
            text = mode.title
        }
        return Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("trip.map.caption")
    }

    // MARK: Charts

    @ViewBuilder private var charts: some View {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        let heightUnit = units.distance == .miles ? "ft" : "m"
        chartCard("Battery", "battery.75percent", HistoryTheme.green, "%", series: snapshot?.battery,
                  accessory: batteryAccessory, step: true, domain: { TripChartDomain.padded($0) })
        chartCard("Power", "bolt.fill", HistoryTheme.amber, "kW", series: snapshot?.power,
                  accessory: snapshot?.power.values.max().map { "\(sampledPrefix(snapshot?.power))PEAK \(VoltaFormat.number($0, digits: 0)) kW" },
                  digits: 1, showsZero: true, domain: { TripChartDomain.zeroBased($0) })
        chartCard("Speed", "speedometer", HistoryTheme.blue, speedUnit, series: snapshot?.speed,
                  accessory: snapshot?.speed.values.max().map { "\(sampledPrefix(snapshot?.speed))MAX \(VoltaFormat.number($0, digits: 0))" + (summary.avgSpeedKph.map { " · AVG \(VoltaFormat.number(units.distanceValue(km: $0), digits: 0))" } ?? "") },
                  gradient: [HistoryTheme.green, HistoryTheme.amber, HistoryTheme.red], domain: { TripChartDomain.zeroBased($0) })
        if let snapshot, !snapshot.longitudinalAcceleration.isEmpty || !snapshot.lateralAcceleration.isEmpty {
            let values = snapshot.longitudinalAcceleration.values + snapshot.lateralAcceleration.values
            telemetryChartCard("Acceleration", "gyroscope", "m/s²",
                               traces: [
                                .init(label: "Longitudinal", color: HistoryTheme.green, series: snapshot.longitudinalAcceleration),
                                .init(label: "Lateral", color: HistoryTheme.blue, series: snapshot.lateralAcceleration),
                               ], accessory: "LONG / LAT", digits: 2, domain: TelemetryAcceleration.domain(values),
                               showsZero: true, height: 110)
        }
        chartCard("Elevation", "mountain.2.fill", HistoryTheme.purple, heightUnit, series: snapshot?.elevation,
                  accessory: snapshot.flatMap { rangeAccessory($0.elevation.values, unit: heightUnit) },
                  domain: { TripChartDomain.padded($0) })
        if let snapshot, !snapshot.energyRemaining.isEmpty {
            telemetryChartCard("Energy remaining", "bolt.batteryblock.fill", "kWh",
                               traces: [.init(label: "Energy", color: HistoryTheme.green, series: snapshot.energyRemaining)],
                               accessory: energyAccessory(snapshot), digits: 1, domain: TripChartDomain.padded(snapshot.energyRemaining.values, minPad: 0.5))
        }
        if let snapshot, !snapshot.batteryTempMin.isEmpty || !snapshot.batteryTempMax.isEmpty {
            let values = snapshot.batteryTempMin.values + snapshot.batteryTempMax.values
            telemetryChartCard("Battery temperature", "thermometer.medium", units.temperatureUnit,
                               traces: [
                                .init(label: "Min", color: HistoryTheme.blue, series: snapshot.batteryTempMin),
                                .init(label: "Max", color: HistoryTheme.red, series: snapshot.batteryTempMax),
                               ], accessory: rangeAccessory(values, unit: units.temperatureUnit), digits: 1, domain: TripChartDomain.padded(values, minPad: 2))
        }
        if let snapshot, !snapshot.insideTemp.isEmpty || !snapshot.outsideTemp.isEmpty {
            let values = snapshot.insideTemp.values + snapshot.outsideTemp.values
            telemetryChartCard("Cabin & outside", "thermometer.sun.fill", units.temperatureUnit,
                               traces: [
                                .init(label: "Inside", color: HistoryTheme.amber, series: snapshot.insideTemp),
                                .init(label: "Outside", color: HistoryTheme.blue, series: snapshot.outsideTemp),
                               ], accessory: "INSIDE / OUTSIDE", digits: 1, domain: TripChartDomain.padded(values, minPad: 2))
        }
    }

    private func rangeAccessory(_ values: [Double], unit: String) -> String? {
        guard let min = values.min(), let max = values.max() else { return nil }
        return "MIN \(VoltaFormat.number(min, digits: 0)) · MAX \(VoltaFormat.number(max, digits: 0)) \(unit)"
    }

    private func energyAccessory(_ snapshot: TripSnapshot) -> String? {
        guard let first = snapshot.energyRemaining.values.first, let last = snapshot.energyRemaining.values.last else { return nil }
        let used = summary.energyUsedKwh.map { " · USED \(VoltaFormat.number($0)) kWh" } ?? ""
        return "\(VoltaFormat.number(first)) → \(VoltaFormat.number(last)) kWh" + used
    }

    private var supplementalTelemetryMissing: Bool {
        guard let snapshot else { return true }
        return snapshot.energyRemaining.isEmpty && snapshot.batteryTempMin.isEmpty && snapshot.batteryTempMax.isEmpty
            && snapshot.insideTemp.isEmpty && snapshot.outsideTemp.isEmpty
    }

    /// Extremes of a sparsely recorded signal are only those of its samples,
    /// which can differ from the server's summary (e.g. the hero's max speed).
    private func sampledPrefix(_ series: TripChartSeries?) -> String { series?.signal.isDense == true ? "" : "SAMPLED " }

    private var batteryAccessory: String? {
        guard let from = summary.startBatteryLevel, let to = summary.endBatteryLevel else { return nil }
        let delta = to - from
        return "\(from)% → \(to)% · \(delta > 0 ? "+" : "")\(delta)%"
    }

    private func chartCard(_ title: String, _ icon: String, _ color: Color, _ unit: String, series: TripChartSeries?,
                           accessory: String?, digits: Int = 0, step: Bool = false, showsZero: Bool = false,
                           gradient: [Color]? = nil, domain: @escaping ([Double]) -> ClosedRange<Double>) -> some View {
        HistoryChartCard(title: title, systemImage: icon) {
            if let accessory {
                Text(accessory).voltaLabelStyle().tracking(1)
            }
        } chart: {
            if let error = loader.error {
                HistoryChartPlaceholder(height: 130, message: error) { reload() }
            } else if snapshot == nil {
                HistoryChartPlaceholder(height: 130)
            } else if let series, !series.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    TripChart(series: series, color: color, gradient: gradient, unit: unit, digits: digits, step: step,
                              showsZero: showsZero, yDomain: domain(series.values), scrub: $scrub, selection: focus)
                    if let note = TripChartSeries.coverageNote(series, title: title) {
                        Text(note)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HistoryTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("trip.chart.coverage.\(title.lowercased())")
                    }
                }
            } else {
                HistoryChartPlaceholder(height: 130, message: "Not recorded for this drive.")
            }
        }
    }

    private func telemetryChartCard(_ title: String, _ icon: String, _ unit: String,
                                    traces: [TelemetryTrace], accessory: String?, digits: Int,
                                    domain: ClosedRange<Double>, showsZero: Bool = false,
                                    height: CGFloat = 140) -> some View {
        let recorded = traces.reduce(0) { $0 + $1.series.points.count }
        let gapCount = Set(traces.flatMap(\.series.gaps).map { "\($0.start)-\($0.end)" }).count
        let downsampled = traces.contains { $0.series.downsampled }
        let truncated = traces.contains { $0.series.truncated }
        var note = "Fleet Telemetry · \(recorded.formatted()) recorded sample\(recorded == 1 ? "" : "s")"
        if gapCount > 0 { note += " · \(gapCount) known gap\(gapCount == 1 ? "" : "s") not joined" }
        if downsampled { note += " · downsampled" }
        if truncated { note += " · history truncated" }
        let end = summary.end ?? summary.start.addingTimeInterval(summary.durationMin * 60)
        return HistoryChartCard(title: title, systemImage: icon) {
            if let accessory { Text(accessory).voltaLabelStyle().tracking(1) }
        } chart: {
            VStack(alignment: .leading, spacing: 8) {
                TelemetryMetricChart(traces: traces, unit: unit, domain: domain,
                                     sessionStart: summary.start, sessionEnd: end, digits: digits,
                                     showsZero: showsZero, height: height, scrub: $scrub,
                                     selectionMinute: focusMinute)
                Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trip.telemetry.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
    }

    // MARK: Details

    private var detailRows: [(String, String)] {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        let heightUnit = units.distance == .miles ? "ft" : "m"
        func height(_ m: Double) -> String { "\(VoltaFormat.number(units.distance == .miles ? m * 3.28084 : m, digits: 0)) \(heightUnit)" }
        var rows: [(String, String)] = [
            ("Average speed", summary.avgSpeedKph.map { "\(VoltaFormat.number(units.distanceValue(km: $0), digits: 0)) \(speedUnit)" } ?? "—"),
        ]
        switch snapshot?.maxSpeed {
        case .value(let v): rows.append(("Max speed", "\(VoltaFormat.number(units.distanceValue(km: v), digits: 0)) \(speedUnit)"))
        case .atLeast(let v): rows.append(("Max speed", "≥ \(VoltaFormat.number(units.distanceValue(km: v), digits: 0)) \(speedUnit) (sparse samples)"))
        default: rows.append(("Max speed", "—"))
        }
        rows.append(("Regen recovered", TripStatsRow.regenDetail(snapshot?.regen)))
        rows.append(("Climb", loader.detail?.elevationGainM.map { "↑ " + height($0) } ?? "—"))
        switch snapshot?.descent {
        case .value(let v): rows.append(("Descent", "↓ " + height(v)))
        case .atLeast(let v): rows.append(("Descent", "≥ ↓ " + height(v) + " (partial)"))
        case .unavailable(let reason): rows.append(("Descent", "— · \(reason)"))
        case nil: rows.append(("Descent", "—"))
        }
        rows.append(("Outside (average)", summary.outsideTempAvgC.map { "\(VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0))\(units.temperatureUnit)" } ?? "—"))
        if let t = snapshot?.timeline {
            let telemetrySources: [String] = [
                snapshot?.usesFleetTelemetry == true ? "route" : nil,
                snapshot?.usesTelemetryBattery == true ? "battery" : nil,
                snapshot?.usesTelemetryPower == true ? "power" : nil,
                snapshot?.usesTelemetrySpeed == true ? "speed" : nil,
                snapshot?.usesTelemetryElevation == true ? "elevation" : nil,
            ].compactMap { $0 }
            if !telemetrySources.isEmpty {
                rows.append(("Fleet Telemetry used for", telemetrySources.joined(separator: ", ")))
            }
            rows.append(("Samples", "\(t.points.count.formatted()) distinct of \(t.rawCount.formatted()) rows"))
            if t.conflictingTimestamps > 0 {
                rows.append(("Conflicting timestamps", "\(t.conflictingTimestamps) · kept 1 row each by a fixed rule"))
            }
            rows.append(("Coverage", TripAnalysis.percent(t.coverage) + (t.gapCount > 0 ? " · \(t.gapCount) gap\(t.gapCount == 1 ? "" : "s")" : "")))
            if let median = t.medianInterval { rows.append(("Typical interval", "\(VoltaFormat.number(median, digits: 0)) s")) }
        }
        let tz = TimeZone.current
        rows.append(("Times shown in", "This device · \(tz.abbreviation(for: summary.start) ?? tz.identifier)"))
        return rows
    }
}

/// Back button matching the other detail screens.
private struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
    }
}

/// What the drive detail's map area shows.
enum RouteMapState: Equatable {
    case loading
    case failed(String)
    /// Detail loaded but the path is empty.
    case notRecorded
    /// Exactly one recorded position: a marker, no line.
    case single(DrivePoint)
    case route([DrivePoint])

    init(detail: DriveDetail?, error: String?, preferredPath: [DrivePoint]? = nil) {
        if let error { self = .failed(error); return }
        guard let detail else { self = .loading; return }
        let path = preferredPath ?? detail.path
        switch path.count {
        case 0: self = .notRecorded
        case 1: self = .single(path[0])
        default: self = .route(path)
        }
    }
}

extension DrivePoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

#Preview("Trip · dense") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, MockDataSource())
    .preferredColorScheme(.dark)
    .task { drive = try? await MockDataSource().drive(id: TripFixtures.denseDriveID).summary }
}

#Preview("Trip · sparse collector") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, MockDataSource())
    .preferredColorScheme(.dark)
    .task { drive = try? await MockDataSource().drive(id: TripFixtures.sparseDriveID).summary }
}

#Preview("Trip · error") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, HistoryPreviewFailingSource())
    .preferredColorScheme(.dark)
    .task { drive = try? await MockDataSource().drives(vehicleID: 1, range: .init(), cursor: nil).items.first }
}
