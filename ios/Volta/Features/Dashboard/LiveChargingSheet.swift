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

    init(initialStatus: VehicleStatus) {
        _status = State(initialValue: initialStatus)
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
        .task(id: vehicleID) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refresh() async {
        if let fresh = try? await dataSource.status(vehicleID: vehicleID) { status = fresh }
        guard let id = status.activeChargeId else { return }
        if let fresh = try? await dataSource.charge(id: id) { detail = fresh }
    }

    private var charging: Bool { status.isCharging }
    private var target: Int? { status.chargeLimit }
    private var readyAt: Date? {
        guard charging, let minutes = status.minutesToFull else { return nil }
        return Date.now.addingTimeInterval(Double(minutes) * 60)
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

    /// Wattly's session controls. Volta can't send vehicle commands yet, so
    /// they're shown for layout and disabled.
    private var controls: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            HStack(spacing: VoltaSpacing.md) {
                controlButton("Stop Charging", systemImage: "stop.fill", tint: .voltaRed)
                controlButton("Unlock Port", systemImage: "lock.open.fill", tint: .voltaTextPrimary)
            }
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
            Text("Charging controls need vehicle commands, which aren't connected yet.")
                .font(.caption).foregroundStyle(Color.voltaTextTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Charging controls unavailable")
    }

    private func controlButton(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.voltaCard, in: .rect(cornerRadius: VoltaRadius.control))
    }

    // MARK: Stats

    private var rates: ElectricityRates {
        app?.settings.rates ?? ElectricityRates(home: nil, dcFast: nil, currency: units.currency)
    }

    private var sessionSamples: [FleetTelemetrySample] {
        let start = status.chargeStartedAt ?? detail?.summary.start ?? .distantPast
        return (detail?.telemetry?.samples ?? []).filter { $0.t >= start }.sorted { $0.t < $1.t }
    }

    /// Range added since the session began: the car's rated range now minus
    /// the first rated range recorded in the session.
    private var rangeAddedKm: Double? {
        guard let now = status.ratedRangeKm,
              let first = sessionSamples.first(where: { $0.ratedRangeKm != nil })?.ratedRangeKm
                ?? detail?.samples.first(where: { $0.ratedRangeKm != nil })?.ratedRangeKm else { return nil }
        return max(0, now - first)
    }

    private var addedKwh: Double? { status.chargeEnergyAddedKwh ?? detail?.summary.energyAddedKwh }

    private var stats: some View {
        let rate = status.fastCharger == true ? (rates.dcFast ?? rates.home) : rates.home
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
        let points = sessionSamples
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            HStack {
                Text("Session").voltaLabelStyle()
                Spacer()
                HStack(spacing: VoltaSpacing.md) {
                    legend("kW", .voltaGreen)
                    legend("%", .voltaBlue)
                }
            }
            if points.count >= 2 {
                LiveSessionChart(samples: points, readyAt: readyAt, target: target.map(Double.init),
                                 currentLevel: Double(status.batteryLevel))
            } else {
                Text(detail == nil && status.activeChargeId != nil ? "Loading the session…" : "The session curve appears once a few readings arrive.")
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
/// at the car's ready time.
struct LiveSessionChart: View {
    var samples: [FleetTelemetrySample]
    var readyAt: Date?
    var target: Double?
    var currentLevel: Double

    private var top: Double {
        let peak = samples.compactMap(\.powerKw).max() ?? 0
        return max(1, (peak * 1.2).rounded(.up))
    }
    private func socY(_ percent: Double) -> Double { min(100, max(0, percent)) / 100 * top }
    private var end: Date { max(readyAt ?? .now, samples.last?.t ?? .now) }

    var body: some View {
        let power = samples.filter { $0.powerKw != nil }
        let soc = samples.filter { $0.batteryLevel != nil }
        let last = soc.last
        Chart {
            ForEach(power, id: \.t) { s in
                AreaMark(x: .value("Time", s.t), y: .value("kW", s.powerKw!), series: .value("Series", "fill"), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.voltaGreen.opacity(0.25), Color.voltaGreen.opacity(0.04)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.t), y: .value("kW", s.powerKw!), series: .value("Series", "power"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.voltaGreen)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            ForEach(soc, id: \.t) { s in
                LineMark(x: .value("Time", s.t), y: .value("kW", socY(s.batteryLevel!)), series: .value("Series", "soc"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.voltaBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let last, let readyAt, let target, readyAt > last.t {
                LineMark(x: .value("Time", last.t), y: .value("kW", socY(max(last.batteryLevel!, currentLevel))), series: .value("Series", "projection"))
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
            if let last = power.last {
                PointMark(x: .value("Time", last.t), y: .value("kW", last.powerKw!))
                    .foregroundStyle(Color.voltaGreen)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: (samples.first?.t ?? .now)...end)
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
