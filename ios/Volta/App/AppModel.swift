import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    enum PairingState: Equatable { case unpaired, paired, demo }
    private(set) var isLaunchDemo = false
    private(set) var pairingState: PairingState = .unpaired
    private(set) var dataSource: any VoltaDataSource = MockDataSource(empty: true) {
        didSet { tesla.setClient(dataSource as? any TeslaAccountClient) }
    }
    private(set) var vehicles: [Vehicle] = []
    private(set) var hasLoadedVehicles = false
    private(set) var needsCredentialRetry = false
    private(set) var isConfiguringAppLock = false
    private(set) var isLoadingVehicles = false
    private(set) var isPairing = false
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
    /// Widget snapshot + Live Activities. Told about every pairing, demo and
    /// vehicle change; see `surfaceContext`.
    @ObservationIgnored let surfaces: any VehicleSurfaces
    /// Sign in with Tesla. Follows `dataSource`, so any pairing change cancels a running flow.
    let tesla: TeslaLinkModel

    var isDemoMode: Bool { pairingState == .demo }
    var isPaired: Bool { pairingState != .unpaired }
    /// Setting it is the user's explicit choice; see `resolveSelection`.
    var selectedVehicleID: Int {
        get { isLaunchDemo ? MockDataSource.vehicleID : settings.selectedVehicleID ?? Vehicle.automaticChoice(in: vehicles)?.id ?? MockDataSource.vehicleID }
        set {
            guard !isLaunchDemo else { return }
            settings.selectedVehicleID = newValue; settings.selectedVehicleIsExplicit = true
            updateSurfaces()
        }
    }
    var selectedVehicle: Vehicle? { vehicles.first { $0.id == selectedVehicleID } }
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

    init(settings: UserSettings? = nil, tokenStore: any TokenStoring = KeychainTokenStore(), session: URLSession? = nil, appLock: any AppAuthenticating = AppLock(), launchArguments: [String] = ProcessInfo.processInfo.arguments, surfaces: (any VehicleSurfaces)? = nil, teslaWebAuth: (any TeslaWebAuthenticating)? = nil) {
        let demoIndex = launchArguments.firstIndex(of: "-demo-mode")
        let launchDemo = demoIndex.flatMap { index -> Bool? in
            guard launchArguments.indices.contains(index + 1) else { return nil }
            return ["yes", "true", "1"].contains(launchArguments[index + 1].lowercased())
        } ?? false
        // Resolve the override before constructing or reading the persistent domain.
        let settings = launchDemo ? UserSettings(defaults: nil) : settings ?? UserSettings()
        self.settings = settings; self.tokenStore = tokenStore; self.session = session; self.appLock = appLock
        self.surfaces = surfaces ?? WidgetSync(settings: settings)
        tesla = TeslaLinkModel(webAuth: teslaWebAuth ?? TeslaWebAuthenticator())
        isLaunchDemo = launchDemo
        if launchDemo || settings.demoMode {
            pairingState = .demo; dataSource = MockDataSource(empty: launchDemo ? false : settings.emptyDemo)
        } else { restorePairing() }
        isLocked = isPaired && settings.appLockEnabled
        updateSurfaces()
        tesla.setClient(dataSource as? any TeslaAccountClient)
        tesla.onConnected = { [weak self] in await self?.loadVehicles() }
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
        errorMessage = "This device token was revoked or expired. Pair again to reconnect."
    }
    func pair(serverURL: String, code: String, deviceName: String) async {
        guard !isLaunchDemo, pairingState == .unpaired, !isPairing else { return }
        errorMessage = nil
        let currentGeneration = generation
        isPairing = true
        defer { if generation == currentGeneration { isPairing = false } }
        do {
            let url = try APIDataSource.validatedServerURL(serverURL)
            let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !name.isEmpty else {
                throw VoltaError.transport("Enter the eight-character code and a device name.")
            }
            let response = try await APIDataSource.pair(baseURL: url, code: code, deviceName: name, session: session)
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
            settings.demoMode = false
            needsCredentialRetry = false; hasLoadedVehicles = false
            settings.selectedVehicleID = nil; settings.selectedVehicleIsExplicit = false
            pairingState = .paired
            dataSource = makeAPI(url: url, token: response.token)
            isLocked = settings.appLockEnabled
            updateSurfaces()
            await loadVehicles()
        } catch is CancellationError { }
        catch { if generation == currentGeneration { errorMessage = error.localizedDescription } }
    }
    func tryDemoMode(empty: Bool = false) {
        generation = UUID(); lockGeneration = UUID(); appLock.cancel()
        isPairing = false; isUnlocking = false; isLoadingVehicles = false; isConfiguringAppLock = false
        needsCredentialRetry = false; hasLoadedVehicles = false; authenticateOnActive = false
        if !isLaunchDemo {
            settings.emptyDemo = empty
            settings.demoMode = true; settings.selectedVehicleID = nil; settings.selectedVehicleIsExplicit = false
        }
        pairingState = .demo; dataSource = MockDataSource(empty: empty)
        vehicles = []; errorMessage = nil
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
        pairingState = .unpaired; vehicles = []; isLocked = false
        dataSource = MockDataSource(empty: true)
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
        let currentGeneration = generation; let source = dataSource
        isLoadingVehicles = true
        defer { if generation == currentGeneration { isLoadingVehicles = false; hasLoadedVehicles = true } }
        do {
            let vehicles = try await source.vehicles()
            guard generation == currentGeneration else { return }
            self.vehicles = vehicles
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
            if unlocked && !hasLoadedVehicles { await loadVehicles() }
        } catch { if generation == currentGeneration && lockGeneration == currentLock { errorMessage = error.localizedDescription } }
    }
}
