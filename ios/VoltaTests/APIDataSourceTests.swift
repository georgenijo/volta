import XCTest
import Synchronization
@testable import Volta

final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let handler = Mutex<Handler?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.handler.withLock { $0 }
            let (status, data) = try XCTUnwrap(callback)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor final class APIDataSourceTests: XCTestCase {
    private func source(handler: @escaping StubProtocol.Handler, unauthorized: @escaping @Sendable () async -> Void = {}) -> APIDataSource {
        StubProtocol.handler.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-token", session: URLSession(configuration: config), onUnauthorized: unauthorized)
    }
    private func expectError(_ expected: VoltaError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected error") }
        catch { XCTAssertEqual(error as? VoltaError, expected) }
    }
    func testBearerAndCursorQuery() async throws {
        let page = try DecodingTests.fixture("drivePage")
        let api = source { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            XCTAssertEqual(request.url?.path, "/v1/vehicles/1/drives")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "cursor" }?.value, "opaque+cursor/=")
            XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "100")
            XCTAssertNotNil(query.first { $0.name == "from" })
            return (200, page)
        }
        let result = try await api.drives(vehicleID: 1, range: DateRange(from: .now, to: nil), cursor: "opaque+cursor/=")
        XCTAssertEqual(result.items.count, 1)
    }
    func testSummarySendsDeviceTimeZone() async throws {
        let data = try DecodingTests.fixture("summary")
        let expected = APIDataSource.summaryTimeZone()
        XCTAssertEqual(expected, TimeZone.knownTimeZoneIdentifiers.contains(TimeZone.current.identifier) ? TimeZone.current.identifier : nil)
        for range in SummaryRange.allCases {
            let api = source { request in
                XCTAssertEqual(request.url?.path, "/v1/vehicles/1/summary")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "range" }?.value, range.rawValue)
                XCTAssertEqual(query.first { $0.name == "tz" }?.value, expected)
                return (200, data)
            }
            _ = try await api.summary(vehicleID: 1, range: range)
        }
        XCTAssertEqual(APIDataSource.summaryTimeZone(try XCTUnwrap(TimeZone(identifier: "America/New_York"))), "America/New_York")
        XCTAssertNil(APIDataSource.summaryTimeZone(try XCTUnwrap(TimeZone(secondsFromGMT: 3600))), "fixed offsets are not IANA names")
    }
    func testUnauthorizedNotifiesUnpair() async {
        let notified = Mutex(false)
        let api = source(handler: { _ in (401, Data()) }, unauthorized: { notified.withLock { $0 = true } })
        await expectError(.unauthorized) { _ = try await api.vehicles() }
        XCTAssertTrue(notified.withLock { $0 })
    }
    func testErrorMapping() async {
        let notFound = source { _ in (404, Data()) }
        await expectError(.notFound) { _ = try await notFound.drive(id: 999) }
        let server = source { _ in (503, Data(#"{"error":{"code":"database_unavailable","message":"Try later"}}"#.utf8)) }
        await expectError(.server(code: "database_unavailable", message: "Try later")) { _ = try await server.vehicles() }
        let fallback = source { _ in (502, Data("not JSON".utf8)) }
        await expectError(.server(code: "http_502", message: "The server returned HTTP 502.")) { _ = try await fallback.vehicles() }
        let transport = source { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await transport.vehicles(); XCTFail() } catch { guard case .transport = error as? VoltaError else { return XCTFail("Expected transport") } }
        let malformed = source { _ in (200, Data("{}".utf8)) }
        await expectError(.transport("The server response could not be decoded.")) { _ = try await malformed.vehicles() }
    }
    func testPairAndRevoke() async throws {
        let data = try DecodingTests.fixture("pair")
        let api = source { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/auth/pair")
            return (200, data)
        }
        // Reuse the stub configuration for the unauthenticated static pairing client.
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let result = try await APIDataSource.pair(baseURL: api.baseURL, code: "ABCD1234", deviceName: "Test", session: URLSession(configuration: config))
        XCTAssertEqual(result.device.id, 1)
        let revoke = source { request in XCTAssertEqual(request.httpMethod, "DELETE"); return (204, Data()) }
        try await revoke.revoke()
    }
    func testHealthAndCommands() async throws {
        let data = try DecodingTests.fixture("health")
        let api = source { request in XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); return (200, data) }
        let health = try await api.health()
        XCTAssertTrue(health.ok)
        await expectError(.commandsUnavailable) { try await api.command(vehicleID: 1, name: "unlock", params: [:]) }
    }
    func testCancellationPreserved() async {
        let api = source { _ in throw URLError(.cancelled) }
        do { _ = try await api.vehicles(); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testHTTPSValidation() throws {
        XCTAssertEqual(try APIDataSource.validatedServerURL(" https://volta.example/ ").host, "volta.example")
        for input in ["http://volta.example", "https://user:pass@volta.example", "https://volta.example/v1", "https://volta.example?token=x", "https://volta.example#x"] { XCTAssertThrowsError(try APIDataSource.validatedServerURL(input)) }
    }
    func testAuthenticated401ClearsAppModelAndToken() async throws {
        let suite = "VoltaTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = KeychainTokenStore(service: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? store.delete() }
        try store.save("synthetic-token")
        let settings = UserSettings(defaults: defaults); settings.serverURL = "https://volta.example"
        StubProtocol.handler.withLock { $0 = { _ in (401, Data()) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let model = AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config))
        XCTAssertEqual(model.pairingState, .paired)
        await model.loadVehicles()
        XCTAssertEqual(model.pairingState, .unpaired)
        XCTAssertNil(try store.load()); XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }
    func testEveryReadRouteMatchesContract() async throws {
        let routes: [(String, String, @Sendable (APIDataSource) async throws -> Void)] = [
            ("/v1/me", "device", { _ = try await $0.me() }),
            ("/v1/vehicles/1/status", "status", { _ = try await $0.status(vehicleID: 1) }),
            ("/v1/vehicles/1/summary", "summary", { _ = try await $0.summary(vehicleID: 1, range: .sevenDays) }),
            ("/v1/drives/10", "driveDetail", { _ = try await $0.drive(id: 10) }),
            ("/v1/vehicles/1/charges", "chargePage", { _ = try await $0.charges(vehicleID: 1, range: .init(), cursor: nil) }),
            ("/v1/charges/20", "chargeDetail", { _ = try await $0.charge(id: 20) }),
            ("/v1/vehicles/1/idles", "idlePage", { _ = try await $0.idles(vehicleID: 1, range: .init(), cursor: nil) }),
            ("/v1/vehicles/1/battery", "battery", { _ = try await $0.battery(vehicleID: 1) })
        ]
        for (path, fixture, operation) in routes {
            let data = try DecodingTests.fixture(fixture)
            let api = source { request in XCTAssertEqual(request.url?.path, path); return (200, data) }
            try await operation(api)
        }
        let arrays: [(String, String, @Sendable (APIDataSource) async throws -> Void)] = [
            ("/v1/vehicles", "vehicle", { _ = try await $0.vehicles() }),
            ("/v1/vehicles/1/timeline", "timeline", { _ = try await $0.timeline(vehicleID: 1, hours: 48) }),
            ("/v1/vehicles/1/mileage", "mileage", { _ = try await $0.mileage(vehicleID: 1, bucket: .month) }),
            ("/v1/vehicles/1/firmware", "firmware", { _ = try await $0.firmware(vehicleID: 1) }),
            ("/v1/vehicles/1/places", "place", { _ = try await $0.places(vehicleID: 1) })
        ]
        for (path, fixture, operation) in arrays {
            let data = Data("[".utf8) + (try DecodingTests.fixture(fixture)) + Data("]".utf8)
            let api = source { request in XCTAssertEqual(request.url?.path, path); return (200, data) }
            try await operation(api)
        }
    }

    func testInvalidPairingCodePreservesServerMessage() async throws {
        StubProtocol.handler.withLock { $0 = { _ in (401, Data(#"{"error":{"code":"invalid_pairing_code","message":"Pairing code is invalid or expired"}}"#.utf8)) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        await expectError(.server(code: "invalid_pairing_code", message: "Pairing code is invalid or expired")) {
            _ = try await APIDataSource.pair(baseURL: URL(string: "https://volta.example")!, code: "ABCD1234", deviceName: "Test", session: URLSession(configuration: config))
        }
    }

}
