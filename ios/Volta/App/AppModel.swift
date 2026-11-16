import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    enum PairingState: Equatable { case unpaired, paired, demo }
    private(set) var isLaunchDemo = false
    private(set) var pairingState: PairingState = .unpaired
    private(set) var dataSource: any VoltaDataSource = MockDataSource(empty: true) {
        didSet {
            connectionGeneration &+= 1
            // The replaced source must never send another command, even one
            // already past every check upstream.
            (oldValue as? APIDataSource)?.invalidateCommands()
            dashboardCanUseInitialVehicles = false
            tesla.setClient(dataSource as? any TeslaAccountClient)
            savedDashboards.acceptedBackend = savedDashboardBackend
            followSelectionInSavedDashboards()
            launchVehicles?.cancel(); launchVehicles = nil
            vehiclesLoad = nil; startupLoad = nil; startupLoadUnclaimed = false
        }
    }
    /// Changes whenever the data source is replaced (pairing, demo mode,
    /// disconnecting), so work that awaited can tell its source is stale.
    @ObservationIgnored private(set) var connectionGeneration = 0
    /// Test hook passed to each API data source; see `APIDataSource`.
    private let willStartCommand: (@Sendable () -> Void)?
    /// A pending request from the lock control to open the Controls screen
    /// (to unlock there). See `controlsRequestDecision`.
    private(set) var controlsRequest: ControlsRequest?
    /// Set when the request may be shown now: the shell selects the Dashboard
    /// and the Dashboard, which owns Controls, opens them and takes it
    /// (`takeControlsPresentation`). One request opens Controls once.
    private(set) var controlsPresentationRequested = false
    @ObservationIgnored private var presentationGeneration: Int?
    /// The scene's phase as last reported by the root view (nil before the
    /// first report). The privacy shield and the Controls sheet's cover both
    /// read it, so they always agree.
    private(set) var scenePhase: AppScenePhase?
    /// The effective selection depends on it, so the saved-dashboard fence
    /// follows every change (the saved list restored at launch or unlock too).
    private(set) var vehicles: [Vehicle] = [] { didSet { followSelectionInSavedDashboards() } }
    private(set) var hasLoadedVehicles = false
    private(set) var needsCredentialRetry = false
    private(set) var isConfiguringAppLock = false
    private(set) var isLoadingVehicles = false
    private(set) var isPairing = false
    /// Servers that answered they don't offer Sign in with Apple. The sign-in
    /// screen asks for a pairing code for these addresses only.
    private var serversWithoutAppleSignIn: Set<String> = []
    private var alwaysNeedsPairingCode = false
    /// The server the sign-in screen connects to.
    let signInServerURL: String
    private(set) var isUnlocking = false
    private(set) var isLocked = false
    /// Counts unlocks the user cancelled or that failed. The Dashboard closes
    /// Controls the lock was hiding (see `ControlsRouting`).
    private(set) var refusedUnlocks = 0
    var errorMessage: String?
    let settings: UserSettings
    @ObservationIgnored private let tokenStore: any TokenStoring
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let appLock: any AppAuthenticating
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lockGeneration = UUID()
    @ObservationIgnored private var authenticateOnActive = false
    @ObservationIgnored private var dashboardCanUseInitialVehicles = false
    /// The vehicle load in flight. Every caller joins it rather than sending
    /// another `/vehicles`: the root view, and a dashboard mounted from the
    /// saved list, in whichever order their tasks run.
    @ObservationIgnored private var vehiclesLoad: Task<Void, Never>?
    /// False while `init` runs in an iOS prewarm: the process may then be
    /// suspended for a long time, so nothing is sent until the user opens the app.
    @ObservationIgnored private var sendsLaunchRequests = true
    /// The load started by `restorePairing()`, until a `loadVehicles()` joins it.
    @ObservationIgnored private var startupLoad: Task<Void, Never>?
    /// It succeeded before any `loadVehicles()` joined it: the root view's
    /// first call then has nothing to send.
    @ObservationIgnored private var startupLoadUnclaimed = false
    /// `/vehicles`, sent when a stored pairing is restored rather than when the
    /// root view first appears; the next vehicle load consumes it.
    @ObservationIgnored private var launchVehicles: Task<[Vehicle], any Error>?
    /// The last dashboard saved for this backend; see `SavedDashboard`.
    @ObservationIgnored private let savedDashboards: any SavedDashboardStoring
    /// The saved dashboard read at launch, offered once to the first dashboard.
    @ObservationIgnored private var launchDashboard: SavedDashboard? {
        didSet { if launchDashboard == nil { launchPrefetch?.cancel(); launchPrefetch = nil } }
    }
    /// That dashboard's `/status`, sent at launch; see `DashboardPrefetch`.
    @ObservationIgnored private var launchPrefetch: DashboardPrefetch?
    /// Widget snapshot + Live Activities. Told about every pairing, demo and
    /// vehicle change; see `surfaceContext`.
    @ObservationIgnored let surfaces: any VehicleSurfaces
    /// Sign in with Tesla. Follows `dataSource`, so any pairing change cancels a running flow.
    let tesla: TeslaLinkModel
    /// One command coordinator for every surface, keyed by backend and vehicle.
    let commandCoordinator: VehicleCommandCoordinator

    var isDemoMode: Bool { pairingState == .demo }
    var isPaired: Bool { pairingState != .unpaired }
    /// Setting it is the user's explicit choice; see `resolveSelection`.
    var selectedVehicleID: Int {
        get { isLaunchDemo ? MockDataSource.vehicleID : settings.selectedVehicleID ?? Vehicle.automaticChoice(in: vehicles)?.id ?? MockDataSource.vehicleID }
        set {
            guard !isLaunchDemo else { return }
            dashboardCanUseInitialVehicles = false
            launchDashboard = nil
            settings.selectedVehicleID = newValue; settings.selectedVehicleIsExplicit = true
            updateSurfaces()
        }
    }
    var selectedVehicle: Vehicle? { vehicles.first { $0.id == selectedVehicleID } }
    /// What a newly mounted dashboard starts from: where to save what it
    /// loads, and, for the first dashboard only, the dashboard saved by the
    /// previous launch and the startup vehicle list. That list may still be
    /// loading when a saved dashboard mounted the shell early; the dashboard
    /// then awaits it rather than sending a second `/vehicles`. Remounts after
    /// a vehicle switch must fetch a new list, even within this process.
    func takeInitialDashboardVehicles(vehicleID: Int) -> DashboardStart? {
        let canUseVehicles = dashboardCanUseInitialVehicles
        dashboardCanUseInitialVehicles = false
        let saved = launchDashboard, prefetch = launchPrefetch
        launchPrefetch = nil
        launchDashboard = nil
        guard isPaired, !isLocked else { prefetch?.cancel(); return nil }
        let backend = savedDashboardBackend
        // DashboardModel cancels a prefetch it cannot use.
        var start = DashboardStart(saved: saved?.vehicleID == vehicleID ? saved : nil,
                                   store: backend == nil ? nil : savedDashboards, backend: backend,
                                   prefetch: prefetch)
        guard vehicleID == selectedVehicleID else { return start }
        if canUseVehicles {
            start.vehicles = { [vehicles] in vehicles }
        } else if !hasLoadedVehicles, let load = vehiclesLoad ?? startVehicleLoad() {
            let currentGeneration = generation
            start.vehicles = { [weak self] in
                await load.value
                guard let self, self.generation == currentGeneration, self.dashboardCanUseInitialVehicles,
                      vehicleID == self.selectedVehicleID else { return nil }
                self.dashboardCanUseInitialVehicles = false
                return self.vehicles
            }
        }
        return start
    }
    /// The saved-dashboard key of the paired server; nil in demo mode.
    private var savedDashboardBackend: String? {
        guard pairingState == .paired, !isLaunchDemo, let api = dataSource as? APIDataSource else { return nil }
        return SavedDashboard.backendKey(api.commandBackendID)
    }
    /// Shows the previous launch's vehicles, so the shell and its saved
    /// dashboard appear in the first frame. The vehicle request still runs and
    /// replaces them. Never while locked: unlocking restores it.
    private func restoreSavedDashboard() {
        guard pairingState == .paired, !isLocked, !hasLoadedVehicles, vehicles.isEmpty,
              let backend = savedDashboardBackend, let saved = savedDashboards.read(backend: backend),
              saved.vehicles.contains(where: { $0.id == saved.vehicleID }) else { return }
        vehicles = saved.vehicles
        launchDashboard = saved
        // The shell mounts in the first frame; its dashboard's status need
        // not wait for that frame to be built.
        if saved.vehicleID == selectedVehicleID, sendsLaunchRequests {
            launchPrefetch = DashboardPrefetch(dataSource: dataSource, vehicleID: saved.vehicleID, surfaces: surfaces)
        }
    }
    private func forgetSavedDashboard() {
        launchDashboard = nil
        savedDashboards.remove()
    }
    /// The user's choice of a car from a list newer than `vehicles` (Dashboard
    /// refreshes its own). An id missing from `vehicles` would leave the surfaces
    /// `.pending`, which keeps the previous car's widget and Live Activities and
    /// never publishes the new one's; adopting it first makes the switch clean up.
    func select(_ vehicle: Vehicle) {
        guard !isLaunchDemo else { return }
        if !vehicles.contains(where: { $0.id == vehicle.id }) { vehicles.append(vehicle) }
        selectedVehicleID = vehicle.id
    }
    /// What widgets and Live Activities may show. Only a paired, loaded vehicle
    /// is published; every demo and unpaired state clears them. A Keychain
    /// that is still locked after prewarm leaves them untouched.
    var surfaceContext: VehicleSurfaceContext {
        if isLaunchDemo { return .inactive }
        if needsCredentialRetry { return .suspended }
        switch pairingState {
        case .unpaired, .demo: return .inactive
        case .paired:
            guard let vehicle = selectedVehicle else { return .pending }
            return .vehicle(id: vehicle.id, name: vehicle.name)
        }
    }
    /// Inject no publisher into synthetic screens: mock refreshes never even
    /// reach WidgetSync. The context still clears snapshots and activities.
    var refreshSurfaces: (any VehicleSurfaces)? {
        guard case .vehicle = surfaceContext else { return nil }
        return surfaces
    }
    var units: UnitPreferences {
        get { settings.units }
        set { settings.units = newValue }
    }
    /// Live Activity while driving. Turning it off ends running driving activities
    /// immediately, even while a sync is waiting on the network.
    var drivingLiveActivity: Bool {
        get { settings.drivingLiveActivity }
        set {
            guard newValue != settings.drivingLiveActivity else { return }
            settings.drivingLiveActivity = newValue
            surfaces.drivingActivityPreferenceChanged()
        }
    }
    var appLockEnabled: Bool {
        get { !isLaunchDemo && settings.appLockEnabled }
        set { Task { await setAppLockEnabled(newValue) } }
    }

    init(settings: UserSettings? = nil, tokenStore: any TokenStoring = KeychainTokenStore(), session: URLSession? = nil, appLock: any AppAuthenticating = AppLock(), launchArguments: [String] = ProcessInfo.processInfo.arguments, launchEnvironment: [String: String] = ProcessInfo.processInfo.environment, surfaces: (any VehicleSurfaces)? = nil, teslaWebAuth: (any TeslaWebAuthenticating)? = nil, commandIntentStore: VehicleCommandIntentStore? = nil, savedDashboards: (any SavedDashboardStoring)? = nil, willStartCommand: (@Sendable () -> Void)? = nil) {
        StartupTrace.mark(.appModel)
        let demoIndex = launchArguments.firstIndex(of: "-demo-mode")
        let launchDemo = demoIndex.flatMap { index -> Bool? in
            guard launchArguments.indices.contains(index + 1) else { return nil }
            return ["yes", "true", "1"].contains(launchArguments[index + 1].lowercased())
        } ?? false
        // Resolve the override before constructing or reading the persistent domain.
        let settings = launchDemo ? UserSettings(defaults: nil) : settings ?? UserSettings()
        self.settings = settings; self.tokenStore = tokenStore; self.session = session; self.appLock = appLock
        // The saved dashboard lives beside the stored credential; test token
        // stores get one in memory.
        self.savedDashboards = savedDashboards ?? (tokenStore is KeychainTokenStore ? SavedDashboardFile() : MemorySavedDashboards())
        self.willStartCommand = willStartCommand
        self.surfaces = surfaces ?? WidgetSync(settings: settings)
        tesla = TeslaLinkModel(webAuth: teslaWebAuth ?? TeslaWebAuthenticator())
        commandCoordinator = VehicleCommandCoordinator(store: commandIntentStore ?? (launchDemo ? VehicleCommandIntentStore(inMemory: []) : nil))
        isLaunchDemo = launchDemo
        var signInServerURL = VoltaServer.address
        #if DEBUG
        // UI tests and startup benchmarks sign in to a local fixture.
        if let index = launchArguments.firstIndex(of: "-serverURL"), launchArguments.indices.contains(index + 1) {
            signInServerURL = launchArguments[index + 1]
        }
        // Startup benchmarks pair with a local fixture that has no Apple sign-in.
        alwaysNeedsPairingCode = launchArguments.contains("-pairing-code")
        #endif
        self.signInServerURL = signInServerURL
        if launchDemo || settings.demoMode {
            pairingState = .demo; dataSource = MockDataSource(empty: launchDemo ? false : settings.emptyDemo)
        } else {
            sendsLaunchRequests = launchEnvironment["ActivePrewarm"] != "1"
            restorePairing()
            // Any later restore happens with the user present.
            sendsLaunchRequests = true
        }
        isLocked = isPaired && settings.appLockEnabled
        self.savedDashboards.acceptedBackend = savedDashboardBackend
        updateSurfaces()
        tesla.setClient(dataSource as? any TeslaAccountClient)
        tesla.onConnected = { [weak self] in
            guard let self else { return }
            await self.loadVehicles()
            await self.commandCoordinator.refreshCapabilities(dataSource: self.dataSource,
                                                               vehicleID: self.selectedVehicleID)
        }
    }
    /// Every selection, pairing and vehicle-list change ends here, so the
    /// saved-dashboard store follows the selected car too.
    private func updateSurfaces() {
        surfaces.setContext(surfaceContext)
        followSelectionInSavedDashboards()
    }
    /// Saves are accepted only for the effective selection. Called by every
    /// path that can change it: `vehicles`, the stored choice (via
    /// `updateSurfaces`) and pairing.
    private func followSelectionInSavedDashboards() {
        savedDashboards.acceptedVehicleID = selectedVehicleID
    }
    /// Retry Keychain access when protected data becomes available after prewarm.
    func restorePairing() {
        guard !isLaunchDemo, pairingState == .unpaired else { return }
        defer { updateSurfaces() }
        do {
            guard let token = try tokenStore.load(), !token.isEmpty else { needsCredentialRetry = false; return }
            // A reinstall can retain Keychain but lose UserDefaults. Never send a token to an unknown endpoint.
            guard !settings.serverURL.isEmpty else { needsCredentialRetry = false; return }
            let url = try APIDataSource.validatedServerURL(settings.serverURL)
            pairingState = .paired; dataSource = makeAPI(url: url, token: token)
            needsCredentialRetry = false; errorMessage = nil
            isLocked = settings.appLockEnabled
            // Status first: a saved list already stands in for the vehicles.
            restoreSavedDashboard()
            if !isLocked, sendsLaunchRequests {
                // Detached: a main-actor task would not start until the first frame is built.
                launchVehicles = Task.detached(priority: .userInitiated) { [dataSource] in try await dataSource.vehicles() }
                // Exists before any view's task runs, so each of them joins it.
                startupLoad = startVehicleLoad()
            }
        } catch let error as KeychainTokenStore.StoreError where error.status == -25308 {
            needsCredentialRetry = true
            errorMessage = "Unlock your iPhone, then retry access to the stored device token."
        } catch { needsCredentialRetry = false; errorMessage = error.localizedDescription }
    }
    private func makeAPI(url: URL, token: String) -> APIDataSource {
        let currentGeneration = generation
        return APIDataSource(baseURL: url, token: token, session: session, willStartCommand: willStartCommand) { [weak self] in
            await self?.handleUnauthorized(generation: currentGeneration)
        }
    }
    private func handleUnauthorized(generation: UUID) {
        guard self.generation == generation, pairingState == .paired else { return }
        unpair()
        errorMessage = "This device token was revoked or expired. Sign in again to reconnect."
    }
    /// True when `serverURL` answered that it doesn't offer Sign in with Apple.
    func needsPairingCode(for serverURL: String) -> Bool {
        if alwaysNeedsPairingCode { return true }
        return Self.serverKey(serverURL).map(serversWithoutAppleSignIn.contains) ?? false
    }
    /// Host and port, so spellings of one address match.
    private static func serverKey(_ serverURL: String) -> String? {
        guard let url = try? APIDataSource.validatedServerURL(serverURL), let host = url.host?.lowercased() else { return nil }
        return "\(host):\(url.port ?? 443)"
    }
    private func resetSignInFallbacks() { serversWithoutAppleSignIn = [] }
    func pair(serverURL: String, code: String, deviceName: String) async {
        await connect(serverURL: serverURL, deviceName: deviceName, withApple: false) { url, name, session in
            let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !name.isEmpty else {
                throw VoltaError.transport("Enter the eight-character code and a device name.")
            }
            return try await APIDataSource.pair(baseURL: url, code: code, deviceName: name, session: session)
        }
    }
    /// Connects with the identity token from Sign in with Apple. The server
    /// issues the same device token as pairing, to an enrolled Apple Account only.
    func signInWithApple(serverURL: String, identityToken: String, deviceName: String) async {
        await connect(serverURL: serverURL, deviceName: deviceName, withApple: true) { url, name, session in
            guard !name.isEmpty else { throw VoltaError.transport("Enter a device name.") }
            return try await APIDataSource.signInWithApple(baseURL: url, identityToken: identityToken, deviceName: name, session: session)
        }
    }
    /// Obtains a device token with `issue`, stores it, and switches to the server.
    private func connect(serverURL: String, deviceName: String, withApple: Bool,
                         issue: (URL, String, URLSession?) async throws -> PairResponse) async {
        guard !isLaunchDemo, pairingState == .unpaired, !isPairing else { return }
        errorMessage = nil
        let currentGeneration = generation
        isPairing = true
        defer { if generation == currentGeneration { isPairing = false } }
        do {
            let url = try APIDataSource.validatedServerURL(serverURL)
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await issue(url, name, session)
            guard currentGeneration == generation else {
                if !response.token.isEmpty { try? await APIDataSource(baseURL: url, token: response.token, session: session).revoke() }
                return
            }
            guard !response.token.isEmpty else { throw VoltaError.transport("The server returned an empty device token.") }
            do { try tokenStore.save(response.token) }
            catch {
                let storageError = error
                try? await APIDataSource(baseURL: url, token: response.token, session: session).revoke()
                guard currentGeneration == generation else { return }
                throw storageError
            }
            settings.serverURL = url.absoluteString
            settings.signedInWithApple = withApple
            resetSignInFallbacks()
            settings.demoMode = false
            needsCredentialRetry = false; hasLoadedVehicles = false
            settings.selectedVehicleID = nil; settings.selectedVehicleIsExplicit = false
            pairingState = .paired
            dataSource = makeAPI(url: url, token: response.token)
            isLocked = settings.appLockEnabled
            updateSurfaces()
            await loadVehicles()
        } catch is CancellationError { }
        catch {
            guard generation == currentGeneration else { return }
            switch error as? VoltaError {
            case .appleSignInUnavailable:
                if let key = Self.serverKey(serverURL) { serversWithoutAppleSignIn.insert(key) }
            case .unreachable:
                errorMessage = "Couldn't reach your Volta server. Check that Tailscale is connected, then try again."
                return
            default: break
            }
            errorMessage = error.localizedDescription
        }
    }
    func tryDemoMode(empty: Bool = false) {
        generation = UUID(); lockGeneration = UUID(); appLock.cancel()
        isPairing = false; isUnlocking = false; isLoadingVehicles = false; isConfiguringAppLock = false
        needsCredentialRetry = false; hasLoadedVehicles = false; authenticateOnActive = false
        if !isLaunchDemo {
            settings.emptyDemo = empty
            settings.demoMode = true; settings.selectedVehicleID = nil; settings.selectedVehicleIsExplicit = false
            forgetSavedDashboard()
        }
        pairingState = .demo; dataSource = MockDataSource(empty: empty)
        vehicles = []; errorMessage = nil; resetSignInFallbacks()
        isLocked = settings.appLockEnabled
        updateSurfaces()
    }
    /// Local disconnect. Explicit server-side revoke is available separately.
    @discardableResult
    func unpair() -> Bool {
        ExportFiles.removeAll()
        if isLaunchDemo { exitLaunchDemo(); return true }
        generation = UUID(); lockGeneration = UUID(); appLock.cancel()
        isPairing = false; isUnlocking = false; isLoadingVehicles = false; isConfiguringAppLock = false
        settings.demoMode = false; settings.emptyDemo = false
        settings.selectedVehicleID = nil; settings.selectedVehicleIsExplicit = false
        needsCredentialRetry = false; hasLoadedVehicles = false; authenticateOnActive = false
        pairingState = .unpaired; vehicles = []; isLocked = false; resetSignInFallbacks()
        dataSource = MockDataSource(empty: true)
        forgetSavedDashboard()
        updateSurfaces()  // clears the widget snapshot and ends Live Activities
        do { try tokenStore.delete(); errorMessage = nil; return true }
        catch { settings.serverURL = ""; errorMessage = error.localizedDescription; return false }
    }
    func revokeAndUnpair() async {
        let currentGeneration = generation
        do {
            if let api = dataSource as? APIDataSource { try await api.revoke() }
            if generation == currentGeneration { unpair() }
        } catch { if generation == currentGeneration { errorMessage = error.localizedDescription } }
    }
    /// Joins the vehicle load in flight, or starts one.
    func loadVehicles() async {
        if let load = vehiclesLoad {
            if load == startupLoad { startupLoad = nil }
            await load.value
            return
        }
        if startupLoadUnclaimed { startupLoadUnclaimed = false; return }
        guard let load = startVehicleLoad() else { return }
        await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
    }
    @discardableResult private func startVehicleLoad() -> Task<Void, Never>? {
        guard isPaired, !isLoadingVehicles, !isLocked else { return nil }
        isLoadingVehicles = true
        let load = Task { await performVehicleLoad() }
        vehiclesLoad = load
        return load
    }
    private func performVehicleLoad() async {
        let currentGeneration = generation; let source = dataSource
        defer {
            if generation == currentGeneration {
                isLoadingVehicles = false; hasLoadedVehicles = true
                if vehiclesLoad == startupLoad { startupLoad = nil }
                vehiclesLoad = nil
            }
        }
        do {
            let launch = launchVehicles
            launchVehicles = nil
            let vehicles: [Vehicle]
            if let launch { vehicles = try await DashboardPrefetch.value(of: launch) }
            else { vehicles = try await source.vehicles() }
            guard generation == currentGeneration else { return }
            dashboardCanUseInitialVehicles = !hasLoadedVehicles
            self.vehicles = vehicles
            if let startupLoad, vehiclesLoad == startupLoad { startupLoadUnclaimed = true }
            StartupTrace.mark(.vehicles)
            if !isLaunchDemo { resolveSelection() }
            updateSurfaces()
            errorMessage = nil
        } catch is CancellationError { }
        catch { if generation == currentGeneration { errorMessage = error.localizedDescription } }
    }
    /// Reads the selection after the vehicle request returns, so a choice made
    /// meanwhile wins. An explicit choice stays while that vehicle exists, even
    /// without data. An automatic one stays unless the server reports it has no
    /// data and another vehicle does; it never hops between cars that have data.
    private func resolveSelection() {
        let saved = vehicles.first { $0.id == settings.selectedVehicleID }
        if let saved, settings.selectedVehicleIsExplicit || saved.hasData != false
            || !vehicles.contains(where: { $0.hasData != false }) { return }
        settings.selectedVehicleID = Vehicle.automaticChoice(in: vehicles)?.id
        settings.selectedVehicleIsExplicit = false
    }
    /// Enabling a lock requires a successful system authentication first.
    func setAppLockEnabled(_ enabled: Bool) async {
        guard !isLaunchDemo, !isConfiguringAppLock, !isLocked else { return }
        if !enabled { settings.appLockEnabled = false; return }
        guard !settings.appLockEnabled else { return }
        let currentGeneration = generation; let currentLock = lockGeneration
        isConfiguringAppLock = true; errorMessage = nil
        defer { if generation == currentGeneration { isConfiguringAppLock = false } }
        do {
            let verified = try await appLock.unlock()
            guard generation == currentGeneration && lockGeneration == currentLock else { return }
            if verified { settings.appLockEnabled = true }
        } catch { if generation == currentGeneration && lockGeneration == currentLock { errorMessage = error.localizedDescription } }
    }
    /// Recovery removes private credentials before disabling an unusable lock.
    func disconnectLockedDevice() {
        if isLaunchDemo { exitLaunchDemo(); return }
        if unpair() { settings.appLockEnabled = false }
    }
    /// A launch-only demo must never disconnect the saved real device.
    private func exitLaunchDemo() {
        generation = UUID(); lockGeneration = UUID(); appLock.cancel()
        authenticateOnActive = false
        isPairing = false; isUnlocking = false; isLoadingVehicles = false; isConfiguringAppLock = false
        vehicles = []; hasLoadedVehicles = false; needsCredentialRetry = false; errorMessage = nil
        pairingState = .unpaired; dataSource = MockDataSource(empty: true); isLocked = false
        updateSurfaces()
        // This process stays isolated even after exiting the synthetic preview.
        // A normal relaunch is required to access saved pairing or credentials.
    }
    /// Foreground and screen appearance: show the server's actual Tesla state.
    func refreshTesla() async {
        guard isPaired, !isLocked, !needsCredentialRetry else { return }
        await tesla.refresh()
    }
    func didEnterBackground() {
        lock(); authenticateOnActive = true
    }
    func becameActive() async {
        if needsCredentialRetry { restorePairing() }
        guard authenticateOnActive else { return }
        // Consumed before showing the system sheet: inactive -> active after Cancel
        // cannot issue another automatic prompt.
        authenticateOnActive = false
        if isLocked { await unlock() }
    }
    func lock() {
        dashboardCanUseInitialVehicles = false
        launchDashboard = nil
        lockGeneration = UUID(); appLock.cancel(); isUnlocking = false
        if !isLaunchDemo && settings.appLockEnabled && isPaired { isLocked = true }
    }
    func unlock() async {
        guard isLocked, !isUnlocking else { return }
        let currentGeneration = generation; let currentLock = lockGeneration
        isUnlocking = true; errorMessage = nil
        defer { if generation == currentGeneration && lockGeneration == currentLock { isUnlocking = false } }
        do {
            let unlocked = try await appLock.unlock()
            guard generation == currentGeneration && lockGeneration == currentLock else { return }
            isLocked = !unlocked
            // Authentication cancelled or failed: a waiting Controls request is dropped.
            if !unlocked { controlsRequest = nil; refusedUnlocks += 1 }
            if unlocked && !hasLoadedVehicles { restoreSavedDashboard(); await loadVehicles() }
        } catch {
            if generation == currentGeneration && lockGeneration == currentLock {
                errorMessage = error.localizedDescription
                controlsRequest = nil
                refusedUnlocks += 1
            }
        }
    }
}

