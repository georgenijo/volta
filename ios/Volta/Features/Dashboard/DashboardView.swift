import SwiftUI
import WidgetKit

/// Dashboard tab: 3D map backdrop, battery + range, quick controls, metric
/// cards, 48h activity strip, and Today/7D/30D summary.
struct DashboardView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.vehicleSurfaces) private var surfaces
    @Environment(\.scenePhase) private var scenePhase
    /// Owns the vehicle selection; absent in previews.
    @Environment(AppModel.self) private var app: AppModel?

    @State private var model = DashboardModel()
    @State private var scrollOffset: CGFloat = 0
    @State private var showControls = false
    @State private var showVehicle = false
    @State private var showNotifications = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Visible map height below the safe area before content starts.
    private let mapReveal: CGFloat = 300
    /// Total map height (extends under the content top, where it fades out).
    private let mapHeight: CGFloat = 520

    var body: some View {
        ZStack(alignment: .top) {
            Color.voltaBackground.ignoresSafeArea()
            mapLayer
            content
            header
        }
        .preferredColorScheme(.dark)
        .task(id: vehicleID) {
            await load()
            #if DEBUG
            // Screenshot aid: `-dashboardScrollY 420` starts the dashboard scrolled;
            let y = UserDefaults.standard.double(forKey: "dashboardScrollY")
            if y > 0 { scrollPosition.scrollTo(y: y) }
            // `-dashboardOpenControls YES` opens the Controls sheet on launch.
            if UserDefaults.standard.bool(forKey: "dashboardOpenControls") { showControls = true }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Back in the foreground: refresh the screen, widgets and Live Activities.
            guard phase == .active, let last = model.lastLoadedAt, Date.now.timeIntervalSince(last) > 30 else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            // "Today" is a local day: hide totals from the old zone, refetch in the
            // new one (which also rewrites the widget snapshot), and reload widgets
            // so they re-check the zone now.
            model.deviceZoneChanged()
            WidgetCenter.shared.reloadAllTimelines()
            Task { await load() }
        }
        .sheet(isPresented: $showControls) {
            ControlsView(initialStatus: model.status, vehicleName: model.vehicle?.name)
        }
        .sheet(isPresented: $showVehicle) {
            VehicleInfoSheet(vehicle: model.vehicle, status: model.status, vehicles: model.vehicles,
                             selectedID: vehicleID, onSelect: selectVehicle)
                .presentationDetents(selectVehicle == nil ? [.medium] : [.medium, .large])
        }
    }

    /// Switching re-keys the signed-in shell (`\.vehicleID`), which reloads every
    /// screen for the chosen car. nil when there's nothing to switch to, or in
    /// the launch demo, whose vehicle is fixed.
    private var selectVehicle: ((Int) -> Void)? { Self.selectVehicle(app: app, vehicles: model.vehicles) }

    static func selectVehicle(app: AppModel?, vehicles: [Vehicle]) -> ((Int) -> Void)? {
        guard let app, !app.isLaunchDemo, vehicles.count > 1 else { return nil }
        return { id in if let vehicle = vehicles.first(where: { $0.id == id }) { app.select(vehicle) } }
    }

    private func load() async {
        await model.load(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces)
    }

    // MARK: Map

    private var mapLayer: some View {
        let progress = min(max(scrollOffset / mapReveal, 0), 1)
        return DashboardMap(location: model.status?.location,
                            sentry: model.status?.sentryMode ?? false,
                            state: model.status?.state)
            .frame(height: mapHeight)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .voltaBackground.opacity(0.85), .voltaBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .overlay(Color.voltaBackground.opacity(progress * 0.6))
            .offset(y: -max(scrollOffset, 0) * 0.45 + max(-scrollOffset, 0) * 0.5)
            .scaleEffect(1 + max(-scrollOffset, 0) / 900, anchor: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .redacted(reason: model.status == nil ? .placeholder : [])
    }

    // MARK: Header

    private var header: some View {
        let fade = min(max((scrollOffset - mapReveal * 0.6) / 80, 0), 1)
        return ZStack {
            Image("Wordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .foregroundStyle(Color.voltaTextPrimary.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .accessibilityLabel("Volta")
                .accessibilityAddTraits(.isHeader)
            HStack {
                GlassCircleButton(systemImage: "car.fill", size: 52,
                                  accessibilityLabel: selectVehicle == nil ? "Vehicle" : "Vehicle and switch vehicles") {
                    showVehicle = true
                }
                .accessibilityIdentifier("button.vehicle")
                Spacer()
                GlassCircleButton(systemImage: "bell.fill", size: 52, badge: false,
                                  accessibilityLabel: "Notifications") {
                    showNotifications = true
                }
                .popover(isPresented: $showNotifications) {
                    Text("No notifications")
                        .font(.subheadline)
                        .foregroundStyle(Color.voltaTextSecondary)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, VoltaSpacing.screen - 4)
        .padding(.bottom, VoltaSpacing.md)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: .voltaBackground, location: 0),
                                   .init(color: .voltaBackground.opacity(0.95), location: 0.6),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 190)
                .ignoresSafeArea(edges: .top)
                .opacity(fade)
                .allowsHitTesting(false)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .failed(let message):
            failure(message)
        case .noData:
            noData
        case .loading, .loaded:
            scroll
        }
    }

    private var scroll: some View {
        let status = model.status ?? .skeleton
        let isPlaceholder = model.status == nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: mapReveal)
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.refreshError {
                        InlineBanner(systemImage: "wifi.exclamationmark",
                                     message: "Couldn't refresh. Showing data from \(lastUpdatedText(status)). \(error)",
                                     tint: .voltaAmber) { model.refreshError = nil }
                            .padding(.bottom, VoltaSpacing.lg)
                    }
                    if let partial = model.partialFailureMessage, model.refreshError == nil {
                        InlineBanner(systemImage: "exclamationmark.triangle",
                                     message: "\(partial) Pull to refresh to try again.",
                                     tint: .voltaAmber)
                            .padding(.bottom, VoltaSpacing.lg)
                    }
                    identityRow(status)
                    if let freshness = status.telemetryFreshness {
                        Text(freshness.label)
                            .font(.caption).foregroundStyle(Color.voltaTextSecondary)
                            .padding(.top, VoltaSpacing.sm)
                    }
                    batteryBlock(status)
                        .padding(.top, VoltaSpacing.xl)
                    HairlineDivider().padding(.top, VoltaSpacing.xl)
                    QuickControlsRow(status: status) { showControls = true }
                    HairlineDivider()
                    metricGrid(status)
                        .padding(.top, VoltaSpacing.xl)
                    ActivityStrip(segments: model.timeline, failed: model.timelineFailed)
                        .padding(.top, VoltaSpacing.xxl + 4)
                    HairlineDivider().padding(.top, VoltaSpacing.xl)
                    // Re-render when today's reporting day ends so its totals drop.
                    TimelineView(.explicit(model.todayDay.map { [$0.interval.end] } ?? [])) { _ in
                        ActivitySummarySection(summaries: model.visibleSummaries(at: .now),
                                               failedRanges: Set(SummaryRange.allCases.filter(model.summaryFailed)))
                    }
                    .padding(.top, VoltaSpacing.xl)
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .redacted(reason: isPlaceholder ? .placeholder : [])
                .disabled(isPlaceholder)
            }
            .padding(.bottom, VoltaSpacing.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .accessibilityIdentifier("scroll.dashboard")
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, new in
            scrollOffset = new
        }
        .refreshable { await load() }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
            EmptyState(systemImage: "antenna.radiowaves.left.and.right.slash",
                       title: "Can't reach your car's data",
                       message: message)
            PillButton("Try again", systemImage: "arrow.clockwise", style: .accent) {
                Task { await load() }
            }
            .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 120)
    }

    /// Reachable server, but this car has never reported a battery reading
    /// (for example a car added to the account that hasn't woken up yet).
    private var noData: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
            EmptyState(systemImage: "car",
                       title: "No data yet",
                       message: "\(model.vehicle?.name ?? "This vehicle") hasn't reported a battery reading yet. It appears here after the car wakes up and its data is recorded.")
                .accessibilityIdentifier("screen.dashboard.noData")
            VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                if selectVehicle != nil {
                    PillButton("Choose another vehicle", systemImage: "car.2.fill", style: .accent) {
                        showVehicle = true
                    }
                    .accessibilityIdentifier("button.chooseVehicle")
                }
                PillButton("Try again", systemImage: "arrow.clockwise", style: selectVehicle == nil ? .accent : .neutral) {
                    Task { await load() }
                }
            }
            .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 120)
    }

    // MARK: Sections

    private func identityRow(_ status: VehicleStatus) -> some View {
        HStack(spacing: VoltaSpacing.lg) {
            Image(systemName: "person.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.voltaTextSecondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.voltaRaised))
            Text(model.vehicle?.name ?? "Vehicle")
                .font(.system(.subheadline, weight: .medium))
                .tracking(2.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: status.state.color, size: 6)
                Text(stateLine(status))
                    .font(.caption)
                    .foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // UI-test readiness marker: only present once real data has loaded.
        .accessibilityIdentifier(model.status != nil ? "screen.dashboard" : "")
    }

    private func stateLine(_ status: VehicleStatus) -> String {
        switch status.state {
        case .asleep, .offline:
            "\(status.state.displayName) · \(lastUpdatedText(status))"
        case .charging:
            if let minutes = status.minutesToFull {
                "Charging · \(VoltaFormat.duration(minutes: Double(minutes))) left"
            } else { "Charging" }
        default:
            status.state.displayName
        }
    }

    private func lastUpdatedText(_ status: VehicleStatus) -> String {
        VoltaFormat.relativeDate(status.updatedAt)
    }

    /// The range shown and a label that says which one it is: TeslaMate often
    /// records only rated range, which must not be called an estimate.
    static func rangeDisplay(_ status: VehicleStatus) -> (label: String, km: Double?) {
        if let est = status.estRangeKm { return ("Est. range", est) }
        if let rated = status.ratedRangeKm { return ("Rated range", rated) }
        return ("Range", nil)
    }

    private func batteryBlock(_ status: VehicleStatus) -> some View {
        let range = Self.rangeDisplay(status)
        return VStack(spacing: VoltaSpacing.xl) {
            HStack(alignment: .bottom) {
                BigNumber("\(status.batteryLevel)", unit: "%", size: 66)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                Spacer()
                VStack(alignment: .trailing, spacing: VoltaSpacing.sm) {
                    Text(range.label).voltaLabelStyle()
                    BigNumber(range.km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                              unit: units.distanceUnit, size: 24, weight: .semibold)
                }
                .padding(.bottom, 10)
            }
            RangeBar(level: status.batteryLevel, limit: status.chargeLimit,
                     charging: status.chargingState == .charging)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricGrid(_ status: VehicleStatus) -> some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            MetricCard(systemImage: "minus.plus.batteryblock", title: "Pack Temp",
                       value: temperatureNumber(status.packTempMaxC), unit: units.temperatureUnit,
                       gauge: GradientGauge(value: status.packTempMaxC.map(Self.tempFraction))) {
                Text(status.packTempMaxC == nil ? "Streams when awake" : status.packTempMinC.map { "Min \(units.formatTemperature($0))" } ?? "No minimum recorded")
                    .font(.caption).foregroundStyle(Color.voltaTextSecondary)
            }
            efficiencyCard
            climateCard(status)
            weatherCard(status)
        }
    }

    private var efficiencyCard: some View {
        let eff = model.summaries[.thirtyDays]?.efficiencyWhPerKm
        let value = eff.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—"
        // 100 Wh/km (great) … 250 Wh/km (heavy).
        let fraction = eff.map { ($0 - 100) / 150 }
        return MetricCard(systemImage: "leaf", title: "30D Eff", value: value, unit: units.efficiencyUnit,
                          gauge: GradientGauge(value: fraction,
                                               colors: [.voltaGreen, .voltaGreen, .voltaAmber, .voltaRed],
                                               knob: .filled(.voltaGreen)),
                          tint: nil)
    }

    private func climateCard(_ status: VehicleStatus) -> some View {
        let on = status.climateOn ?? false
        return MetricCard(systemImage: "fan", title: "Climate",
                          value: temperatureNumber(status.insideTempC), unit: units.temperatureUnit,
                          badge: .init(text: status.climateOn == nil ? "—" : (on ? "On" : "Off"),
                                       color: on ? .voltaGreen : .voltaTextSecondary, inHeader: true),
                          gauge: GradientGauge(value: status.insideTempC.map(Self.tempFraction), knob: .ring,
                                               secondaryValue: status.outsideTempC.map(Self.tempFraction)),
                          tint: on ? .voltaGreen : .voltaTeal) {
            if let outside = status.outsideTempC {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("OUT").font(.caption2.weight(.medium)).tracking(1.2)
                        .foregroundStyle(Color.voltaTextSecondary)
                    Text("\(VoltaFormat.number(units.temperatureValue(celsius: outside), digits: 0))°")
                        .font(.system(.title3, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .fixedSize()
            }
        }
    }

    private func weatherCard(_ status: VehicleStatus) -> some View {
        let hour = Calendar.current.component(.hour, from: .now)
        let night = hour < 6 || hour >= 19
        let t = status.outsideTempC
        let extreme = t.map { $0 <= 0 || $0 >= 35 } ?? false
        let symbol: String = {
            guard let t else { return "cloud" }
            if t <= 0 { return "snowflake" }
            return night ? "moon.stars.fill" : (t >= 24 ? "sun.max.fill" : "cloud.sun.fill")
        }()
        let dayFraction = (Double(hour) + Double(Calendar.current.component(.minute, from: .now)) / 60) / 24
        return MetricCard(systemImage: "cloud.sun", title: "Weather",
                          value: temperatureNumber(t), unit: units.temperatureUnit,
                          headerAccessory: extreme
                            ? AnyView(Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .foregroundStyle(Color.voltaAmber)
                                .accessibilityLabel(t.map { $0 <= 0 ? "Freezing" : "Very hot" } ?? ""))
                            : nil,
                          gauge: GradientGauge(value: dayFraction, colors: GradientGauge.daylight, knob: .ring),
                          tint: .voltaBlue) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 30))
                .foregroundStyle(Color.white.opacity(0.9))
        }
    }

    private func temperatureNumber(_ celsius: Double?) -> String {
        celsius.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—"
    }

    /// Maps -5 °C … 45 °C onto the gauge.
    static func tempFraction(_ celsius: Double) -> Double { (celsius + 5) / 50 }
}

