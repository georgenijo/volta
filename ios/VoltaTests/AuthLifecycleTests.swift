import XCTest
import Synchronization
@testable import Volta

private final class MemoryTokenStore: TokenStoring, Sendable {
    let accesses = Mutex(0)
    private let state = Mutex<(String?, Bool, Bool, Bool)>((nil, false, false, false))
    func load() throws -> String? {
        accesses.withLock { $0 += 1 }
        return try state.withLock { state in
            if state.1 { throw KeychainTokenStore.StoreError(status: -25308) }
            return state.0
        }
    }
    func save(_ token: String) throws {
        accesses.withLock { $0 += 1 }
        try state.withLock { state in
            if state.3 { throw KeychainTokenStore.StoreError(status: -34018) }
            state.0 = token
        }
    }
    func delete() throws {
        accesses.withLock { $0 += 1 }
        try state.withLock { state in
            if state.2 { throw KeychainTokenStore.StoreError(status: -25308) }
            state.0 = nil
        }
    }
    func setUnavailable(_ value: Bool) { state.withLock { $0.1 = value } }
    func setSaveFailure(_ value: Bool) { state.withLock { $0.3 = value } }
    func setDeletionFailure(_ value: Bool) { state.withLock { $0.2 = value } }
}

@MainActor private final class TestAuthentication: AppAuthenticating {
    var result = true
    var failure: Error?
    var calls = 0
    var cancellations = 0
    func unlock() async throws -> Bool { calls += 1; if let failure { throw failure }; return result }
    func cancel() { cancellations += 1 }
}