// MARK: - Controls requested by the lock control

/// One pending request to open the Controls screen, tied to the connection
/// it was made under.
struct ControlsRequest: Equatable, Hashable, Sendable {
    var generation: Int
}

enum ControlsRequestDecision: Equatable, Sendable {
    /// No request is pending.
    case idle
    /// Keep the request until the app is in front, unlocked and has a car.
    case wait
    case present
    case drop
}

extension AppModel {
    /// What the presenter watches; any change re-evaluates the request.
    struct ControlsRequestInputs: Hashable {
        var request: ControlsRequest?
        var generation: Int
        var isPaired: Bool
        var isLocked: Bool
        var hasVehicles: Bool
    }

    var controlsRequestInputs: ControlsRequestInputs {
        ControlsRequestInputs(request: controlsRequest, generation: connectionGeneration, isPaired: isPaired,
                              isLocked: isLocked, hasVehicles: !vehicles.isEmpty)
    }

    /// Called by the lock control (through the intent service).
    func requestControls() {
        controlsRequest = ControlsRequest(generation: connectionGeneration)
    }

    /// Whether to show the requested Controls screen now. Pure, so every
    /// branch is unit tested.
    /// - A request from another connection (disconnect, re-pair, demo switch) is dropped.
    /// - Without a session it is dropped.
    /// - While the app is in the background or behind the app lock, it waits;
    ///   a cancelled or failed unlock drops it (see `unlock()`).
    /// - Another sheet already up drops it: sheets never stack.
    static func controlsRequestDecision(_ request: ControlsRequest?, generation: Int, isPaired: Bool,
                                        isActive: Bool, isLocked: Bool, hasVehicles: Bool,
                                        otherSheetUp: Bool) -> ControlsRequestDecision {
        guard let request else { return .idle }
        guard request.generation == generation, isPaired else { return .drop }
        guard isActive, !isLocked, hasVehicles else { return .wait }
        return otherSheetUp ? .drop : .present
    }