extension Color {
    fileprivate static let voltaTeal = Color(hex: 0x14B8A6)
}

// MARK: - Range bar

/// Thin blue bar with glow; a faint tick marks the charge limit.
struct RangeBar: View {
    var level: Int
    var limit: Int?
    var charging: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x2563EB), .voltaBlue, Color(hex: 0x60A5FA)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * CGFloat(min(max(level, 0), 100)) / 100)
                    .shadow(color: .voltaBlue.opacity(0.7), radius: 6)
                    .phaseAnimator(charging ? [0.6, 1] : [1]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in .easeInOut(duration: 1.2) }
                if let limit, limit < 100 {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 2, height: 10)
                        .offset(x: w * CGFloat(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Battery \(level) percent\(limit.map { ", limit \($0) percent" } ?? "")")
    }
}

// MARK: - Quick controls

/// Row of icon buttons reflecting status; any tap opens the Controls sheet.
struct QuickControlsRow: View {
    var status: VehicleStatus
    var open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            let doors = StateDisplay.doors(status.locked)
            item(doors.symbol,
                 color: doors.tone == .active ? .voltaRed.opacity(0.85) : neutral(doors),
                 label: "Doors: \(doors.text)")
            let climate = StateDisplay.climate(status.climateOn)
            item("fan", color: climate.tone == .active ? .voltaGreen : neutral(climate),
                 label: "Climate: \(climate.text)")
            item("car.side.front.open", color: .voltaTextPrimary.opacity(0.75), label: "Frunk")
            item("car.side.rear.open", color: .voltaTextPrimary.opacity(0.75), label: "Trunk")
            let sentry = StateDisplay.sentry(status.sentryMode)
            item(sentry.symbol,
                 color: sentry.tone == .active ? .voltaRed.opacity(0.85) : neutral(sentry),
                 label: "Sentry: \(sentry.text)")
            item("location.fill", color: .voltaTextPrimary.opacity(0.6), label: "Locate")
            item("ellipsis", color: .voltaTextPrimary.opacity(0.85), label: "All controls")
                .accessibilityIdentifier("button.controls")
        }
        .padding(.vertical, VoltaSpacing.lg + 2)
    }

    private func neutral(_ display: StateDisplay) -> Color {
        display.isKnown ? .voltaTextPrimary.opacity(0.75) : .voltaTextTertiary
    }

    private func item(_ symbol: String, color: Color, label: String) -> some View {
        Button(action: open) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .frame(width: 28, height: 24)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(VoltaPressStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Opens controls")
    }
}