@MainActor final class AuthLifecycleTests: XCTestCase {
    private func settings() -> UserSettings {
        let name = "VoltaAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserSettings(defaults: defaults)
    }
    private func session(_ handler: @escaping StubProtocol.Handler) -> URLSession {
        StubProtocol.handler.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    func testSuccessfulPairPersistsAndRevokeDisconnects() async throws {
        let pair = try DecodingTests.fixture("pair"); let vehicle = try DecodingTests.fixture("vehicle")
        let revoked = Mutex(false)
        let session = session { request in
            if request.url!.path == "/v1/auth/pair" { return (200, pair) }
            if request.url!.path == "/v1/me" { revoked.withLock { $0 = true }; return (204, Data()) }
            return (200, Data("[".utf8) + vehicle + Data("]".utf8))
        }
        let settings = settings(); let store = MemoryTokenStore()
        let model = AppModel(settings: settings, tokenStore: store, session: session)
        await model.pair(serverURL: "https://volta.example", code: "abcd1234", deviceName: "Test")
        XCTAssertEqual(model.pairingState, .paired); XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        XCTAssertEqual(try store.load(), "synthetic-test-token"); XCTAssertEqual(settings.serverURL, "https://volta.example")
        await model.revokeAndUnpair()
        XCTAssertTrue(revoked.withLock { $0 }); XCTAssertFalse(model.isPaired); XCTAssertNil(try store.load())
    }
    func testStaleUnauthorizedCannotClearDemoState() async throws {
        let store = MemoryTokenStore(); try store.save("synthetic-token")
        let settings = settings(); settings.serverURL = "https://volta.example"
        let model = AppModel(settings: settings, tokenStore: store, session: session { _ in (401, Data()) })
        let oldSource = model.dataSource
        model.tryDemoMode(); await model.loadVehicles()
        do { _ = try await oldSource.vehicles(); XCTFail() } catch { XCTAssertEqual(error as? VoltaError, .unauthorized) }
        XCTAssertTrue(model.isDemoMode); XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        XCTAssertEqual(try store.load(), "synthetic-token")
    }
    func testStaleUnauthorizedCannotClearNewPairing() async throws {
        let pair = try DecodingTests.fixture("pair"); let vehicle = try DecodingTests.fixture("vehicle")
        let store = MemoryTokenStore(); try store.save("old-token")
        let settings = settings(); settings.serverURL = "https://volta.example"
        let session = session { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" { return (401, Data()) }
            if request.url!.path == "/v1/auth/pair" { return (200, pair) }
            return (200, Data("[".utf8) + vehicle + Data("]".utf8))
        }
        let model = AppModel(settings: settings, tokenStore: store, session: session)
        let oldSource = model.dataSource
        model.unpair()
        await model.pair(serverURL: "https://volta.example", code: "ABCD1234", deviceName: "Test")
        do { _ = try await oldSource.vehicles(); XCTFail() } catch { XCTAssertEqual(error as? VoltaError, .unauthorized) }
        XCTAssertEqual(model.pairingState, .paired); XCTAssertEqual(try store.load(), "synthetic-test-token")
    }
    func testStalePairIsDiscardedAndOrphanedTokenRevoked() async throws {
        let pairData = try DecodingTests.fixture("pair")
        let started = Mutex(false); let revoked = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let session = session { request in
            if request.url!.path == "/v1/auth/pair" {
                started.withLock { $0 = true }
                guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                return (200, pairData)
            }
            revoked.withLock { $0 = true }; return (204, Data())
        }
        let store = MemoryTokenStore()
        let model = AppModel(settings: settings(), tokenStore: store, session: session)
        let pairing = Task { await model.pair(serverURL: "https://volta.example", code: "ABCD1234", deviceName: "Test") }
        let deadline = Date.now.addingTimeInterval(3)
        while !started.withLock({ $0 }) && Date.now < deadline { await Task.yield() }
        XCTAssertTrue(started.withLock { $0 })
        model.tryDemoMode(); release.signal()
        await pairing.value
        XCTAssertTrue(model.isDemoMode); XCTAssertNil(try store.load()); XCTAssertTrue(revoked.withLock { $0 })
    }
    func testCredentialRetryAndReinstallWithoutServer() throws {
        let store = MemoryTokenStore(); try store.save("synthetic-token"); store.setUnavailable(true)
        let settings = settings(); settings.serverURL = "https://volta.example"
        let model = AppModel(settings: settings, tokenStore: store)
        XCTAssertTrue(model.needsCredentialRetry); XCTAssertFalse(model.isPaired)
        store.setUnavailable(false); model.restorePairing()
        XCTAssertTrue(model.isPaired); XCTAssertFalse(model.needsCredentialRetry)
        settings.serverURL = ""
        let reinstalled = AppModel(settings: settings, tokenStore: store)
        XCTAssertFalse(reinstalled.isPaired); XCTAssertNil(reinstalled.errorMessage)
    }
    func testLockEnableRequiresAuthenticationAndRecoveryRemovesToken() async throws {
        let store = MemoryTokenStore(); try store.save("synthetic-token")
        let settings = settings(); settings.serverURL = "https://volta.example"
        let auth = TestAuthentication(); auth.failure = VoltaError.transport("No system authentication available")
        let model = AppModel(settings: settings, tokenStore: store, appLock: auth)
        await model.setAppLockEnabled(true)
        XCTAssertFalse(model.appLockEnabled); XCTAssertNotNil(model.errorMessage)
        auth.failure = nil
        await model.setAppLockEnabled(true)
        XCTAssertTrue(model.appLockEnabled); XCTAssertFalse(model.isLocked)
        model.lock(); XCTAssertTrue(model.isLocked)
        auth.failure = VoltaError.transport("Passcode removed")
        await model.unlock(); XCTAssertTrue(model.isLocked)
        model.disconnectLockedDevice()
        XCTAssertFalse(model.isPaired); XCTAssertNil(try store.load()); XCTAssertFalse(model.appLockEnabled)
    }
    func testFailedKeychainDeleteCannotDisableLockOrRestoreEndpoint() throws {
        let store = MemoryTokenStore(); try store.save("synthetic-token"); store.setDeletionFailure(true)
        let settings = settings(); settings.serverURL = "https://volta.example"; settings.appLockEnabled = true
        let model = AppModel(settings: settings, tokenStore: store, appLock: TestAuthentication())
        model.disconnectLockedDevice()
        XCTAssertTrue(settings.appLockEnabled); XCTAssertEqual(settings.serverURL, "")
        XCTAssertFalse(AppModel(settings: settings, tokenStore: store).isPaired)
    }
    func testUnlockRetainsLoadedVehiclesAndEmptyDemoPersists() async throws {
        let settings = settings(); let auth = TestAuthentication()
        let model = AppModel(settings: settings, tokenStore: MemoryTokenStore(), appLock: auth)
        model.tryDemoMode(empty: true); await model.loadVehicles()
        let vehicles = model.vehicles
        await model.setAppLockEnabled(true); model.lock(); await model.unlock()
        XCTAssertFalse(model.isLocked); XCTAssertEqual(model.vehicles, vehicles)
        let restored = AppModel(settings: settings, tokenStore: MemoryTokenStore(), appLock: auth)
        let drives = try await restored.dataSource.drives(vehicleID: 1, range: .init(), cursor: nil)
        XCTAssertTrue(drives.items.isEmpty)
    }
    func testCancelledAuthenticationDoesNotRepromptWhenActiveAgain() async {
        let settings = settings(); let auth = TestAuthentication(); auth.result = false
        let model = AppModel(settings: settings, tokenStore: MemoryTokenStore(), appLock: auth)
        model.tryDemoMode(); await model.loadVehicles()
        settings.appLockEnabled = true
        model.didEnterBackground(); await model.becameActive()
        XCTAssertTrue(model.isLocked); XCTAssertEqual(auth.calls, 1)
        // The system sheet's inactive -> active transition must leave Cancel effective.
        await model.becameActive(); await model.becameActive()
        XCTAssertTrue(model.isLocked); XCTAssertEqual(auth.calls, 1)
        await model.unlock(); XCTAssertEqual(auth.calls, 2)
        model.didEnterBackground(); await model.becameActive()
        XCTAssertEqual(auth.calls, 3)
    }
    func testKeychainSaveFailureRevokesIssuedToken() async throws {
        let pair = try DecodingTests.fixture("pair"); let revoked = Mutex(false)
        let session = session { request in
            if request.url!.path == "/v1/auth/pair" { return (200, pair) }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
            revoked.withLock { $0 = true }; return (204, Data())
        }
        let store = MemoryTokenStore(); store.setSaveFailure(true)
        let settings = settings()
        let model = AppModel(settings: settings, tokenStore: store, session: session)
        await model.pair(serverURL: "https://volta.example", code: "ABCD1234", deviceName: "Test")
        XCTAssertFalse(model.isPaired); XCTAssertNil(try store.load()); XCTAssertTrue(revoked.withLock { $0 })
        XCTAssertEqual(settings.serverURL, ""); XCTAssertNotNil(model.errorMessage)
    }

    func testDemoLaunchArgumentSkipsPairingAndKeychainAccess() async throws {
        let settings = settings(); settings.selectedVehicleID = 42
        let store = MemoryTokenStore(); store.setUnavailable(true)
        let model = AppModel(settings: settings, tokenStore: store, launchArguments: ["Volta", "-demo-mode", "YES"])
        XCTAssertTrue(model.isDemoMode); XCTAssertFalse(model.needsCredentialRetry)
        XCTAssertNil(model.errorMessage); XCTAssertFalse(settings.demoMode)
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicle?.name, "Friday"); XCTAssertEqual(model.selectedVehicleID, 1)
        XCTAssertEqual(settings.selectedVehicleID, 42)
        let drives = try await model.dataSource.drives(vehicleID: 1, range: .init(), cursor: nil)
        XCTAssertFalse(drives.items.isEmpty)
        let normal = AppModel(settings: settings, tokenStore: store, launchArguments: ["Volta", "-demo-mode", "NO"])
        XCTAssertFalse(normal.isDemoMode); XCTAssertTrue(normal.needsCredentialRetry)
    }

