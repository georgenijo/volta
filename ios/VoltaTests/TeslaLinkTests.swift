import XCTest
import Synchronization
@testable import Volta

/// Synthetic values only; asserted never to surface in any message.
private let syntheticCallback = URL(string: "volta://tesla-callback?code=SYNTHETIC-CODE-123&state=SYNTHETIC-STATE-456")!
private let authorizationURL = URL(string: "https://auth.tesla.com/oauth2/v3/authorize?client_id=synthetic&state=SYNTHETIC-STATE-456")!

private func status(available: Bool = true, connected: Bool = false, needsReauth: Bool = false, paused: Bool = false) -> TeslaStatus {
    TeslaStatus(available: available, connected: connected, needsReauth: needsReauth, linkPending: false,
                collector: .init(enabled: connected), budget: .init(monthlyLimitUsd: 10, spentUsd: 2.5, paused: paused))
}

private final class FakeTeslaClient: TeslaAccountClient, Sendable {
    struct Calls: Equatable { var status = 0, start = 0, cancel = 0, disconnect = 0; var completed: [URL] = [] }
    private let state = Mutex<(calls: Calls, status: [Result<TeslaStatus, any Error>], start: Result<TeslaLinkStart, any Error>, complete: [Result<TeslaStatus, any Error>], disconnect: (any Error)?)>(
        (Calls(), [], .success(TeslaLinkStart(authorizationUrl: authorizationURL, callbackScheme: "volta", expiresAt: .now.addingTimeInterval(600))), [], nil))
    var calls: Calls { state.withLock { $0.calls } }
    /// The last scripted status repeats.
    func setStatus(_ results: Result<TeslaStatus, any Error>...) { state.withLock { $0.status = results } }
    func setStart(_ result: Result<TeslaLinkStart, any Error>) { state.withLock { $0.start = result } }
    func setComplete(_ results: Result<TeslaStatus, any Error>...) { state.withLock { $0.complete = results } }
    func setDisconnectError(_ error: (any Error)?) { state.withLock { $0.disconnect = error } }

    private let held = Mutex<(next: TeslaStatus?, waiter: CheckedContinuation<Void, Never>?)>((nil, nil))
    /// The next status call answers `value`, but only after `releaseStatus()`:
    /// a response that was true when sent and arrives late.
    func holdNextStatus(returning value: TeslaStatus) { held.withLock { $0.next = value } }
    var isHoldingStatus: Bool { held.withLock { $0.waiter != nil } }
    func releaseStatus() { held.withLock { h in h.waiter?.resume(); h.waiter = nil } }

    func teslaStatus() async throws -> TeslaStatus {
        if let value = held.withLock({ h in defer { h.next = nil }; return h.next }) {
            state.withLock { $0.calls.status += 1 }
            await withCheckedContinuation { c in held.withLock { $0.waiter = c } }
            return value
        }
        return try state.withLock { s in
            s.calls.status += 1
            let next = s.status.count > 1 ? s.status.removeFirst() : (s.status.first ?? .success(status()))
            return try next.get()
        }
    }
    func startTeslaLink() async throws -> TeslaLinkStart { try state.withLock { $0.calls.start += 1; return try $0.start.get() } }
    func completeTeslaLink(callbackURL: URL) async throws -> TeslaStatus {
        try state.withLock { s in
            s.calls.completed.append(callbackURL)
            let next = s.complete.count > 1 ? s.complete.removeFirst() : (s.complete.first ?? .success(status(connected: true)))
            return try next.get()
        }
    }
    func cancelTeslaLink() async throws { state.withLock { $0.calls.cancel += 1 } }
    func disconnectTesla() async throws {
        try state.withLock { s in
            s.calls.disconnect += 1
            if let error = s.disconnect { throw error }
        }
    }
}