// MARK: - Activity summary

struct ActivitySummarySection: View {
    var summaries: [SummaryRange: ActivitySummary]
    /// Ranges whose latest load failed (stale data, if any, is still shown).
    var failedRanges: Set<SummaryRange> = []
    @Environment(\.units) private var units
    @State private var range: SummaryRange = .today

    var body: some View {
        let summary = summaries[range]
        VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
            HStack {
                Text("Activity").voltaLabelStyle()
                    .font(.system(.footnote, weight: .semibold))
                Spacer()
                SegmentedRangePicker(selection: $range)
            }
            HStack {
                StatColumn(value: summary.map { VoltaFormat.number(units.distanceValue(km: $0.distanceKm), digits: 0) } ?? "—",
                           caption: units.distanceUnit.uppercased())
                StatColumn(value: summary.map { "\($0.chargeCount)" } ?? "—", caption: "CHARGES")
                StatColumn(value: summary?.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—",
                           caption: units.efficiencyUnit)
            }
            if summary == nil, failedRanges.contains(range) {
                Label("Couldn't load \(range.voltaLabel) activity", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Vehicle sheet

/// The selected vehicle's details and, when the account has more than one car,
/// the list to switch between them.
struct VehicleInfoSheet: View {
    var vehicle: Vehicle?
    var status: VehicleStatus?
    var vehicles: [Vehicle] = []
    var selectedID: Int?
    /// nil hides the vehicle list.
    var onSelect: ((Int) -> Void)?
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let onSelect, vehicles.count > 1 {
                    vehicleList(onSelect).padding(.bottom, VoltaSpacing.xxl)
                }
                details
            }
            .padding(VoltaSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationBackground(Color.voltaBackground)
        .preferredColorScheme(.dark)
    }

    private func vehicleList(_ onSelect: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            Text("Vehicles").voltaLabelStyle()
            VStack(spacing: 0) {
                ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { HairlineDivider() }
                    Button {
                        dismiss()
                        choose(item.id)
                    } label: {
                        HStack(spacing: VoltaSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).foregroundStyle(Color.voltaTextPrimary)
                                let detail = Self.detail(item)
                                if !detail.isEmpty {
                                    Text(detail).font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                                }
                            }
                            Spacer()
                            if item.id == selectedID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.voltaGreen)
                            }
                        }
                        .padding(.vertical, VoltaSpacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
                    .accessibilityIdentifier("vehicle.\(item.id)")
                }
            }
        }
    }

    /// Every tap selects, the checked car included: tapping the automatic
    /// choice makes it explicit, so it stays when another car gains data.
    func choose(_ id: Int) { onSelect?(id) }

    /// Model and trim, plus "No data yet" when the server has no reading.
    static func detail(_ vehicle: Vehicle) -> String {
        ([vehicle.model, vehicle.trim] + [vehicle.hasData == false ? "No data yet" : nil])
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vehicle?.name ?? "Vehicle")
                .font(.system(.title, weight: .bold))
                .foregroundStyle(Color.voltaTextPrimary)
            Text([vehicle?.model, vehicle?.trim].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Color.voltaTextSecondary)
                .padding(.top, 4)
            VStack(spacing: 0) {
                row("Color", vehicle?.exteriorColor)
                HairlineDivider()
                row("VIN", vehicle?.vinSuffix.map { "…\($0)" })
                HairlineDivider()
                row("Software", status?.firmware ?? vehicle?.firmware)
                HairlineDivider()
                row("Odometer", status?.odometerKm.map { units.formatDistance($0, fractionDigits: 0) })
            }
            .padding(.top, VoltaSpacing.xl)
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.voltaTextSecondary)
            Spacer()
            Text(value ?? "—").foregroundStyle(Color.voltaTextPrimary)
        }
        .font(.body)
        .padding(.vertical, VoltaSpacing.md + 2)
    }
}

// MARK: - Previews

#Preview("Dashboard") {
    DashboardView()
        .environment(\.dataSource, MockDataSource())
}

#Preview("Dashboard – empty") {
    DashboardView()
        .environment(\.dataSource, MockDataSource(empty: true))
}

#Preview("Dashboard – error") {
    DashboardView()
        .environment(\.dataSource, FailingDataSource())
}

/// Preview helper that fails every call.
struct FailingDataSource: VoltaDataSource {
    var error: VoltaError = .transport("The server at volta.tailnet couldn't be reached.")
    func vehicles() async throws -> [Vehicle] { throw error }
    func status(vehicleID: Int) async throws -> VehicleStatus { throw error }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { throw error }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { throw error }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { throw error }
    func drive(id: Int) async throws -> DriveDetail { throw error }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { throw error }
    func charge(id: Int) async throws -> ChargeDetail { throw error }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { throw error }
    func battery(vehicleID: Int) async throws -> BatteryHealth { throw error }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { throw error }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { throw error }
    func places(vehicleID: Int) async throws -> [Place] { throw error }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws { throw VoltaError.commandsUnavailable }
}
