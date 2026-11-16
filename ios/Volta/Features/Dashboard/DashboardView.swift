import SwiftUI
import WidgetKit

/// Dashboard tab. Three layouts from one set of sections:
/// - compact width (iPhone Duo's outer display, ordinary iPhones): one
///   column under a short map;
/// - regular width, wider than tall (the inner display open flat): a "stage"
///   pane (map, battery, dock) and a scrolling pane (Now card, metrics,
///   activity) that meet on the hinge;
/// - regular width, taller than wide (the inner display upright): map and
///   battery above the hinge, the rest below it.
///
/// The Dashboard owns the vehicle's `ControlsModel`, so the dock, the Now
/// card and Controls share state and one command path, and Controls survives
/// switching between a sheet and a pushed screen when the device folds.
struct DashboardView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.vehicleSurfaces) private var surfaces
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vehicleCommandCoordinator) private var sharedCoordinator
    @Environment(\.dynamicTypeSize) private var environmentTypeSize
    /// The text size this view lays out for (the DEBUG override included,
    /// which applies below this view).
    private var typeSize: DynamicTypeSize { DebugTypeSizeOverride.size ?? environmentTypeSize }
    /// Owns the vehicle selection; absent in previews.
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.barsOnSide) private var barsOnSide

    @State private var model = DashboardModel()
    @State private var controls = ControlsModel(status: nil)
    @State private var localCoordinator = VehicleCommandCoordinator()
    @State private var scrollOffset: CGFloat = 0
    /// Controls are open (wherever they are shown).
    @State private var showControls = false
    /// Where Controls are on screen now. It trails `showControls` and
    /// `controlsPushed`: a sheet must finish dismissing before the same
    /// screen can be pushed, or the push is dropped.
    @State private var controlsHost: ControlsView.Presentation?
    /// Bumped when the Controls sheet finishes dismissing. `onDismiss` runs a
    /// closure from an earlier body, whose size class can be stale, so the
    /// sync runs from `onChange` with current values instead.
    @State private var controlsSheetDismissals = 0
    /// The Dashboard's navigation stack; Controls is its only destination.
    /// A path, because `navigationDestination(isPresented:)` ignores a push
    /// requested just after a sheet dismisses.
    @State private var path: [Route] = []

    enum Route: Hashable { case controls }
    @State private var showVehicle = false
    @State private var showNotifications = false
    @State private var showLiveCharge = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Window is wider than it is tall (iPhone Duo's inner display opened flat).
    @State private var isLandscape = false
    /// Top safe area, for sizing the compact map under the status bar.
    @State private var safeTop: CGFloat = 0
    @State private var confirmation: CommandConfirmation?
    @State private var powerCurve: [ChargeCurvePoint] = []
    /// The command activity the Dashboard itself started, shown in its banner.
    @State private var dashboardActivityID: UUID?
    @State private var awaitingActivity = false

    enum Layout { case stage, upright, column }

    private var layout: Layout {
        guard horizontalSizeClass == .regular else { return .column }
        switch model.phase {
        case .failed, .noData: return .column
        case .loading, .loaded: return isLandscape ? .stage : .upright
        }
    }

    /// Controls is a pushed two-pane screen in a regular-width window wider
    /// than tall, and a sheet otherwise.
    private var controlsPushed: Bool { horizontalSizeClass == .regular && isLandscape }

    /// Visible map height below the safe area in the single column.
    private let mapReveal: CGFloat = 200

    private var coordinator: VehicleCommandCoordinator { sharedCoordinator ?? localCoordinator }
    private var context: VehicleCommandContext {
        VehicleCommandContext(model: controls, coordinator: coordinator, dataSource: dataSource,
                              vehicleID: vehicleID, surfaces: surfaces)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch layout {
                case .stage: stage
                case .upright: upright
                case .column: column
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: Route.self) { _ in
                ControlsView(model: controls, vehicleName: model.vehicle?.name, presentation: .pushed)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .onChange(of: showControls) { syncControlsHost() }
        .onChange(of: controlsPushed) { syncControlsHost() }
        .onChange(of: controlsSheetDismissals) { syncControlsHost() }
        .onChange(of: path) {
            // Back from pushed Controls closes them.
            if path.isEmpty, controlsHost == .pushed { controlsHost = nil; showControls = false }
        }
        .preferredColorScheme(.dark)
        .task(id: vehicleID) {
            await initialLoad()
            await coordinator.refreshCapabilities(dataSource: dataSource, vehicleID: vehicleID)
            #if DEBUG
            // Screenshot aid: `-dashboardScrollY 420` starts the dashboard scrolled;
            let y = UserDefaults.standard.double(forKey: "dashboardScrollY")
            if y > 0 { scrollPosition.scrollTo(y: y) }
            // `-dashboardOpenControls YES` opens Controls on launch.
            if UserDefaults.standard.bool(forKey: "dashboardOpenControls") { showControls = true }
            // `-dashboardOpenLiveCharge YES` opens the live charging sheet on launch.
            if UserDefaults.standard.bool(forKey: "dashboardOpenLiveCharge"), model.status?.isCharging == true { showLiveCharge = true }
            #endif
        }
        .task(id: CurveKey(chargeID: model.status?.isCharging == true ? model.status?.activeChargeId : nil,
                           loadedAt: model.lastLoadedAt)) {
            await loadPowerCurve()
        }
        .onChange(of: model.status) { _, status in
            if let status { controls.observe(status, dataSource: dataSource, vehicleID: vehicleID) }
        }
        .onChange(of: coordinator.activity(dataSource: dataSource, vehicleID: vehicleID)?.id) { _, id in
            if awaitingActivity, let id { dashboardActivityID = id; awaitingActivity = false }
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
        .sheet(isPresented: sheetControls, onDismiss: { controlsSheetDismissals += 1 }) {
            ControlsView(model: controls, vehicleName: model.vehicle?.name, presentation: .sheet)
                .modifier(DebugTypeSizeOverride())
        }
        .sheet(isPresented: $showLiveCharge, onDismiss: { Task { await load() } }) {
            if let status = model.status {
                // Not rebuilt on text styles: keeps the app's cap.
                LiveChargingSheet(initialStatus: status)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
        .sheet(isPresented: $showVehicle) {
            VehicleInfoSheet(vehicle: model.vehicle, status: model.status, vehicles: model.vehicles,
                             selectedID: vehicleID, onSelect: selectVehicle)
                .presentationDetents(selectVehicle == nil ? [.medium] : [.medium, .large])
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .alert(item: $confirmation) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  primaryButton: .cancel(), secondaryButton: .destructive(Text(item.button)) { send(item.command) })
        }
        .modifier(DebugTypeSizeOverride())
    }

    /// Controls open as a pushed screen; folding to a compact window moves
    /// them to the sheet (and back) without closing them. Only the user
    /// closing the screen where it is now (Back, Close, a swipe) clears
    /// `showControls`; a move between hosts does not.
    private var sheetControls: Binding<Bool> {
        Binding(get: { controlsHost == .sheet },
                set: { if !$0, controlsHost == .sheet { controlsHost = nil; showControls = false } })
    }

    private func syncControlsHost() {
        let wanted: ControlsView.Presentation? = showControls ? (controlsPushed ? .pushed : .sheet) : nil
        guard controlsHost != wanted else { return }
        if controlsHost == .sheet, wanted == .pushed {
            // Dismiss first; the sheet's onDismiss calls back here to push.
            controlsHost = nil
        } else {
            controlsHost = wanted
        }
        let wantedPath: [Route] = controlsHost == .pushed ? [.controls] : []
        if path != wantedPath { path = wantedPath }
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

    /// AppModel already fetched this account's vehicles before MainShell could
    /// appear. Seed a new dashboard with that list; every later refresh goes
    /// through `load()` and asks the server for a fresh list.
    private func initialLoad() async {
        await model.load(dataSource: dataSource, vehicleID: vehicleID,
                         initialVehicles: app?.takeInitialDashboardVehicles(vehicleID: vehicleID), surfaces: surfaces)
    }

    private struct CurveKey: Equatable {
        var chargeID: Int?
        var loadedAt: Date?
    }

    /// The live session's power, for the Now card's sparkline: the same
    /// session detail and curve the live charging sheet draws.
    private func loadPowerCurve() async {
        guard let status = model.status, status.isCharging, let id = status.activeChargeId else {
            powerCurve = []
            return
        }
        guard let detail = try? await dataSource.charge(id: id), !Task.isCancelled else { return }
        let start = min(status.chargeStartedAt ?? detail.summary.start, detail.summary.start)
        let curve = ChargeCurve.curve(telemetry: detail.telemetry, samples: detail.samples, field: "Power",
                                      start: start, end: detail.summary.end ?? .now,
                                      telemetryValue: { $0.powerKw }, sampleValue: { $0.powerKw })
        powerCurve = ChargeCurve.reduced(curve.points, maxPoints: 120)
    }

    // MARK: Commands

    /// Sends a command from the dock or the Now card through the Controls
    /// path: asks first where Controls asks, and opens Controls (which says
    /// why) when the server cannot run it.
    private func perform(_ command: VehicleCommand) {
        guard context.supports(command) else {
            showControls = true
            return
        }
        guard context.canStart(command) else { return }
        if let required = CommandConfirmation.required(for: command) {
            confirmation = required
        } else {
            send(command)
        }
    }

    private func send(_ command: VehicleCommand) {
        awaitingActivity = true
        context.send(command)
    }

    private func tap(_ tile: DockTile) {
        switch tile.tap {
        case .send(let command): perform(command)
        case .openControls: showControls = true
        }
    }

    /// The Dashboard shows command feedback for what it sent, and for any
    /// send still in flight or unresolved.
    /// The Dashboard's own sends, and anything still unresolved. Hidden while
    /// Controls is open, which shows the same banner.
    @ViewBuilder private var activityBanner: some View {
        if controlsHost == nil,
           let activity = coordinator.activity(dataSource: dataSource, vehicleID: vehicleID),
           activity.id == dashboardActivityID || activity.phase == .pending || activity.phase == .unknown {
            VehicleCommandActivityBanner(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID) {
                Task { await context.refresh() }
            }
        }
    }

    // MARK: Layouts

    private var displayStatus: VehicleStatus { controls.effective(model.status ?? .skeleton) }
    private var isPlaceholder: Bool { model.status == nil }

    /// Open flat: the stage on one side of the hinge, the details on the other.
    private var stage: some View {
        VoltaPanes {
            stagePane
        } secondary: {
            ScrollView {
                VStack(alignment: .leading, spacing: VoltaSpacing.xl - 4) {
                    banners
                    nowCard(.standard)
                    metricTiles(displayStatus)
                    details
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, VoltaSpacing.sm)
                .padding(.bottom, VoltaSpacing.tabBarClearance)
                .redacted(reason: isPlaceholder ? .placeholder : [])
                .disabled(isPlaceholder)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.dashboard")
            .refreshable { await load() }
            .overlay(alignment: .bottom) { activityBanner }
        }
        .background(Color.voltaBackground.ignoresSafeArea())
    }

    /// Map, identity, battery and the dock; scrolls only at accessibility sizes.
    @ViewBuilder private var stagePane: some View {
        let status = displayStatus
        if typeSize.isAccessibilitySize {
            ScrollView {
                VStack(spacing: 0) {
                    // Tall enough that the pill clears the wordmark.
                    stageMap(status).frame(height: 300)
                    stageControls(status, dock: true)
                }
            }
            .scrollIndicators(.hidden)
        } else {
            VStack(spacing: 0) {
                // The map runs on behind the battery and fades out there, so
                // the car sits lower and the pill clears the wordmark.
                stageMap(status, runsUnder: 150).frame(maxHeight: .infinity)
                stageControls(status, dock: true)
            }
        }
    }

    private func stageControls(_ status: VehicleStatus, dock showsDock: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            identityRow(status)
            hero(status).padding(.top, VoltaSpacing.xs)
            if showsDock {
                dock.padding(.top, VoltaSpacing.xl - 4)
            }
        }
        .padding(.horizontal, VoltaSpacing.screen)
        .padding(.bottom, VoltaSpacing.lg)
        // The map gives way; the battery and dock keep their size.
        .fixedSize(horizontal: false, vertical: true)
        .redacted(reason: isPlaceholder ? .placeholder : [])
        .disabled(isPlaceholder)
    }

    /// The map as a pane's backdrop: wordmark over it while the bars are on
    /// the side, pill and marker centered, a fade into the background.
    private func stageMap(_ status: VehicleStatus, runsUnder: CGFloat = 0) -> some View {
        DashboardMap(location: status.location,
                     sentry: status.sentryMode ?? false,
                     state: model.status?.state,
                     charging: status.isCharging,
                     chargerPowerKw: status.chargerPowerKw)
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .voltaBackground.opacity(0.85), location: 0.45),
                                       .init(color: .voltaBackground, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90 + runsUnder * 1.3)
                    .allowsHitTesting(false)
            }
            .padding(.bottom, -runsUnder)
            .ignoresSafeArea(edges: [.top, .leading])
            .contentShape(.rect)
            .onTapGesture { if status.isCharging { showLiveCharge = true } }
            .accessibilityAddTraits(status.isCharging ? .isButton : [])
            .accessibilityIdentifier("button.liveCharge.map")
            .redacted(reason: isPlaceholder ? .placeholder : [])
            .overlay(alignment: .top) {
                if barsOnSide { wordmark(height: 26).padding(.top, VoltaSpacing.lg) }
            }
    }

    /// Upright: map and battery above the hinge; Now card, dock and the rest below.
    private var upright: some View {
        let status = displayStatus
        return VoltaPanes(axis: .vertical) {
            VStack(spacing: 0) {
                stageMap(status, runsUnder: 120).frame(maxHeight: .infinity)
                stageControls(status, dock: false)
            }
        } secondary: {
            ScrollView {
                VStack(alignment: .leading, spacing: VoltaSpacing.lg) {
                    banners
                    nowCard(.wide)
                    dock
                    metricTiles(status)
                    details
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, VoltaSpacing.lg)
                .padding(.bottom, VoltaSpacing.tabBarClearance)
                .redacted(reason: isPlaceholder ? .placeholder : [])
                .disabled(isPlaceholder)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.dashboard")
            .refreshable { await load() }
            .overlay(alignment: .bottom) { activityBanner }
        }
        .background(Color.voltaBackground.ignoresSafeArea())
    }

    /// Compact width: one column under a short map.
    @ViewBuilder private var column: some View {
        ZStack(alignment: .top) {
            Color.voltaBackground.ignoresSafeArea()
            mapLayer
            columnContent
            topScrim
            if barsOnSide {
                wordmark(height: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VoltaSpacing.screen)
                    .padding(.top, VoltaSpacing.sm)
            }
        }
        .overlay(alignment: .bottom) { activityBanner }
    }

    private var mapLayer: some View {
        let progress = min(max(scrollOffset / mapReveal, 0), 1)
        let status = displayStatus
        // The pill and marker are centered on the map, so its height puts
        // them in the visible part above the content.
        let height = (safeTop + mapReveal) * 1.42
        return DashboardMap(location: status.location,
                            sentry: status.sentryMode ?? false,
                            state: model.status?.state,
                            charging: status.isCharging,
                            chargerPowerKw: status.chargerPowerKw)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .voltaBackground.opacity(0.85), .voltaBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height - safeTop - mapReveal + 60)
            }
            .overlay(Color.voltaBackground.opacity(progress * 0.85))
            .offset(y: -max(scrollOffset, 0) * 0.45 + max(-scrollOffset, 0) * 0.5)
            .scaleEffect(1 + max(-scrollOffset, 0) / 900, anchor: .top)
            // Full width: on iPhone Duo the backdrop continues under the side bar.
            .ignoresSafeArea(edges: [.top, .horizontal])
            .allowsHitTesting(false)
            .redacted(reason: model.status == nil ? .placeholder : [])
    }

    @ViewBuilder
    private var columnContent: some View {
        switch model.phase {
        case .failed(let message):
            failure(message)
        case .noData:
            noData
        case .loading, .loaded:
            columnScroll
        }
    }

    private var columnScroll: some View {
        let status = displayStatus
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The map can't take touches; while charging it opens the live session.
                Color.clear.frame(height: mapReveal)
                    .contentShape(.rect)
                    .onTapGesture { if status.isCharging { showLiveCharge = true } }
                    .accessibilityHidden(!status.isCharging)
                    .accessibilityLabel("Live charging session")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("button.liveCharge.map")
                VStack(alignment: .leading, spacing: 0) {
                    banners
                    identityRow(status)
                    hero(status).padding(.top, VoltaSpacing.xs)
                    nowCard(.compact).padding(.top, VoltaSpacing.xl)
                    dock.padding(.top, VoltaSpacing.md)
                    metricTiles(status).padding(.top, VoltaSpacing.md)
                    details.padding(.top, VoltaSpacing.xl + 4)
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .voltaReadableWidth(720)
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

    /// Darkens the top once the map has scrolled away, so the bar buttons and
    /// status bar stay legible over the cards.
    private var topScrim: some View {
        let fade = min(max((scrollOffset - mapReveal * 0.6) / 80, 0), 1)
        return LinearGradient(stops: [.init(color: .voltaBackground, location: 0),
                                      .init(color: .voltaBackground.opacity(0.95), location: 0.6),
                                      .init(color: .clear, location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: 170)
            .ignoresSafeArea(edges: [.top, .horizontal])
            .opacity(fade)
            .allowsHitTesting(false)
    }

    // MARK: Toolbar

    /// System toolbar items, so iPhone Duo can move them to the side bar with
    /// the tabs. Each has a title and a symbol for the overflow menu.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // A title keeps a horizontal bar alive, so with side bars the wordmark
        // is drawn over the map instead.
        if !barsOnSide {
            ToolbarItem(placement: .principal) { wordmark(height: 20) }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { showVehicle = true } label: {
                Label(selectVehicle == nil ? "Vehicle" : "Vehicle and switch vehicles", systemImage: "car.fill")
            }
            .tint(Color.voltaTextPrimary)
            .accessibilityIdentifier("button.vehicle")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNotifications = true } label: {
                Label("Notifications", systemImage: "bell.fill")
            }
            .tint(Color.voltaTextPrimary)
            .popover(isPresented: $showNotifications) {
                Text("No notifications")
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func wordmark(height: CGFloat) -> some View {
        Image("Wordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(Color.voltaTextPrimary.opacity(0.92))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .accessibilityLabel("Volta")
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Sections

    @ViewBuilder
    private var banners: some View {
        let status = model.status ?? .skeleton
        if let error = model.refreshError {
            InlineBanner(systemImage: "wifi.exclamationmark",
                         message: "Couldn't refresh. Showing data from \(VoltaFormat.relativeDate(status.updatedAt)). \(error)",
                         tint: .voltaAmber) { model.refreshError = nil }
                .padding(.bottom, VoltaSpacing.lg)
        }
        if let partial = model.partialFailureMessage, model.refreshError == nil {
            InlineBanner(systemImage: "exclamationmark.triangle",
                         message: "\(partial) Pull to refresh to try again.",
                         tint: .voltaAmber)
                .padding(.bottom, VoltaSpacing.lg)
        }
    }

    private func nowCard(_ style: NowCard.Style) -> some View {
        NowCard(status: displayStatus, style: style, context: context, powerCurve: powerCurve,
                parkedSince: NowCardContent.parkedSince(model.timeline),
                openLiveCharge: { if model.status?.isCharging == true { showLiveCharge = true } },
                perform: perform, openControls: { showControls = true })
    }

    private var dock: some View {
        DashboardDock(
            tiles: DockTile.tiles(locked: controls.status == nil ? model.status?.locked : controls.locked,
                                  climateOn: controls.status == nil ? model.status?.climateOn : controls.climateOn,
                                  sentry: controls.status == nil ? model.status?.sentryMode : controls.sentry,
                                  supports: context.supports),
            sending: { tile in
                if case .send(let command) = tile.tap { return context.isSending(command) }
                return false
            },
            blocked: { tile in
                if case .send(let command) = tile.tap { return !context.canStart(command) }
                return false
            },
            tap: tap)
    }

    /// Activity strip, then Today / 7D / 30D.
    @ViewBuilder
    private var details: some View {
        ActivityStrip(segments: model.timeline, failed: model.timelineFailed,
                      loading: model.loadingSections.contains(.timeline))
            .padding(.top, VoltaSpacing.sm)
        HairlineDivider().padding(.top, VoltaSpacing.xl)
        // Re-render when today's reporting day ends so its totals drop.
        TimelineView(.explicit(model.todayDay.map { [$0.interval.end] } ?? [])) { _ in
            ActivitySummarySection(summaries: model.visibleSummaries(at: .now),
                                   failedRanges: Set(SummaryRange.allCases.filter(model.summaryFailed)),
                                   loadingRanges: Set(SummaryRange.allCases.filter { model.loadingSections.contains(.summary($0)) }))
        }
        .padding(.top, VoltaSpacing.lg)
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

    /// "FRIDAY ⌄" (opens the vehicle sheet) and the data's freshness.
    private func identityRow(_ status: VehicleStatus) -> some View {
        HStack(spacing: VoltaSpacing.md) {
            Button { showVehicle = true } label: {
                HStack(spacing: VoltaSpacing.sm) {
                    Text(model.vehicle?.name ?? "Vehicle")
                        .font(.system(.subheadline, weight: .semibold))
                        .tracking(2.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.voltaTextPrimary.opacity(0.92))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.voltaTextSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.vehicle?.name ?? "Vehicle"). Vehicle details\(selectVehicle == nil ? "" : " and switching")")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: VoltaSpacing.sm)
            let freshness = Self.freshness(status)
            HStack(spacing: 6) {
                if freshness.isLive { StatusDot(color: .voltaTextPrimary, size: 6) }
                Text(freshness.text)
                    .font(.footnote)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
        // UI-test readiness marker: only present once real data has loaded.
        .accessibilityIdentifier(model.status != nil ? "screen.dashboard" : "")
    }

    /// "Live" while telemetry streams; otherwise how old the data is, in the
    /// wording the app already uses.
    static func freshness(_ status: VehicleStatus, now: Date = .now) -> (text: String, isLive: Bool) {
        switch status.state {
        case .asleep, .offline:
            return ("\(status.state.displayName) · \(VoltaFormat.relativeDate(status.updatedAt, now: now))", false)
        default:
            if let freshness = status.telemetryFreshness {
                return freshness.connected ? ("Live", true) : (freshness.label, false)
            }
            return ("Updated \(VoltaFormat.relativeDate(status.updatedAt, now: now))", false)
        }
    }

    /// The range shown and a label that says which one it is: TeslaMate often
    /// records only rated range, which must not be called an estimate.
    static func rangeDisplay(_ status: VehicleStatus) -> (label: String, km: Double?) {
        if let est = status.estRangeKm { return ("Est. range", est) }
        if let rated = status.ratedRangeKm { return ("Rated range", rated) }
        return ("Range", nil)
    }

    /// Battery (green only while charging), range, and the range bar.
    private func hero(_ status: VehicleStatus) -> some View {
        let range = Self.rangeDisplay(status)
        return VStack(spacing: VoltaSpacing.md + 2) {
            HStack(alignment: .bottom) {
                BigNumber("\(status.batteryLevel)", unit: "%", size: 66,
                          color: status.isCharging ? .voltaGreen : .voltaTextPrimary)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                Spacer()
                VStack(alignment: .trailing, spacing: VoltaSpacing.xs) {
                    Text(range.label).voltaLabelStyle()
                    BigNumber(range.km.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—",
                              unit: units.distanceUnit, size: 26, weight: .semibold)
                }
                .padding(.bottom, 10)
            }
            .accessibilityElement(children: .combine)
            RangeBar(level: status.batteryLevel, limit: controls.displayedChargeLimit ?? status.chargeLimit,
                     charging: status.isCharging)
        }
    }

    /// Pack, Cabin and Outside: value, unit, and a caption on its own line.
    private func metricTiles(_ status: VehicleStatus) -> some View {
        let pack = MetricTile(title: "Pack", value: temperatureNumber(status.packTempMaxC), unit: units.temperatureUnit,
                              caption: status.packTempMaxC == nil ? "Streams when awake"
                                : status.packTempMinC.map { "Min \(units.formatTemperature($0))" } ?? "Maximum cell")
        let cabin = MetricTile(title: "Cabin", value: temperatureNumber(status.insideTempC), unit: units.temperatureUnit,
                               caption: "Climate \(StateDisplay.climate(status.climateOn).text.lowercased())")
        let outside = MetricTile(title: "Outside", value: temperatureNumber(status.outsideTempC), unit: units.temperatureUnit,
                                 caption: "At the car")
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: VoltaSpacing.sm) { pack; cabin; outside }
            } else {
                HStack(spacing: VoltaSpacing.sm + 2) { pack; cabin; outside }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func temperatureNumber(_ celsius: Double?) -> String {
        celsius.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—"
    }

    /// "No drives" only when the 30-day summary loaded and counted none; a
    /// missing or failed summary, or drives without recorded energy, is unavailable.
    static func efficiencyDetail(_ summary: ActivitySummary?, loading: Bool = false) -> String {
        guard let summary else { return loading ? "Loading 30-day average…" : "Unavailable" }
        if summary.efficiencyWhPerKm != nil { return "30-day average" }
        return summary.driveCount == 0 ? "No drives in 30 days" : "Unavailable"
    }

    /// Maps -5 °C … 45 °C onto a gauge.
    static func tempFraction(_ celsius: Double) -> Double { (celsius + 5) / 50 }
}

// MARK: - Metric tile

/// "PACK / 100 °F / Min 88°F": value 32 pt (the widest that fits "100" in a
/// third of a pane), unit 17 pt, caption 13 pt, all scaled with Dynamic Type.
struct MetricTile: View {
    var title: String
    var value: String
    var unit: String
    var caption: String
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var unitSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).voltaLabelStyle()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: valueSize, weight: .heavy))
                    .tracking(-valueSize * 0.02)
                    .monospacedDigit()
                    .foregroundStyle(Color.voltaTextPrimary)
                Text(unit)
                    .font(.system(size: unitSize))
                    .foregroundStyle(Color.voltaTextSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Color.voltaTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, VoltaSpacing.md)
        .padding(.vertical, VoltaSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voltaCardBackground(radius: 18)
        .accessibilityElement(children: .combine)
    }
}

extension ControlsModel {
    /// `base` with this model's own values (which may be newer, or simulated
    /// in demo mode) for the states controls change.
    func effective(_ base: VehicleStatus) -> VehicleStatus {
        guard status != nil else { return base }
        var status = base
        status.locked = locked
        status.climateOn = climateOn
        status.sentryMode = sentry
        status.chargingState = chargingState
        status.chargeLimit = chargeLimit
        return status
    }
}

// MARK: - Range bar

/// Thin blue bar with glow (green while charging); a tick marks the charge limit.
struct RangeBar: View {
    var level: Int
    var limit: Int?
    var charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                let fill = w * CGFloat(min(max(level, 0), 100)) / 100
                Capsule()
                    .fill(LinearGradient(colors: charging ? [Color(hex: 0x15803D), .voltaGreen, Color(hex: 0xA7F3D0)]
                                                          : [Color(hex: 0x2563EB), .voltaBlue, Color(hex: 0x60A5FA)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill)
                    .shadow(color: (charging ? Color.voltaGreen : .voltaBlue).opacity(0.7), radius: 6)
                    .phaseAnimator(charging && !reduceMotion ? [0.6, 1] : [1]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in .easeInOut(duration: 1.2) }
                if let limit, limit < 100 {
                    Rectangle()
                        .fill(Color.white.opacity(0.6))  // 3:1 or better on the background
                        .frame(width: 2, height: 10)
                        .offset(x: w * CGFloat(limit) / 100 - 1)
                }
                if charging, fill > 0 {
                    // Bright leading edge where energy is going in.
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: .voltaGreen, radius: 6)
                        .offset(x: fill - 4)
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Battery \(level) percent\(limit.map { ", limit \($0) percent" } ?? "")")
    }
}

// MARK: - Activity summary

struct ActivitySummarySection: View {
    var summaries: [SummaryRange: ActivitySummary]
    /// Ranges whose latest load failed (stale data, if any, is still shown).
    var failedRanges: Set<SummaryRange> = []
    var loadingRanges: Set<SummaryRange> = []
    @Environment(\.units) private var units
    @State private var range: SummaryRange = .today

    private var activityLabel: some View {
        Text("Activity").voltaLabelStyle()
            .font(.system(.footnote, weight: .semibold))
    }

    private var picker: some View {
        SegmentedRangePicker(selection: $range, minimumHitHeight: 44)
            .fixedSize()
    }

    @ViewBuilder
    private func stats(_ summary: ActivitySummary?) -> some View {
        StatColumn(value: summary.map { VoltaFormat.number(units.distanceValue(km: $0.distanceKm), digits: 0) } ?? "—",
                   caption: units.distanceUnit.uppercased())
        StatColumn(value: summary.map { "\($0.chargeCount)" } ?? "—", caption: "CHARGES")
        StatColumn(value: summary?.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—",
                   caption: units.efficiencyUnit)
    }

    var body: some View {
        let summary = summaries[range]
        VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    activityLabel
                    Spacer()
                    picker
                }
                VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                    activityLabel
                    picker
                }
            }
            // Three across, or one above another at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack { stats(summary) }
                VStack(spacing: VoltaSpacing.lg) { stats(summary) }
            }
            if summary == nil, loadingRanges.contains(range) {
                ProgressView("Loading \(range.voltaLabel) activity…")
                    .font(.footnote)
                    .tint(Color.voltaTextSecondary)
                    .frame(maxWidth: .infinity)
            } else if summary == nil, failedRanges.contains(range) {
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
}

/// Layout aid: `-dashboardTypeSize accessibility5` renders the Dashboard and
/// Controls at that text size without changing the simulator's setting.
/// DEBUG builds only.
private struct DebugTypeSizeOverride: ViewModifier {
    static var size: DynamicTypeSize? {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "dashboardTypeSize") else { return nil }
        return DynamicTypeSize.allCases.first { "\($0)" == raw }
        #else
        return nil
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size = Self.size {
            content.environment(\.dynamicTypeSize, size)
        } else {
            content
        }
    }
}