    func testLaunchDemoIsolatesSavedSettingsLockCredentialsAndNetwork() async throws {
        let settings = settings(); settings.serverURL = "https://volta.example"
        settings.selectedVehicleID = 42; settings.appLockEnabled = true
        settings.demoMode = true; settings.emptyDemo = true
        settings.units = .init(distance: .kilometers, temperature: .celsius, currency: "EUR")
        let store = MemoryTokenStore(); try store.save("saved-real-token")
        let initialAccesses = store.accesses.withLock { $0 }
        let requests = Mutex(0)
        let session = session { _ in
            requests.withLock { $0 += 1 }
            return (500, Data())
        }
        let auth = TestAuthentication()
        let model = AppModel(settings: settings, tokenStore: store, session: session, appLock: auth, launchArguments: ["Volta", "-demo-mode", "YES"])
        XCTAssertTrue(model.isLaunchDemo); XCTAssertFalse(model.isLocked)
        XCTAssertFalse(model.appLockEnabled); XCTAssertEqual(model.units, .default)
        XCTAssertFalse(model.settings.demoMode); XCTAssertEqual(model.settings.serverURL, "")
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 1); XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        model.didEnterBackground(); await model.becameActive()
        await model.setAppLockEnabled(true); await model.unlock()
        XCTAssertFalse(model.isLocked); XCTAssertEqual(auth.calls, 0)
        model.units = .init(distance: .miles, temperature: .fahrenheit, currency: "GBP")
        model.unpair(); model.restorePairing()
        await model.pair(serverURL: settings.serverURL, code: "ABCD1234", deviceName: "Demo")
        XCTAssertTrue(model.isLaunchDemo); XCTAssertFalse(model.isPaired)
        model.tryDemoMode(); await model.loadVehicles()
        XCTAssertTrue(model.isDemoMode); XCTAssertFalse(model.isLocked)
        XCTAssertEqual(store.accesses.withLock { $0 }, initialAccesses)
        XCTAssertEqual(requests.withLock { $0 }, 0)
        XCTAssertEqual(try store.load(), "saved-real-token")
        XCTAssertEqual(settings.selectedVehicleID, 42); XCTAssertEqual(settings.serverURL, "https://volta.example")
        XCTAssertTrue(settings.appLockEnabled); XCTAssertTrue(settings.demoMode); XCTAssertTrue(settings.emptyDemo)
        XCTAssertEqual(settings.units.currency, "EUR")
        let freshLaunch = AppModel(settings: settings, tokenStore: store, launchArguments: ["Volta", "-demo-mode", "YES"])
        XCTAssertEqual(freshLaunch.units, .default)
    }

}