@MainActor private final class FakeWebAuth: TeslaWebAuthenticating {
    var result: Result<URL, any Error> = .success(syntheticCallback)
    var requests: [(url: URL, scheme: String)] = []
    var holds = false
    private var held: CheckedContinuation<URL, any Error>?
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        requests.append((url, callbackScheme))
        if holds { return try await withCheckedThrowingContinuation { held = $0 } }
        return try result.get()
    }
    func release() { held?.resume(with: result); held = nil }
}

@MainActor final class TeslaLinkModelTests: XCTestCase {
    private func makeModel(_ client: FakeTeslaClient, web: FakeWebAuth = FakeWebAuth()) async -> TeslaLinkModel {
        let model = TeslaLinkModel(webAuth: web, retryDelays: [.zero, .zero, .zero])
        model.setClient(client)
        await model.refresh()
        return model
    }
    private func assertNoSecrets(_ model: TeslaLinkModel, file: StaticString = #filePath, line: UInt = #line) {
        let text = [model.failureMessage, model.disconnectError].compactMap { $0 }.joined()
        XCTAssertFalse(text.contains("SYNTHETIC"), "Callback values leaked into a message", file: file, line: line)
        XCTAssertFalse(text.contains("tesla-callback"), file: file, line: line)
    }

    func testSuccessCompletesWithCallbackAndReloadsVehicles() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status()), .success(status(connected: true)))
        let web = FakeWebAuth()
        let model = await makeModel(client, web: web)
        XCTAssertEqual(model.state, .disconnected)
        var connectedCalls = 0
        model.onConnected = { connectedCalls += 1 }
        model.start(); await model.waitForFlow()
        XCTAssertEqual(web.requests.map(\.url), [authorizationURL])
        XCTAssertEqual(web.requests.map(\.scheme), ["volta"])
        XCTAssertEqual(client.calls.completed, [syntheticCallback])
        XCTAssertEqual(client.calls.status, 2, "status refreshes after completion")
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(connectedCalls, 1)
    }

    func testUserCancelCancelsPendingLinkWithoutError() async {
        let client = FakeTeslaClient(); let web = FakeWebAuth(); web.result = .failure(TeslaWebAuthError.cancelled)
        let model = await makeModel(client, web: web)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(client.calls.cancel, 1)
        XCTAssertTrue(client.calls.completed.isEmpty)
        XCTAssertEqual(model.state, .disconnected)
        XCTAssertNil(model.failureMessage)
    }

    func testCancelReturnsToNeedsReauth() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status(connected: true, needsReauth: true)))
        let web = FakeWebAuth(); web.result = .failure(CancellationError())
        let model = await makeModel(client, web: web)
        XCTAssertEqual(model.state, .needsReauth)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(model.state, .needsReauth); XCTAssertEqual(client.calls.cancel, 1)
    }

    func testDeniedAndExpiredFailWithoutLeakingCallback() async {
        for code in ["tesla_link_denied", "tesla_link_invalid", "tesla_link_device_mismatch", "tesla_link_failed"] {
            let client = FakeTeslaClient()
            client.setComplete(.failure(VoltaError.server(code: code, message: "bad code=SYNTHETIC-CODE-123 state=SYNTHETIC-STATE-456")))
            let model = await makeModel(client)
            model.start(); await model.waitForFlow()
            guard case .failed(let message, let retryable) = model.state else { return XCTFail("Expected failure for \(code)") }
            XCTAssertFalse(retryable, code); XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(client.calls.completed.count, 1, "\(code) is not retried")
            assertNoSecrets(model)
            // Starting again requests a fresh link rather than replaying the callback.
            client.setComplete(.success(status(connected: true))); client.setStatus(.success(status(connected: true)))
            model.retry(); await model.waitForFlow()
            XCTAssertEqual(client.calls.start, 2, code)
            XCTAssertEqual(client.calls.completed.count, 2, "\(code): the spent callback is never resent")
            XCTAssertEqual(model.state, .connected, code)
        }
    }

    func testUnavailableRetriesSameCallbackThenSucceeds() async {
        let client = FakeTeslaClient()
        let unavailable = VoltaError.server(code: "tesla_unavailable", message: "SYNTHETIC-CODE-123")
        client.setComplete(.failure(unavailable), .failure(unavailable), .success(status(connected: true)))
        client.setStatus(.success(status()), .success(status(connected: true)))
        let model = await makeModel(client)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(client.calls.completed, [syntheticCallback, syntheticCallback, syntheticCallback])
        XCTAssertEqual(client.calls.start, 1)
        XCTAssertEqual(model.state, .connected)
    }

    func testUnavailableExhaustedIsRetryableWithSameCallback() async {
        let client = FakeTeslaClient()
        let unavailable = VoltaError.server(code: "tesla_unavailable", message: "SYNTHETIC-STATE-456")
        client.setComplete(.failure(unavailable), .failure(unavailable), .failure(unavailable), .failure(unavailable), .success(status(connected: true)))
        let model = await makeModel(client)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(client.calls.completed.count, 4, "one attempt plus three retries")
        guard case .failed(_, true) = model.state else { return XCTFail("Expected retryable failure") }
        assertNoSecrets(model)
        client.setStatus(.success(status(connected: true)))
        model.retry(); await model.waitForFlow()
        XCTAssertEqual(client.calls.completed.count, 5); XCTAssertEqual(Set(client.calls.completed), [syntheticCallback])
        XCTAssertEqual(client.calls.start, 1, "retry reuses the callback instead of a new link")
        XCTAssertEqual(model.state, .connected)
    }

    func testWrongCallbackRejectedWithoutNetwork() async {
        for callback in ["https://tesla-callback/?code=SYNTHETIC-CODE-123", "volta://elsewhere?code=SYNTHETIC-CODE-123&state=SYNTHETIC-STATE-456"] {
            let client = FakeTeslaClient(); let web = FakeWebAuth(); web.result = .success(URL(string: callback)!)
            let model = await makeModel(client, web: web)
            let before = client.calls
            model.start(); await model.waitForFlow()
            XCTAssertTrue(client.calls.completed.isEmpty, callback)
            XCTAssertEqual(client.calls.status, before.status); XCTAssertEqual(client.calls.cancel, 0)
            guard case .failed = model.state else { return XCTFail("Expected failure") }
            assertNoSecrets(model)
        }
    }

    func testInvalidAuthorizationLinkNeverOpens() async {
        for (url, scheme) in [("http://auth.tesla.com/authorize", "volta"), ("https://auth.tesla.com/authorize", "evil")] {
            let client = FakeTeslaClient(); let web = FakeWebAuth()
            client.setStart(.success(TeslaLinkStart(authorizationUrl: URL(string: url)!, callbackScheme: scheme, expiresAt: .now)))
            let model = await makeModel(client, web: web)
            model.start(); await model.waitForFlow()
            XCTAssertTrue(web.requests.isEmpty, url)
            guard case .failed(_, false) = model.state else { return XCTFail("Expected failure") }
        }
    }

    func testNotAvailableStates() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status(available: false)))
        let model = await makeModel(client)
        XCTAssertEqual(model.state, .notAvailable); XCTAssertFalse(model.canSignIn)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(client.calls.start, 0)

        let old = FakeTeslaClient(); old.setStatus(.failure(VoltaError.notFound))
        let oldModel = await makeModel(old)
        XCTAssertEqual(oldModel.state, .notAvailable, "servers without Tesla routes")

        let unconfigured = FakeTeslaClient(); unconfigured.setStart(.failure(VoltaError.server(code: "tesla_link_unavailable", message: "")))
        let unconfiguredModel = await makeModel(unconfigured)
        unconfiguredModel.start(); await unconfiguredModel.waitForFlow()
        XCTAssertEqual(unconfiguredModel.state, .notAvailable)
    }

    func testAlreadyConnectedRefreshesStatus() async {
        let client = FakeTeslaClient()
        client.setStatus(.success(status()), .success(status(connected: true)))
        client.setStart(.failure(VoltaError.server(code: "tesla_already_connected", message: "")))
        let model = await makeModel(client)
        model.start(); await model.waitForFlow()
        XCTAssertEqual(model.state, .connected)
        XCTAssertFalse(model.isBusy, "reconciling leaves the sign-in flow")
        XCTAssertEqual(client.calls.status, 2)
        XCTAssertTrue(client.calls.completed.isEmpty)
    }

    private func waitForHeldStatus(_ client: FakeTeslaClient) async {
        let deadline = Date.now.addingTimeInterval(3)
        while !client.isHoldingStatus && Date.now < deadline { await Task.yield() }
        XCTAssertTrue(client.isHoldingStatus)
    }

    func testLateStatusCannotUndoDisconnect() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status(connected: true)))
        let model = await makeModel(client)
        client.holdNextStatus(returning: status(connected: true))
        let refresh = Task { await model.refresh() }
        await waitForHeldStatus(client)
        client.setStatus(.success(status()))
        await model.disconnect()
        XCTAssertEqual(model.state, .disconnected)
        client.releaseStatus(); await refresh.value
        XCTAssertEqual(model.state, .disconnected, "a status sent before disconnect arrived after it")
        XCTAssertEqual(model.status?.connected, false)
    }

    func testLateStatusCannotUndoSignIn() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status()))
        let model = await makeModel(client)
        client.holdNextStatus(returning: status())
        let refresh = Task { await model.refresh() }
        await waitForHeldStatus(client)
        client.setStatus(.success(status(connected: true)))
        model.start(); await model.waitForFlow()
        XCTAssertEqual(model.state, .connected)
        client.releaseStatus(); await refresh.value
        XCTAssertEqual(model.state, .connected, "a status sent before sign-in arrived after it")
    }

    func testDoubleStartIgnored() async {
        let client = FakeTeslaClient(); let web = FakeWebAuth(); web.holds = true
        let model = await makeModel(client, web: web)
        model.start(); model.start()
        let deadline = Date.now.addingTimeInterval(3)
        while web.requests.isEmpty && Date.now < deadline { await Task.yield() }
        XCTAssertEqual(model.state, .awaitingTesla)
        model.start(); model.retry()
        await model.refresh()
        XCTAssertEqual(model.state, .awaitingTesla, "a refresh cannot clobber a running flow")
        web.release(); await model.waitForFlow()
        XCTAssertEqual(client.calls.start, 1); XCTAssertEqual(web.requests.count, 1)
        XCTAssertEqual(client.calls.completed.count, 1)
    }

    func testForegroundRefreshShowsServerState() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status()), .success(status(connected: true, paused: true)))
        let model = await makeModel(client)
        XCTAssertEqual(model.state, .disconnected)
        await model.refresh()
        XCTAssertEqual(model.state, .connected); XCTAssertEqual(model.status?.budget?.paused, true)
        // A failed background refresh keeps the last known state.
        client.setStatus(.failure(VoltaError.transport("offline")))
        await model.refresh()
        XCTAssertEqual(model.state, .connected)
    }

    func testStatusFailureRetriesStatusNotSignIn() async {
        let client = FakeTeslaClient(); client.setStatus(.failure(VoltaError.transport("offline")), .success(status()))
        let model = await makeModel(client)
        guard case .failed(_, true) = model.state else { return XCTFail("Expected retryable failure") }
        model.retry(); await model.waitForFlow()
        XCTAssertEqual(model.state, .disconnected); XCTAssertEqual(client.calls.start, 0)
    }

    func testDisconnect() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status(connected: true)), .success(status()))
        let model = await makeModel(client)
        await model.disconnect()
        XCTAssertEqual(client.calls.disconnect, 1); XCTAssertEqual(model.state, .disconnected)
        client.setStatus(.success(status(connected: true)))
        await model.refresh()
        client.setDisconnectError(VoltaError.server(code: "tesla_unavailable", message: "SYNTHETIC-CODE-123"))
        await model.disconnect()
        XCTAssertEqual(model.state, .connected); XCTAssertNotNil(model.disconnectError)
        assertNoSecrets(model)
    }

    func testFailedReconcileCannotUndoDisconnect() async {
        let client = FakeTeslaClient(); client.setStatus(.success(status(connected: true)))
        let model = await makeModel(client)
        XCTAssertEqual(model.state, .connected)
        client.setStatus(.failure(VoltaError.server(code: "http_503", message: "")))
        await model.disconnect()
        XCTAssertEqual(client.calls.disconnect, 1)
        XCTAssertEqual(model.state, .disconnected, "a failed status read restored the old account")
        XCTAssertEqual(model.status?.connected, false)
        XCTAssertTrue(model.canSignIn); XCTAssertNil(model.disconnectError)
        await model.refresh()
        XCTAssertEqual(model.state, .disconnected)
    }

    func testClientChangeCancelsRunningFlow() async {
        let client = FakeTeslaClient(); let web = FakeWebAuth(); web.holds = true
        let model = await makeModel(client, web: web)
        model.start()
        let deadline = Date.now.addingTimeInterval(3)
        while web.requests.isEmpty && Date.now < deadline { await Task.yield() }
        model.setClient(nil)
        XCTAssertEqual(model.state, .idle)
        web.release(); await Task.yield()
        XCTAssertEqual(model.state, .idle); XCTAssertTrue(client.calls.completed.isEmpty)
    }

    func testDemoModeNeverContactsTesla() async {
        let web = FakeWebAuth()
        let model = TeslaLinkModel(webAuth: web, retryDelays: [])
        model.setClient(MockDataSource())
        await model.refresh()
        XCTAssertEqual(model.state, .disconnected)
        model.start(); await model.waitForFlow()
        XCTAssertTrue(web.requests.isEmpty)
        guard case .failed(let message, false) = model.state else { return XCTFail("Expected demo failure") }
        XCTAssertTrue(message.contains("Demo mode"))
    }
}

