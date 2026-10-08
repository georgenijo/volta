import MapKit
import SwiftUI

struct DriveDetailView: View {
    var drive: DriveSummary

    @Environment(\.dataSource) private var dataSource
    @Environment(\.units) private var units
    @State private var loader = HistoryDetailLoader<DriveDetail>()
    @State private var coloring: RouteColoring = .speed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routeMap
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    stats
                    charts
                }
                .padding(.horizontal, HistoryTheme.gutter)
            }
        }
        .contentMargins(.bottom, HistoryTheme.bottomInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) {
            // Scrim keeps the status bar and back button legible once content scrolls under them.
            ZStack(alignment: .top) {
                LinearGradient(stops: [.init(color: HistoryTheme.background, location: 0),
                                       .init(color: HistoryTheme.background.opacity(0.92), location: 0.55),
                                       .init(color: HistoryTheme.background.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                HistoryDetailHeader(title: "")
            }
        }
        .historyScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        let ds = dataSource, id = drive.id
        await loader.load { try await ds.drive(id: id) }
    }

    private var path: [DrivePoint] { loader.detail?.path ?? [] }

    // MARK: Map

    private var routeMap: some View {
        let state = RouteMapState(detail: loader.detail, error: loader.error)
        return ZStack(alignment: .bottomLeading) {
            switch state {
            case .route(let path):
                Map(initialPosition: .automatic) {
                    ForEach(RouteBuilder.segments(path, coloring: coloring)) { seg in
                        MapPolyline(coordinates: seg.coordinates)
                            .stroke(seg.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let first = path.first {
                        Annotation("Start", coordinate: first.coordinate) {
                            Circle().fill(HistoryTheme.card).frame(width: 16, height: 16)
                                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                        }
                        .annotationTitles(.hidden)
                    }
                    if let last = path.last {
                        Annotation("End", coordinate: last.coordinate) { endMarker }
                            .annotationTitles(.hidden)
                    }
                }
                .modifier(RouteMapStyle())
            case .single(let point):
                Map(initialPosition: .camera(MapCamera(centerCoordinate: point.coordinate, distance: 2000, heading: 0, pitch: 0))) {
                    Annotation("Recorded position", coordinate: point.coordinate) { endMarker }
                        .annotationTitles(.hidden)
                }
                .modifier(RouteMapStyle())
                .overlay(alignment: .top) { routeNote("Only one position recorded for this drive.").padding(.top, 110) }
            case .notRecorded:
                HistoryTheme.card
                HistoryChartPlaceholder(height: 360, message: "Route not recorded for this drive.")
            case .loading:
                HistoryTheme.card
                HistoryChartPlaceholder(height: 360)
            case .failed(let message):
                HistoryTheme.card
                HistoryChartPlaceholder(height: 360, message: message) { Task { await load() } }
            }
            LinearGradient(colors: [HistoryTheme.background.opacity(0.7), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, HistoryTheme.background], startPoint: .init(x: 0.5, y: 0.7), endPoint: .bottom)
                .allowsHitTesting(false)
            if case .route = state {
                VStack(alignment: .leading, spacing: 10) {
                    SegmentedRangePicker(selection: $coloring, options: RouteColoring.allCases) { $0.rawValue }
                        .padding(3)
                        .glassEffect(.regular, in: .capsule)
                    HStack(spacing: 10) {
                        ForEach(RouteBuilder.legend(coloring, units: units), id: \.0) { label, color in
                            HStack(spacing: 4) {
                                StatusDot(color: color)
                                Text(label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(HistoryTheme.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, HistoryTheme.gutter)
                .padding(.bottom, 4)
            }
        }
        .frame(height: 420)
    }

    private var endMarker: some View {
        ZStack {
            Circle().fill(HistoryTheme.blue.opacity(0.25)).frame(width: 30, height: 30)
            Circle().fill(HistoryTheme.blue).frame(width: 16, height: 16)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
        }
    }

    private func routeNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(HistoryTheme.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(HistoryTheme.card.opacity(0.92), in: .capsule)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RouteGlyph().frame(width: 14, height: 52).padding(.top, 5)
                VStack(alignment: .leading, spacing: 0) {
                    endpoint(drive.startAddress, time: drive.start)
                    Spacer(minLength: 10)
                    endpoint(drive.endAddress, time: drive.end)
                }
                .frame(height: 62)
            }
            HStack(alignment: .lastTextBaseline) {
                BigNumber(VoltaFormat.number(units.distanceValue(km: drive.distanceKm)), unit: units.distanceUnit, size: 56)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.drive-detail")
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(drive.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .voltaLabelStyle()
                    BigNumber(VoltaFormat.duration(drive.durationMin), size: 26)
                }
            }
            BatteryRangeView(from: drive.batteryEndpoints.from, to: drive.batteryEndpoints.to, tint: HistoryTheme.blue)
        }
    }

    private func endpoint(_ address: String?, time: Date?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(address ?? "Unknown")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text(time?.historyTime ?? "—")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HistoryTheme.secondary)
                .monospacedDigit()
        }
    }

    // MARK: Stats

    private var stats: some View {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        let regen = RegenEstimate(path)
        return VStack(alignment: .leading, spacing: 8) {
            HistoryStatGrid(items: [
                .init(label: "Efficiency", value: drive.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", unit: units.efficiencyUnit, systemImage: "leaf"),
                .init(label: "Energy", value: drive.energyUsedKwh.map { VoltaFormat.number($0) } ?? "—", unit: "kWh", systemImage: "bolt"),
                .init(label: "Battery", value: drive.batteryUsed.map { "−\($0)" } ?? "—", unit: "%", systemImage: "battery.50percent"),
                .init(label: "Avg speed", value: drive.avgSpeedKph.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", unit: speedUnit, systemImage: "speedometer"),
                .init(label: "Max speed", value: drive.maxSpeedKph.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", unit: speedUnit, systemImage: "gauge.with.dots.needle.100percent"),
                .init(label: "Regen", value: regen.map { ($0.isPartial ? "≥" : "") + VoltaFormat.number($0.kwh) } ?? "—",
                      unit: regen == nil ? nil : "kWh", systemImage: "arrow.triangle.2.circlepath"),
                .init(label: "Climb", value: loader.detail?.elevationGainM.map { VoltaFormat.number(units.distance == .miles ? $0 * 3.28084 : $0, digits: 0) } ?? "—", unit: units.distance == .miles ? "ft" : "m", systemImage: "mountain.2"),
                .init(label: "Outside", value: drive.outsideTempAvgC.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—", unit: units.temperatureUnit, systemImage: "thermometer.medium"),
                .init(label: "Start", value: drive.startBatteryLevel.map(String.init) ?? "—", unit: "%", systemImage: "battery.100percent"),
            ])
            if let note = regen?.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(HistoryTheme.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Charts

    @ViewBuilder private var charts: some View {
        let speedUnit = units.distance == .miles ? "mph" : "km/h"
        chartCard("Speed", "speedometer", HistoryTheme.blue, speedUnit) { $0.speedKph.map { units.distanceValue(km: $0) } }
        chartCard("Power", "bolt.fill", HistoryTheme.amber, "kW", digits: 1, showsZero: true) { $0.powerKw }
        chartCard("Elevation", "mountain.2.fill", HistoryTheme.purple, units.distance == .miles ? "ft" : "m") {
            $0.elevationM.map { units.distance == .miles ? $0 * 3.28084 : $0 }
        }
        chartCard("Battery", "battery.75percent", HistoryTheme.green, "%", domain: nil) { $0.batteryLevel.map(Double.init) }
    }

    private func chartCard(_ title: String, _ icon: String, _ color: Color, _ unit: String,
                           digits: Int = 0, showsZero: Bool = false, domain: ClosedRange<Double>? = nil,
                           value: @escaping (DrivePoint) -> Double?) -> some View {
        let points = path.compactMap { p in value(p).map { HistoryChartPoint(t: p.t, value: $0) } }
        let peak = points.map(\.value).max()
        return HistoryChartCard(title: title, systemImage: icon) {
            if let peak, title != "Battery" {
                Text("PEAK \(VoltaFormat.number(peak, digits: digits)) \(unit)")
                    .voltaLabelStyle()
                    .tracking(1)
            }
        } chart: {
            if let error = loader.error {
                HistoryChartPlaceholder(height: 120, message: error) { Task { await load() } }
            } else if loader.detail == nil {
                HistoryChartPlaceholder(height: 120)
            } else if points.count < 2 {
                HistoryChartPlaceholder(height: 120, message: "Not recorded for this drive.")
            } else {
                HistoryLineChart(points: points, color: color, unit: unit, yDomain: domain ?? batteryDomain(points, title: title),
                                 height: 120, digits: digits, showsZero: showsZero)
            }
        }
    }

    private func batteryDomain(_ points: [HistoryChartPoint], title: String) -> ClosedRange<Double>? {
        guard title == "Battery" || title == "Elevation" else { return nil }
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max(2, (hi - lo) * 0.2)
        return (lo - pad)...(hi + pad)
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

    init(detail: DriveDetail?, error: String?) {
        if let error { self = .failed(error); return }
        guard let detail else { self = .loading; return }
        switch detail.path.count {
        case 0: self = .notRecorded
        case 1: self = .single(detail.path[0])
        default: self = .route(detail.path)
        }
    }
}

private struct RouteMapStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { }
            .environment(\.colorScheme, .dark)
            // Keep room for the header up top.
            .safeAreaPadding(.top, 70)
            .safeAreaPadding(.bottom, 60)
    }
}

extension DrivePoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

#Preview("Drive detail") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, MockDataSource())
    .preferredColorScheme(.dark)
    .task { drive = try? await MockDataSource().drives(vehicleID: 1, range: .init(), cursor: nil).items.first }
}

#Preview("Drive detail · error") {
    @Previewable @State var drive: DriveSummary?
    NavigationStack {
        if let drive { DriveDetailView(drive: drive) } else { Color.clear }
    }
    .environment(\.dataSource, HistoryPreviewFailingSource())
    .preferredColorScheme(.dark)
    .task { drive = try? await MockDataSource().drives(vehicleID: 1, range: .init(), cursor: nil).items.first }
}