    /// The scene is in front and taking input. Before the first report it
    /// counts as active, as at launch.
    var isSceneActive: Bool { scenePhase.map { $0 == .active } ?? true }

    /// Whether the root shows its privacy shield: paired with the app lock on
    /// and the scene not active (Control Center, the app switcher, a system
    /// alert, the background).
    static func needsPrivacy(isPaired: Bool, appLockEnabled: Bool, isActive: Bool) -> Bool {
        isPaired && appLockEnabled && !isActive
    }

    var needsPrivacy: Bool {
        Self.needsPrivacy(isPaired: isPaired, appLockEnabled: appLockEnabled, isActive: isSceneActive)
    }

    /// Whether the Controls sheet is covered: whenever the root shows its
    /// privacy shield or lock overlay. A sheet sits above the root, so it
    /// carries its own cover. (Pushed Controls are inside the root, which
    /// covers them.)
    static func controlsCovered(isLocked: Bool, needsPrivacy: Bool) -> Bool {
        isLocked || needsPrivacy
    }

    var controlsCovered: Bool {
        Self.controlsCovered(isLocked: isLocked, needsPrivacy: needsPrivacy)
    }

    /// The Dashboard calls this when it opens Controls for the request.
    /// True once per request.
    func takeControlsPresentation() -> Bool {
        guard controlsPresentationRequested else { return false }
        controlsPresentationRequested = false
        return true
    }