@MainActor final class TeslaAccountAPITests: XCTestCase {
    private struct Seen: Sendable { let method: String; let path: String; let auth: String?; let contentType: String?; let body: Data }
    private func source(_ handler: @escaping StubProtocol.Handler, unauthorized: @escaping @Sendable () async -> Void = {}) -> APIDataSource {
        StubProtocol.handler.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-token", session: URLSession(configuration: config), onUnauthorized: unauthorized)
    }
    nonisolated private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
    nonisolated private static let statusJSON = Data(#"{"available":true,"connected":true,"needsReauth":false,"linkPending":false,"collector":{"enabled":true},"budget":{"monthlyLimitUsd":10,"spentUsd":2.5,"paused":false}}"#.utf8)

    func testRequestShapes() async throws {
        let seen = Mutex<[Seen]>([])
        let api = source { request in
            seen.withLock { $0.append(Seen(method: request.httpMethod ?? "", path: request.url!.path, auth: request.value(forHTTPHeaderField: "Authorization"),
                                           contentType: request.value(forHTTPHeaderField: "Content-Type"), body: Self.body(request))) }
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/v1/tesla/link"):
                return (200, Data(#"{"authorizationUrl":"https://auth.tesla.com/oauth2/v3/authorize?x=1","callbackScheme":"volta","expiresAt":"2026-10-07T12:00:00Z"}"#.utf8))
            case ("DELETE", _): return (204, Data())
            default: return (200, Self.statusJSON)
            }
        }
        let status = try await api.teslaStatus()
        XCTAssertEqual(status, TeslaStatus(available: true, connected: true, needsReauth: false, linkPending: false, collector: .init(enabled: true), budget: .init(monthlyLimitUsd: 10, spentUsd: 2.5, paused: false)))
        let link = try await api.startTeslaLink()
        XCTAssertEqual(link.authorizationUrl.host, "auth.tesla.com"); XCTAssertEqual(link.callbackScheme, "volta")
        let completed = try await api.completeTeslaLink(callbackURL: syntheticCallback)
        XCTAssertTrue(completed.connected)
        try await api.cancelTeslaLink()
        try await api.disconnectTesla()

        let requests = seen.withLock { $0 }
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /v1/tesla/status", "POST /v1/tesla/link", "POST /v1/tesla/link/complete", "DELETE /v1/tesla/link", "DELETE /v1/tesla/account",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.auth == "Bearer synthetic-token" })
        XCTAssertEqual(requests[1].contentType, "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[1].body) as? [String: String], [:])
        XCTAssertEqual(requests[2].contentType, "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[2].body) as? [String: String], ["callbackUrl": syntheticCallback.absoluteString])
        XCTAssertTrue([0, 3, 4].allSatisfy { requests[$0].body.isEmpty && requests[$0].contentType == nil })
    }

    func testErrorMapping() async {
        func error(_ status: Int, _ code: String, _ call: (APIDataSource) async throws -> Void) async -> VoltaError? {
            let api = source { _ in (status, Data(#"{"error":{"code":"\#(code)","message":"msg"}}"#.utf8)) }
            do { try await call(api); XCTFail("Expected error"); return nil } catch { return error as? VoltaError }
        }
        let cases: [(Int, String)] = [(501, "tesla_link_unavailable"), (409, "tesla_already_connected"), (503, "tesla_unavailable")]
        for (status, code) in cases {
            let mapped = await error(status, code) { _ = try await $0.startTeslaLink() }
            XCTAssertEqual(mapped, .server(code: code, message: "msg"))
        }
        for (status, code) in [(400, "tesla_link_invalid"), (400, "tesla_link_denied"), (400, "tesla_link_failed"), (409, "tesla_link_device_mismatch"), (503, "tesla_unavailable")] {
            let mapped = await error(status, code) { _ = try await $0.completeTeslaLink(callbackURL: syntheticCallback) }
            XCTAssertEqual(mapped, .server(code: code, message: "msg"))
        }
        let notFound = await error(404, "not_found") { _ = try await $0.teslaStatus() }
        XCTAssertEqual(notFound, .notFound)

        let notified = Mutex(false)
        let api = source({ _ in (401, Data()) }, unauthorized: { notified.withLock { $0 = true } })
        do { try await api.disconnectTesla(); XCTFail() } catch { XCTAssertEqual(error as? VoltaError, .unauthorized) }
        XCTAssertTrue(notified.withLock { $0 })
    }

    func testTeslaErrorCopyNeverEchoesServer() {
        for code in ["tesla_link_denied", "tesla_link_invalid", "tesla_link_failed", "tesla_link_device_mismatch", "tesla_unavailable", "other"] {
            let message = TeslaLinkModel.describe(VoltaError.server(code: code, message: "code=SYNTHETIC-CODE-123")).message
            XCTAssertFalse(message.contains("SYNTHETIC"), code)
        }
    }

    /// AppModel wiring: a paired API source drives the Tesla model; unpair resets it.
    func testAppModelFollowsPairing() async throws {
        let name = "VoltaTeslaTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let settings = UserSettings(defaults: defaults); settings.serverURL = "https://volta.example"
        StubProtocol.handler.withLock { $0 = { _ in (200, Self.statusJSON) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let model = AppModel(settings: settings, tokenStore: StaticTokenStore(), session: URLSession(configuration: config), teslaWebAuth: FakeWebAuth())
        XCTAssertTrue(model.isPaired)
        await model.refreshTesla()
        XCTAssertEqual(model.tesla.state, .connected)
        model.unpair()
        XCTAssertEqual(model.tesla.state, .idle); XCTAssertNil(model.tesla.status)
        await model.refreshTesla()
        XCTAssertEqual(model.tesla.state, .idle, "unpaired devices never query Tesla status")
    }
}

private final class StaticTokenStore: TokenStoring, Sendable {
    private let token = Mutex<String?>("synthetic-token")
    func load() throws -> String? { token.withLock { $0 } }
    func save(_ value: String) throws { token.withLock { $0 = value } }
    func delete() throws { token.withLock { $0 = nil } }
}
