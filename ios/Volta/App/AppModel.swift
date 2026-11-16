import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    enum PairingState: Equatable { case unpaired, paired, demo }
    private(set) var isLaunchDemo = false
    private(set) var pairingState: PairingState = .unpaired
    private(set) var dataSource: any VoltaDataSource = MockDataSource(empty: true) {
        didSet {
            dashboardCanUseInitialVehicles = false
            tesla.setClient(dataSource as? any TeslaAccountClient)
            savedDashboards.acceptedBackend = savedDashboardBackend
        }
    }
    private(set) var vehicles: [Vehicle] = []
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
    var errorMessage: String?
    let settings: UserSettings
    @ObservationIgnored private let tokenStore: any TokenStoring
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let appLock: any AppAuthenticating
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lockGeneration = UUID()
    @ObservationIgnored private var authenticateOnActive = false
    @ObservationIgnored private var dashboardCanUseInitialVehicles = false
    /// The vehicle request in flight, which a dashboard mounted from the saved
    /// list awaits instead of sending its own.
    @ObservationIgnored private var vehiclesLoad: Task<Void, Never>?
    /// The last dashboard saved for this backend; see `SavedDashboard`.
    @ObservationIgnored private let savedDashboards: any SavedDashboardStoring
    /// The saved dashboard read at launch, offered once to the first dashboard.
    @ObservationIgnored private var launchDashboard: SavedDashboard? {
        didSet { if launchDashboard == nil { launchPrefetch?.cancel(); launchPrefetch = nil } }
    }
    /// That dashboard's requests, sent at launch; see `DashboardPrefetch`.
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
        } else if !hasLoadedVehicles, let load = vehiclesLoad {
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
        // The shell mounts in the first frame; its dashboard's requests need
        // not wait for that frame to be built.
        if saved.vehicleID == selectedVehicleID {
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

    init(settings: UserSettings? = nil, tokenStore: any TokenStoring = KeychainTokenStore(), session: URLSession? = nil, appLock: any AppAuthenticating = AppLock(), launchArguments: [String] = ProcessInfo.processInfo.arguments, surfaces: (any VehicleSurfaces)? = nil, teslaWebAuth: (any TeslaWebAuthenticating)? = nil, commandIntentStore: VehicleCommandIntentStore? = nil, savedDashboards: (any SavedDashboardStoring)? = nil) {
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
        } else { restorePairing() }
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
    private func updateSurfaces() { surfaces.setContext(surfaceContext) }
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
            restoreSavedDashboard()
        } catch let error as KeychainTokenStore.StoreError where error.status == -25308 {
            needsCredentialRetry = true
            errorMessage = "Unlock your iPhone, then retry access to the stored device token."
        } catch { needsCredentialRetry = false; errorMessage = error.localizedDescription }
    }
    private func makeAPI(url: URL, token: String) -> APIDataSource {
        let currentGeneration = generation
        return APIDataSource(baseURL: url, token: token, session: session) { [weak self] in
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
    func loadVehicles() async {
        guard isPaired, !isLoadingVehicles, !isLocked else { return }
        isLoadingVehicles = true
        let load = Task { await performVehicleLoad() }
        vehiclesLoad = load
        await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
    }
    private func performVehicleLoad() async {
        let currentGeneration = generation; let source = dataSource
        defer {
            if generation == currentGeneration { isLoadingVehicles = false; hasLoadedVehicles = true; vehiclesLoad = nil }
        }
        do {
            let vehicles = try await source.vehicles()
            guard generation == currentGeneration else { return }
            dashboardCanUseInitialVehicles = !hasLoadedVehicles
            self.vehicles = vehicles
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
            if unlocked && !hasLoadedVehicles { restoreSavedDashboard(); await loadVehicles() }
        } catch { if generation == currentGeneration && lockGeneration == currentLock { errorMessage = error.localizedDescription } }
    }
}
