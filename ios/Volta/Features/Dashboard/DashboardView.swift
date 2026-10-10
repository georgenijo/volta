import SwiftUI
import WidgetKit

/// Dashboard tab: 3D map backdrop fading into an open battery hero, quick
/// controls, metric cards, 48h activity rhythm, and Today/7D/30D summary.
struct DashboardView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.vehicleSurfaces) private var surfaces
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isActiveTab) private var isActiveTab
    /// Owns the vehicle selection; absent in previews.
    @Environment(AppModel.self) private var app: AppModel?

    @State private var model = DashboardModel()
    @State private var scrollOffset: CGFloat = 0
    @State private var showControls = false
    @State private var showVehicle = false
    @State private var showNotifications = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Visible map height below the safe area before content starts.
    private let mapReveal: CGFloat = 280
    /// Total map height (extends under the content top, where it fades out).
    private let mapHeight: CGFloat = 500

    var body: some View {
        ZStack(alignment: .top) {
            Color.voltaBackground.ignoresSafeArea()
            mapLayer
            content
            // MainShell keeps this tab mounted at opacity 0 behind the others.
            // On iOS 27 the hidden header (likely the bell's popover anchor) still
            // swallowed taps at the top of the visible tab, e.g. More's gear, so
            // drop it while hidden. It holds no state of its own.
            if isActiveTab { header }
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
            // Long, eased fade so the map dissolves into the background rather
            // than ending at an edge.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.5),
                                       .init(color: .black.opacity(0.55), location: 0.59),
                                       .init(color: .black.opacity(0.15), location: 0.7),
                                       .init(color: .black.opacity(0.04), location: 0.8),
                                       .init(color: .clear, location: 0.9)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                // Quiets the street labels under the header controls.
                LinearGradient(colors: [.voltaBackground.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
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
        let fade = min(max((scrollOffset - mapReveal * 0.55) / 60, 0), 1)
        return ZStack {
            Image("Wordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 18)
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
        // Map shows through at rest; the shared scrim fades in once content
        // scrolls up under the buttons.
        .voltaTopScrim(opacity: fade, glow: false)
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
                    batteryBlock(status)
                        .padding(.top, 2)
                        .background(alignment: .topTrailing) { heroGlow }
                    QuickControlsRow(status: status) { showControls = true }
                        .padding(.top, DashboardRhythm.section)
                    metricGrid(status)
                        .padding(.top, DashboardRhythm.section)
                    ActivityStrip(segments: model.timeline, failed: model.timelineFailed)
                        .padding(.top, DashboardRhythm.section + 4)
                    // Re-render when today's reporting day ends so its totals drop.
                    TimelineView(.explicit(model.todayDay.map { [$0.interval.end] } ?? [])) { _ in
                        ActivitySummarySection(summaries: model.visibleSummaries(at: .now),
                                               failedRanges: Set(SummaryRange.allCases.filter(model.summaryFailed)))
                    }
                    .padding(.top, DashboardRhythm.section)
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

    /// Faint light behind the hero's open side, as on the Drives tab.
    private var heroGlow: some View {
        RadialGradient(colors: [Color.voltaBlue.opacity(0.16), Color.voltaMint.opacity(0.04), .clear],
                       center: .center, startRadius: 0, endRadius: 210)
            .frame(width: 420, height: 420)
            .offset(x: 150, y: -150)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

    /// Eyebrow: vehicle name on the left, live state on the right.
    private func identityRow(_ status: VehicleStatus) -> some View {
        HStack(alignment: .center, spacing: VoltaSpacing.md) {
            Text(model.vehicle?.name ?? "Vehicle")
                .dashboardCaption(size: 11, color: .voltaTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                LiveStatusDot(color: DashboardRhythm.stateColor(status.state),
                              live: status.state == .driving || status.state == .charging)
                Text(stateLine(status))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
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

    /// Open hero: expanded battery numeral, glowing gauge, then a hairline
    /// stat strip that leads with range.
    private func batteryBlock(_ status: VehicleStatus) -> some View {
        let range = Self.rangeDisplay(status)
        let charging = status.chargingState == .charging
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(status.batteryLevel)")
                    .font(.system(size: 92, weight: .bold)).fontWidth(.expanded).tracking(-2.5)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("%").font(.system(size: 22, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                Spacer(minLength: 0)
            }
            RangeBar(level: status.batteryLevel, limit: status.chargeLimit, charging: charging)
                .padding(.top, 10)
            HStack(spacing: 0) {
                DashboardStat(value: range.km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                              unit: range.km == nil ? nil : units.distanceUnit, caption: range.label, leading: true)
                DashboardRhythm.verticalHairline
                DashboardStat(value: status.chargeLimit.map { "\($0)" } ?? "—",
                              unit: status.chargeLimit == nil ? nil : "%", caption: "Limit")
                DashboardRhythm.verticalHairline
                if charging, let kw = status.chargerPowerKw {
                    DashboardStat(value: VoltaFormat.number(kw, digits: 0), unit: "kW", caption: "Charging")
                } else {
                    DashboardStat(value: status.energyRemainingKwh.map { VoltaFormat.number($0) } ?? "—",
                                  unit: status.energyRemainingKwh == nil ? nil : "kWh", caption: "Remaining")
                }
            }
            .padding(.top, 22)
            if let freshness = status.telemetryFreshness {
                HStack(spacing: 6) {
                    Image(systemName: freshness.connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 10, weight: .semibold))
                    Text(freshness.label)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.voltaTextTertiary)
                .padding(.top, 16)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metricGrid(_ status: VehicleStatus) -> some View {
        let columns = [GridItem(.flexible(), spacing: DashboardRhythm.cardGap),
                       GridItem(.flexible(), spacing: DashboardRhythm.cardGap)]
        return LazyVGrid(columns: columns, spacing: DashboardRhythm.cardGap) {
            packTempCard(status)
            efficiencyCard
            climateCard(status)
            weatherCard(status)
        }
    }

    private func packTempCard(_ status: VehicleStatus) -> some View {
        let warm = (status.packTempMaxC ?? 0) >= 40
        return DashboardMetricCard(
            systemImage: "minus.plus.batteryblock", title: "Pack temp",
            value: temperatureNumber(status.packTempMaxC), unit: units.temperatureUnit,
            detail: status.packTempMaxC == nil ? "Streams when awake" : status.packTempMinC.map { "Min \(units.formatTemperature($0))" } ?? "No minimum recorded",
            gauge: ThinGauge(value: status.packTempMaxC.map(Self.tempFraction),
                             colors: [.voltaBlue, .voltaMint, .voltaMint, .voltaAmber, .voltaRed]),
            trailing: warm ? .init(text: "Warm", color: .voltaAmber) : nil)
    }

    private var efficiencyCard: some View {
        let eff = model.summaries[.thirtyDays]?.efficiencyWhPerKm
        let value = eff.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—"
        // 100 Wh/km (great) … 250 Wh/km (heavy).
        let fraction = eff.map { ($0 - 100) / 150 }
        return DashboardMetricCard(
            systemImage: "leaf", title: "30D Eff", value: value, unit: units.efficiencyUnit,
            detail: eff == nil ? "No drives in 30 days" : "30-day average",
            gauge: ThinGauge(value: fraction, colors: [.voltaMint, .voltaMint, .voltaAmber, .voltaRed]))
    }

    private func climateCard(_ status: VehicleStatus) -> some View {
        let on = status.climateOn ?? false
        return DashboardMetricCard(
            systemImage: "fan", title: "Climate",
            value: temperatureNumber(status.insideTempC), unit: units.temperatureUnit,
            detail: status.outsideTempC.map { "Out \(VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0))°" } ?? "Cabin",
            gauge: ThinGauge(value: status.insideTempC.map(Self.tempFraction),
                             colors: [.voltaBlue, .voltaMint, .voltaMint, .voltaAmber, .voltaRed],
                             secondaryValue: status.outsideTempC.map(Self.tempFraction)),
            trailing: .init(text: status.climateOn == nil ? "—" : (on ? "On" : "Off"),
                            color: on ? .voltaMint : .voltaTextTertiary, live: on))
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
        let detail = t.map { extreme ? ($0 <= 0 ? "Freezing" : "Very hot") : (night ? "Night" : "Daytime") } ?? "No reading"
        return DashboardMetricCard(
            systemImage: "cloud.sun", title: "Weather",
            value: temperatureNumber(t), unit: units.temperatureUnit,
            detail: detail,
            gauge: ThinGauge(value: dayFraction, colors: [Color(hex: 0x334155), .voltaAmber, .voltaAmber, Color(hex: 0xA78BFA), Color(hex: 0x334155)]),
            trailing: extreme ? .init(text: "Alert", color: .voltaAmber, systemImage: "exclamationmark.triangle.fill") : nil) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.75))
                .accessibilityHidden(true)
        }
    }

    private func temperatureNumber(_ celsius: Double?) -> String {
        celsius.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—"
    }

    /// Maps -5 °C … 45 °C onto the gauge.
    static func tempFraction(_ celsius: Double) -> Double { (celsius + 5) / 50 }
}

// MARK: - Rhythm

/// Dashboard-local spacing and styling, aligned with the Drives tab.
enum DashboardRhythm {
    /// Between major sections.
    static let section: CGFloat = 30
    /// Between cards in a group.
    static let cardGap: CGFloat = 12
    static let energyGradient = [Color.voltaMint, Color.voltaBlue]

    static var verticalHairline: some View { Rectangle().fill(Color.voltaHairline).frame(width: 1, height: 28) }

    /// State dot color: mint for healthy/positive, blue for motion.
    static func stateColor(_ state: VehicleState) -> Color {
        switch state {
        case .online, .charging: .voltaMint
        case .driving, .updating: .voltaBlue
        case .asleep: .voltaTextSecondary
        case .offline: .voltaTextTertiary
        }
    }
}

extension View {
    /// Small-caps caption: uppercase, semibold, tracked, tertiary.
    func dashboardCaption(size: CGFloat = 10, color: Color = .voltaTextTertiary) -> some View {
        font(.system(size: size, weight: .semibold)).tracking(size >= 11 ? 1.5 : 1.1)
            .textCase(.uppercase).foregroundStyle(color)
    }
}

/// Value over caption, for hairline-separated stat strips.
struct DashboardStat: View {
    var value: String
    var unit: String? = nil
    var caption: String
    var leading = false
    var size: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: size, weight: size >= 22 ? .bold : .semibold))
                    .fontWidth(size >= 22 ? .expanded : .standard).tracking(size >= 22 ? -0.6 : 0)
                    .monospacedDigit().foregroundStyle(.white)
                if let unit {
                    Text(unit).font(.system(size: size * 0.7, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).dashboardCaption().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leading ? 0 : 14)
        .accessibilityElement(children: .combine)
    }
}

/// Status dot; live states breathe a soft halo.
struct LiveStatusDot: View {
    var color: Color
    var live: Bool
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        ZStack {
            if live {
                Circle().fill(color.opacity(0.45))
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(width: size * 2.6, height: size * 2.6)
        .padding(-size * 0.8)
        .onAppear {
            guard live else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Battery gauge

/// Thin mint→blue gauge drawn as light: glow underlay, bright tip, and a tick
/// at the charge limit. Low charge shifts the light to amber.
struct RangeBar: View {
    var level: Int
    var limit: Int?
    var charging: Bool

    private var fraction: CGFloat { CGFloat(min(max(level, 0), 100)) / 100 }
    private var colors: [Color] {
        level <= 20 ? [Color.voltaRed, .voltaAmber] : DashboardRhythm.energyGradient
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = max(w * fraction, 6)
            let gradient = LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 6)
                // Glow underlay.
                Capsule().fill(gradient).frame(width: fill, height: 6)
                    .blur(radius: 8).opacity(0.7)
                Capsule().fill(gradient).frame(width: fill, height: 6)
                    .phaseAnimator(charging ? [0.55, 1] : [1]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in .easeInOut(duration: 1.2) }
                // Bright tip.
                Circle().fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: (colors.last ?? .voltaBlue).opacity(0.9), radius: 6)
                    .offset(x: fill - 5)
                if let limit, limit < 100 {
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 2, height: 16)
                        .offset(x: w * CGFloat(limit) / 100 - 1)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
        .accessibilityLabel("Battery \(level) percent\(limit.map { ", limit \($0) percent" } ?? "")")
    }
}

// MARK: - Metric card

/// Thin gauge line: faint track, gradient fill to `value` (colors are placed
/// on the full width, so position reads as temperature), glow and a lit tip.
struct ThinGauge {
    var value: Double?
    var colors: [Color]
    var secondaryValue: Double? = nil
}

extension ThinGauge: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let gradient = LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 3)
                if let value {
                    let x = max(w * clamp(value), 3)
                    ZStack(alignment: .leading) {
                        gradient.frame(height: 3).blur(radius: 5).opacity(0.6)
                        gradient.frame(height: 3).clipShape(Capsule())
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                    if let secondaryValue {
                        Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .offset(x: w * clamp(secondaryValue) - 4)
                    }
                    Circle().fill(Color.white).frame(width: 7, height: 7)
                        .shadow(color: .white.opacity(0.6), radius: 4)
                        .offset(x: x - 3.5)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
}

/// Dashboard tile on the lit surface: caption, expanded numeral with a
/// small-caps unit, one detail line, and a thin gauge.
struct DashboardMetricCard<Accessory: View>: View {
    struct Trailing {
        var text: String
        var color: Color
        var systemImage: String? = nil
        var live = false
    }

    var systemImage: String
    var title: String
    var value: String
    var unit: String?
    var detail: String
    var gauge: ThinGauge
    var trailing: Trailing?
    var accessory: Accessory

    init(systemImage: String, title: String, value: String, unit: String?, detail: String,
         gauge: ThinGauge, trailing: Trailing? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.gauge = gauge
        self.trailing = trailing
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let trailing {
                    HStack(spacing: 4) {
                        if let image = trailing.systemImage {
                            Image(systemName: image).font(.system(size: 9, weight: .bold))
                        } else if trailing.live {
                            Circle().fill(trailing.color).frame(width: 5, height: 5)
                                .shadow(color: trailing.color, radius: 3)
                        }
                        Text(trailing.text)
                    }
                    .foregroundStyle(trailing.color)
                }
            }
            .dashboardCaption()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 32, weight: .bold)).fontWidth(.expanded).tracking(-1)
                    .monospacedDigit().foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let unit, value != "—" {
                    Text(unit.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(Color.voltaTextSecondary)
                }
                Spacer(minLength: 2)
                accessory
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.top, 18)
            Text(detail)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color.voltaTextSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.top, 2)
            gauge.padding(.top, 14)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .driveSurface()
        .accessibilityElement(children: .combine)
    }
}

extension DashboardMetricCard where Accessory == EmptyView {
    init(systemImage: String, title: String, value: String, unit: String?, detail: String,
         gauge: ThinGauge, trailing: Trailing? = nil) {
        self.init(systemImage: systemImage, title: title, value: value, unit: unit, detail: detail,
                  gauge: gauge, trailing: trailing) { EmptyView() }
    }
}

// MARK: - Quick controls

/// One hairline capsule of icon buttons reflecting status; any tap opens the
/// Controls sheet.
struct QuickControlsRow: View {
    var status: VehicleStatus
    var open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            let doors = StateDisplay.doors(status.locked)
            item(doors.symbol,
                 color: doors.tone == .active ? .voltaRed : neutral(doors),
                 active: doors.tone == .active,
                 label: "Doors: \(doors.text)")
            let climate = StateDisplay.climate(status.climateOn)
            item("fan", color: climate.tone == .active ? .voltaMint : neutral(climate),
                 active: climate.tone == .active,
                 label: "Climate: \(climate.text)")
            item("car.side.front.open", color: .white.opacity(0.7), label: "Frunk")
            item("car.side.rear.open", color: .white.opacity(0.7), label: "Trunk")
            let sentry = StateDisplay.sentry(status.sentryMode)
            item(sentry.symbol,
                 color: sentry.tone == .active ? .voltaRed : neutral(sentry),
                 active: sentry.tone == .active,
                 label: "Sentry: \(sentry.text)")
            item("location.fill", color: .white.opacity(0.55), label: "Locate")
            item("ellipsis", color: .white.opacity(0.8), label: "All controls")
                .accessibilityIdentifier("button.controls")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.white.opacity(0.035), in: .capsule)
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    private func neutral(_ display: StateDisplay) -> Color {
        display.isKnown ? .white.opacity(0.7) : .voltaTextTertiary
    }

    private func item(_ symbol: String, color: Color, active: Bool = false, label: String) -> some View {
        Button(action: open) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(color)
                .shadow(color: active ? color.opacity(0.55) : .clear, radius: 6)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Activity").dashboardCaption(size: 11)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SegmentedRangePicker(selection: $range)
            }
            HStack(spacing: 0) {
                DashboardStat(value: summary.map { VoltaFormat.number(units.distanceValue(km: $0.distanceKm), digits: 0) } ?? "—",
                              caption: units.distanceUnit, leading: true, size: 24)
                DashboardRhythm.verticalHairline
                DashboardStat(value: summary.map { "\($0.chargeCount)" } ?? "—", caption: "Charges", size: 24)
                DashboardRhythm.verticalHairline
                DashboardStat(value: summary?.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—",
                              caption: units.efficiencyUnit, size: 24)
            }
            if summary == nil, failedRanges.contains(range) {
                Label("Couldn't load \(range.voltaLabel) activity", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.voltaTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
        .driveSurface()
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
