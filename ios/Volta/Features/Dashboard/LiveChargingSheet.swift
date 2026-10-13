import Charts
import MapKit
import SwiftUI

/// The charging session happening now: where, how fast, how long to the
/// target, what it has added and cost so far, and the session's curve with a
/// projection to the target. Refreshes every 30 s while open.
struct LiveChargingSheet: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app: AppModel?

    @State private var status: VehicleStatus
    @State private var detail: ChargeDetail?
    @State private var showControls = false
    /// The session whose detail is shown; it outlives the status's id so a
    /// finished session keeps its final totals and curve.
    @State private var shownChargeId: Int?

    init(initialStatus: VehicleStatus) {
        _status = State(initialValue: initialStatus)
        _shownChargeId = State(initialValue: initialStatus.activeChargeId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
                    place
                    levelAndPower
                    progress
                    controls
                    stats
                    sessionChart
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, VoltaSpacing.lg)
                .padding(.bottom, VoltaSpacing.xxl)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color.voltaBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("screen.liveCharge")
        .sheet(isPresented: $showControls, onDismiss: { Task { await refresh() } }) {
            ControlsView(initialStatus: status, vehicleName: app?.selectedVehicle?.name)
        }
        .task(id: vehicleID) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refresh() async {
        if let fresh = try? await dataSource.status(vehicleID: vehicleID) { status = fresh }
        // When charging ends the status may drop the id; the shown session is
        // read once more for its final readings. A different session never
        // shows another's detail, even while its own is not yet servable.
        let id = status.activeChargeId ?? shownChargeId
        if id != shownChargeId { detail = nil; shownChargeId = id }
        guard let id else { return }
        if let fresh = try? await dataSource.charge(id: id) { detail = fresh }
    }

    private var charging: Bool { status.isCharging }
    private var target: Int? { status.chargeLimit }
    /// The car's own estimate, counted from when it was made; none once past.
    private var readyAt: Date? {
        guard charging, let at = status.chargeReadyAt
                ?? status.minutesToFull.map({ status.updatedAt.addingTimeInterval(Double($0) * 60) }) else { return nil }
        return at > .now ? at : nil
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            if let location = status.location {
                let camera = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                                       distance: 600, heading: 0, pitch: 50)
                Map(initialPosition: .camera(camera), interactionModes: [])
                    .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .mapControlVisibility(.hidden)
                    .environment(\.colorScheme, .dark)
                    .saturation(0)
                    .brightness(-0.04)
                    .overlay { if charging { ChargingMarker() } }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                LinearGradient(colors: [Color(hex: 0x1B1E23), .voltaBackground], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.clear, .voltaBackground], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack {
                HStack(spacing: 6) {
                    StatusDot(color: stateColor, size: 7)
                    Text(stateText)
                        .font(.system(.caption, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(stateColor)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.black.opacity(0.6), in: .capsule)
                Spacer()
                GlassCircleButton(systemImage: "xmark", size: 38, accessibilityLabel: "Close") { dismiss() }
                    .accessibilityIdentifier("button.liveCharge.close")
            }
            .padding(.horizontal, VoltaSpacing.lg)
            .padding(.top, VoltaSpacing.lg)
        }
        .frame(height: 210)
        .clipped()
    }

    private var stateText: String {
        switch status.chargingState {
        case .complete: "COMPLETE"
        case .stopped: "STOPPED"
        case .disconnected: "UNPLUGGED"
        default: charging ? "CHARGING" : "NOT CHARGING"
        }
    }

    private var stateColor: Color {
        charging ? .voltaGreen : status.chargingState == .complete ? .voltaBlue : .voltaTextSecondary
    }

    // MARK: Place and level

    private var place: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.location.map(AddressPill.title(for:)) ?? "Charging")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
                .lineLimit(1)
            if let line = Self.chargerLine(status) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "J1772 · 241 V · 32 A" from what the car reports; nothing is guessed.
    static func chargerLine(_ status: VehicleStatus) -> String? {
        var parts: [String] = []
        if let connector = connector(status.chargeCableType, fast: status.fastCharger) { parts.append(connector) }
        if let v = status.chargerVoltage, v > 0 { parts.append("\(VoltaFormat.number(v, digits: 0)) V") }
        if let a = status.chargerCurrentA, a > 0 { parts.append("\(VoltaFormat.number(a, digits: 0)) A") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tesla's cable type as the connector people know it.
    static func connector(_ cable: String?, fast: Bool?) -> String? {
        switch cable {
        case "CableTypeSAE": "J1772"
        case "CableTypeIEC": "Type 2"
        case "CableTypeGB_AC": "GB/T"
        case "CableTypeGB_DC": "GB/T DC"
        default: fast == true ? "DC fast" : nil
        }
    }

    private var levelAndPower: some View {
        HStack(alignment: .firstTextBaseline) {
            BigNumber("\(status.batteryLevel)", unit: "%", size: 60)
            Spacer()
            if charging, let kw = status.chargerPowerKw {
                BigNumber(VoltaFormat.number(kw, digits: kw >= 20 ? 0 : 1), unit: "kW", size: 44, weight: .bold, color: .voltaGreen)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            GeometryReader { geo in
                let w = geo.size.width
                let fill = w * CGFloat(min(max(status.batteryLevel, 0), 100)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(height: 10)
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0x15803D), .voltaGreen, Color(hex: 0xA7F3D0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fill, height: 10)
                        .shadow(color: .voltaGreen.opacity(charging ? 0.6 : 0), radius: 6)
                    if let target {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().strokeBorder(Color.voltaBackground, lineWidth: 3))
                            .frame(width: 20, height: 20)
                            .offset(x: w * CGFloat(min(max(target, 0), 100)) / 100 - 10)
                    }
                }
                .frame(height: 20)
            }
            .frame(height: 20)
            HStack {
                if let target { Text("Target \(target)%").voltaLabelStyle() }
                Spacer()
                if let readyAt {
                    Text(readyLine(readyAt))
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(Color.voltaTextSecondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func readyLine(_ date: Date) -> String {
        var parts = ["Ready by \(VoltaFormat.clock(date))"]
        if let target { parts.append("to \(target)%") }
        if let kw = status.chargerPowerKw { parts.append("\(VoltaFormat.number(kw, digits: kw >= 20 ? 0 : 1)) kW") }
        return parts.joined(separator: " · ")
    }

    // MARK: Controls

    /// Charging actions live in the shared controls coordinator, so opening
    /// them here cannot create a second independent intent stream.
    private var controls: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            Button { showControls = true } label: {
                Label("Manage charging", systemImage: "bolt.car.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.voltaTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.voltaCard, in: .rect(cornerRadius: VoltaRadius.control))
            }
            .buttonStyle(VoltaPressStyle())
            .accessibilityHint("Opens live vehicle controls")
            HStack {
                Text("Charge current").font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                Spacer()
                HStack(spacing: VoltaSpacing.lg) {
                    Image(systemName: "minus")
                    Text(status.chargerCurrentA.map { "\(VoltaFormat.number($0, digits: 0)) A" } ?? "— A")
                        .font(.system(.body, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.voltaTextPrimary)
                    Image(systemName: "plus")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.voltaTextTertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.voltaRaised, in: .capsule)
            }
            Text("Open vehicle controls to stop charging or change the charge limit.")
                .font(.caption).foregroundStyle(Color.voltaTextSecondary)
        }
    }

    // MARK: Stats

    private var rates: ElectricityRates {
        app?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency)
    }

    /// The shown session's window: from its start (the status's, while it is
    /// the status's session) to its end, or now while open.
    private var window: (start: Date, end: Date)? {
        guard let detail else { return nil }
        let statusStart = status.activeChargeId == shownChargeId ? status.chargeStartedAt : nil
        return (min(statusStart ?? detail.summary.start, detail.summary.start), detail.summary.end ?? .now)
    }

    /// One source per curve, split at gaps and invalid readings, as on the
    /// charge detail screen: Fleet Telemetry, else TeslaMate's samples.
    private func curve(_ field: String, _ telemetryValue: (FleetTelemetrySample) -> Double?,
                       _ sampleValue: (ChargeSample) -> Double?) -> [ChargeCurvePoint] {
        guard let detail, let window else { return [] }
        return ChargeCurve.reduced(ChargeCurve.curve(telemetry: detail.telemetry, samples: detail.samples, field: field,
                                                     start: window.start, end: window.end,
                                                     telemetryValue: telemetryValue, sampleValue: sampleValue).points)
    }

    /// Range added since the session began: the car's rated range now minus
    /// the earliest valid rated range either source recorded in the session.
    /// Chosen apart from the chart's source, which needs whole curves.
    private var rangeAddedKm: Double? {
        guard let now = status.ratedRangeKm, let detail, let window else { return nil }
        let span = window.start...max(window.end, window.start)
        let telemetry = TelemetryMetricSeries(detail.telemetry, field: "RatedRange") { $0.ratedRangeKm }.points
            .filter { span.contains($0.t) }.map { (t: $0.t, value: $0.value) }
        let recorded = detail.samples.compactMap { s in s.ratedRangeKm.map { (t: s.t, value: $0) } }
            .filter { span.contains($0.t) && $0.value.isFinite }
        guard let first = (telemetry + recorded).min(by: { $0.t < $1.t }) else { return nil }
        return max(0, now - first.value)
    }

    private var addedKwh: Double? { status.chargeEnergyAddedKwh ?? detail?.summary.energyAddedKwh }

    private var stats: some View {
        let rate = rates.perKwh(fastCharger: status.fastCharger ?? detail?.summary.fastCharger ?? false)
        return HStack(alignment: .top, spacing: 0) {
            stat("Added", addedKwh.map { "+\(VoltaFormat.number($0, digits: 1))" } ?? "—", unit: "kWh")
            stat("Range", rangeAddedKm.map { "+\(VoltaFormat.number(units.distanceValue(km: $0), digits: 0))" } ?? "—",
                 unit: units.distanceUnit)
            VStack(alignment: .leading, spacing: 6) {
                Text("Cost").voltaLabelStyle()
                if let rate, let addedKwh {
                    BigNumber(VoltaFormat.money(addedKwh * rate, currency: rates.currency), size: 22, weight: .bold)
                } else {
                    SetRateButton(settings: app?.settings, size: 15, link: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VoltaSpacing.lg)
        .background(Color.voltaCard, in: .rect(cornerRadius: VoltaRadius.card))
    }

    private func stat(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).voltaLabelStyle()
            BigNumber(value, unit: unit, size: 22, weight: .bold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Session chart

    @ViewBuilder
    private var sessionChart: some View {
        let power = curve("Power", { $0.powerKw }, { $0.powerKw })
        let soc = curve("BatteryLevel", { $0.batteryLevel }, { $0.batteryLevel.map(Double.init) })
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            HStack {
                Text("Session").voltaLabelStyle()
                Spacer()
                HStack(spacing: VoltaSpacing.md) {
                    legend("kW", .voltaGreen)
                    legend("%", .voltaBlue)
                }
            }
            if power.count >= 2 || soc.count >= 2 {
                LiveSessionChart(power: power, soc: soc, readyAt: readyAt, target: target.map(Double.init),
                                 currentLevel: Double(status.batteryLevel))
            } else {
                Text(detail == nil && shownChargeId != nil ? "Loading the session…" : "The session curve appears once a few readings arrive.")
                    .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(VoltaSpacing.lg)
        .background(Color.voltaCard, in: .rect(cornerRadius: VoltaRadius.card))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Color.voltaTextSecondary)
        }
    }
}

/// Power (green, left axis) and state of charge (blue, right axis 0–100 %)
/// over the session, with the charge level projected (dashed) to the target
/// at the car's ready time. Each series is keyed by segment so a line never
/// bridges a gap or an invalid reading.
struct LiveSessionChart: View {
    var power: [ChargeCurvePoint]
    var soc: [ChargeCurvePoint]
    var readyAt: Date?
    var target: Double?
    var currentLevel: Double

    private var top: Double {
        let peak = power.map(\.value).max() ?? 0
        return max(1, (peak * 1.2).rounded(.up))
    }
    private func socY(_ percent: Double) -> Double { min(100, max(0, percent)) / 100 * top }
    private var start: Date { min(power.first?.t ?? .distantFuture, soc.first?.t ?? .distantFuture) }
    private var last: Date { max(power.last?.t ?? .distantPast, soc.last?.t ?? .distantPast) }
    private var end: Date { max(readyAt ?? .now, last) }

    var body: some View {
        Chart {
            ForEach(power) { p in
                AreaMark(x: .value("Time", p.t), y: .value("kW", p.value), series: .value("Series", "fill-\(p.segment)"), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.voltaGreen.opacity(0.25), Color.voltaGreen.opacity(0.04)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value("kW", p.value), series: .value("Series", "power-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.voltaGreen)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            ForEach(soc) { p in
                LineMark(x: .value("Time", p.t), y: .value("kW", socY(p.value)), series: .value("Series", "soc-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.voltaBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let lastSoc = soc.last, let readyAt, let target, readyAt > lastSoc.t {
                LineMark(x: .value("Time", lastSoc.t), y: .value("kW", socY(max(lastSoc.value, currentLevel))), series: .value("Series", "projection"))
                    .foregroundStyle(Color.voltaBlue.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
                LineMark(x: .value("Time", readyAt), y: .value("kW", socY(target)), series: .value("Series", "projection"))
                    .foregroundStyle(Color.voltaBlue.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
                PointMark(x: .value("Time", readyAt), y: .value("kW", socY(target)))
                    .foregroundStyle(Color.voltaBlue)
                    .symbolSize(30)
                    .annotation(position: .top, alignment: .trailing, spacing: 4) {
                        Text(VoltaFormat.clock(readyAt))
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
            }
            if let lastPower = power.last {
                PointMark(x: .value("Time", lastPower.t), y: .value("kW", lastPower.value))
                    .foregroundStyle(Color.voltaGreen)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.voltaTextTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(VoltaFormat.number(v, digits: v.rounded() == v ? 0 : 1)) }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaGreen.opacity(0.85))
            }
            AxisMarks(position: .trailing, values: [0, 50, 100].map(socY)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int((v / top * 100).rounded()))") }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaBlue.opacity(0.85))
            }
        }
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session power and charge level\(readyAt.map { ", reaching the target by \(VoltaFormat.clock($0))" } ?? "")")
    }
}

#Preview("Live charging") {
    Color.black.sheet(isPresented: .constant(true)) {
        LiveChargingSheet(initialStatus: VehicleStatus(
            vehicleId: 1, state: .charging, updatedAt: .now, batteryLevel: 72, usableBatteryLevel: 71, ratedRangeKm: 354,
            estRangeKm: 328, chargeLimit: 80, chargingState: .charging, chargerPowerKw: 7.7, minutesToFull: 48,
            insideTempC: 21, outsideTempC: 16, climateOn: false, driverTempSettingC: 20, locked: true, sentryMode: false,
            odometerKm: 38642, location: Location(latitude: 37.4419, longitude: -122.1430, heading: 115, address: "Palo Alto, CA", placeName: "Home"),
            firmware: nil, chargeEnergyAddedKwh: 2.9, chargerVoltage: 241, chargerCurrentA: 32, fastCharger: false,
            chargeCableType: "CableTypeSAE", chargeStartedAt: .now.addingTimeInterval(-1380), activeChargeId: MockDataSource.liveChargeID))
    }
}