    /// The root view's scene-phase handling. Inactive only covers; background
    /// locks, which closes the Controls sheet.
    func sceneDidChange(to phase: AppScenePhase, otherSheetUp: Bool) {
        let previous = scenePhase
        scenePhase = phase
        if phase == .background, previous != nil, previous != .background { didEnterBackground() }
        updateControlsRequest(otherSheetUp: otherSheetUp)
    }

    /// Called whenever `controlsRequestInputs` or the scene phase change. A
    /// presentation the Dashboard hasn't taken yet is withdrawn when the app
    /// locks or the connection ends.
    func updateControlsRequest(otherSheetUp: Bool) {
        if controlsPresentationRequested, isLocked || !isPaired || presentationGeneration != connectionGeneration {
            controlsPresentationRequested = false
        }
        switch Self.controlsRequestDecision(controlsRequest, generation: connectionGeneration, isPaired: isPaired,
                                            isActive: isSceneActive, isLocked: isLocked, hasVehicles: !vehicles.isEmpty,
                                            otherSheetUp: otherSheetUp) {
        case .present:
            controlsRequest = nil
            presentationGeneration = connectionGeneration
            controlsPresentationRequested = true
        case .drop:
            controlsRequest = nil
        case .idle, .wait:
            break
        }
    }
}

/// The scene phases the model distinguishes (mirrors SwiftUI's `ScenePhase`).
enum AppScenePhase: Equatable, Sendable { case active, inactive, background }
