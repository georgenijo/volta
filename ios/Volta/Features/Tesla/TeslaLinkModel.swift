import Foundation
import Observation

/// Sign in with Tesla: ask the server for an authorization URL, open it in an
/// ephemeral web session, and hand the callback URL back. The server owns the
/// code exchange and tokens. Callback URLs live only in memory and never reach
/// logs or user-facing messages.
@MainActor @Observable
final class TeslaLinkModel {
    enum State: Equatable {
        case idle, loading, notAvailable, disconnected, needsReauth
        case starting, awaitingTesla, completing, connected
        case failed(message: String, retryable: Bool)
    }
    static let callbackScheme = "volta"
    static let callbackHost = "tesla-callback"
    static let scopeDisclosure = "Volta requests read-only access to your vehicle data and location. No remote commands are enabled. You sign in on Tesla's page; Volta never sees your Tesla password."

    private(set) var state: State = .idle
    private(set) var status: TeslaStatus?
    private(set) var isDisconnecting = false
    private(set) var disconnectError: String?

    /// A sign-in flow is running; further starts are ignored.
    var isBusy: Bool {
        switch state { case .starting, .awaitingTesla, .completing: true; default: false }
    }
    var canSignIn: Bool {
        switch state { case .disconnected, .needsReauth, .failed: client != nil && !isDisconnecting; default: false }
    }

    @ObservationIgnored private var client: (any TeslaAccountClient)?
    @ObservationIgnored private let webAuth: any TeslaWebAuthenticating
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private var generation = UUID()
    /// Orders status reads: only the newest one applies, and account changes
    /// (sign-in, disconnect) void any read sent before them.
    @ObservationIgnored private var statusRequest = 0
    @ObservationIgnored private var flow: Task<Void, Never>?
    /// Kept only to retry completion after a 503 that never reached Tesla; the
    /// server replays a finished completion and ends a spent one as `tesla_link_failed`.
    @ObservationIgnored private var pendingCallback: URL?
    /// Called after a successful connection (AppModel reloads vehicles).
    @ObservationIgnored var onConnected: (@MainActor () async -> Void)?

    init(webAuth: any TeslaWebAuthenticating, retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) {
        self.webAuth = webAuth
        self.retryDelays = retryDelays
    }

    /// New pairing, demo or unpair: drop all state and cancel a running flow.
    func setClient(_ client: (any TeslaAccountClient)?) {
        generation = UUID(); statusRequest += 1; flow?.cancel(); flow = nil
        self.client = client
        status = nil; pendingCallback = nil
        isDisconnecting = false; disconnectError = nil
        state = .idle
    }

    /// Server state is authoritative: a backgrounded or killed flow recovers here.
    func refresh() async {
        guard client != nil, !isBusy, !isDisconnecting else { return }
        await loadStatus(generation: generation)
    }

    func start() {
        guard canSignIn, let client else { return }
        let current = generation
        statusRequest += 1
        state = .starting; disconnectError = nil; pendingCallback = nil
        flow = Task { await runFlow(client: client, generation: current) }
    }

    /// Retries completion with the same callback after a 503, reloads a failed
    /// status, or starts over.
    func retry() {
        guard case .failed = state, let client, !isDisconnecting else { return }
        let current = generation
        if let callback = pendingCallback {
            statusRequest += 1
            state = .completing
            flow = Task { await complete(client: client, callback: callback, generation: current) }
        } else if status == nil {
            state = .loading
            flow = Task { await loadStatus(generation: current) }
        } else { start() }
    }

    /// Awaits the running flow (tests and callers that need completion).
    func waitForFlow() async { await flow?.value }

    func disconnect() async {
        guard let client, !isBusy, !isDisconnecting else { return }
        let current = generation
        statusRequest += 1
        isDisconnecting = true; disconnectError = nil
        do {
            try await client.disconnectTesla()
            guard current == generation else { return }
            isDisconnecting = false
            // The server dropped the account: a failed reconcile must fall back
            // to this, not to the connected status read before.
            if let old = status {
                status = TeslaStatus(available: old.available, connected: false, needsReauth: false, linkPending: false, collector: old.collector, budget: old.budget)
            }
            state = .disconnected
            await loadStatus(generation: current)
        } catch {
            guard current == generation else { return }
            isDisconnecting = false
            if !(error is CancellationError) { disconnectError = Self.describe(error).message }
        }
    }

    // MARK: Flow

    private func runFlow(client: any TeslaAccountClient, generation current: UUID) async {
        let link: TeslaLinkStart
        do { link = try await client.startTeslaLink() }
        catch { return await handle(error, generation: current) }
        guard current == generation else { return }
        guard link.authorizationUrl.scheme?.lowercased() == "https", link.authorizationUrl.host?.isEmpty == false,
              link.callbackScheme == Self.callbackScheme else {
            try? await client.cancelTeslaLink()
            guard current == generation else { return }
            return fail("Your server returned an invalid Tesla sign-in link.", retryable: false)
        }
        state = .awaitingTesla
        let callback: URL
        do { callback = try await webAuth.authenticate(url: link.authorizationUrl, callbackScheme: Self.callbackScheme) }
        catch {
            guard current == generation else { return }
            // Best effort: let the server forget the pending login before allowing a new one.
            try? await client.cancelTeslaLink()
            guard current == generation else { return }
            if error is CancellationError || error as? TeslaWebAuthError == .cancelled { state = restingState; return }
            return fail("Tesla sign-in couldn't be opened. Try again.", retryable: false)
        }
        guard current == generation else { return }
        // ASWebAuthenticationSession filters by scheme; check the host too. Never sent if wrong.
        guard callback.scheme?.lowercased() == Self.callbackScheme, callback.host?.lowercased() == Self.callbackHost else {
            return fail("Tesla returned an unexpected response. Start again.", retryable: false)
        }
        pendingCallback = callback
        await complete(client: client, callback: callback, generation: current)
    }

    private func complete(client: any TeslaAccountClient, callback: URL, generation current: UUID) async {
        state = .completing
        var attempt = 0
        while true {
            do {
                let status = try await client.completeTeslaLink(callbackURL: callback)
                guard current == generation else { return }
                pendingCallback = nil
                apply(status)
                break
            } catch let error where Self.isRetryable(error) && attempt < retryDelays.count {
                try? await Task.sleep(for: retryDelays[attempt])
                attempt += 1
                guard current == generation, !Task.isCancelled else { return }
            } catch { return await handle(error, generation: current) }
        }
        await loadStatus(generation: current)
        if current == generation, state == .connected { await onConnected?() }
    }

    private func loadStatus(generation current: UUID) async {
        guard let client else { return }
        statusRequest += 1
        let request = statusRequest
        if status == nil, !isBusy { state = .loading }
        do {
            let status = try await client.teslaStatus()
            guard current == generation, request == statusRequest, !isBusy, !isDisconnecting else { return }
            apply(status)
        } catch {
            guard current == generation, request == statusRequest, !isBusy, !isDisconnecting, !(error is CancellationError) else { return }
            if error as? VoltaError == .notFound { state = .notAvailable; return }  // server predates Tesla linking
            // Keep showing the last known state when a background refresh fails.
            if let status { apply(status) } else { state = .failed(message: Self.describe(error).message, retryable: true) }
        }
    }

    private func handle(_ error: any Error, generation current: UUID) async {
        guard current == generation else { return }
        if error is CancellationError { state = restingState; return }
        switch error as? VoltaError {
        case .server(code: "tesla_already_connected", _)?:
            pendingCallback = nil
            // Leave the sign-in flow first, or the reconciling status is ignored.
            state = .loading
            await loadStatus(generation: current)
        case .server(code: "tesla_link_unavailable", _)?, .notFound?:
            pendingCallback = nil
            state = .notAvailable
        default:
            let (message, retryable) = Self.describe(error)
            if !retryable { pendingCallback = nil }
            fail(message, retryable: retryable)
        }
    }

    private func fail(_ message: String, retryable: Bool) {
        state = .failed(message: message, retryable: retryable)
    }

    private func apply(_ status: TeslaStatus) {
        self.status = status
        state = !status.available ? .notAvailable : status.needsReauth ? .needsReauth : status.connected ? .connected : .disconnected
    }

    private var restingState: State { status?.needsReauth == true ? .needsReauth : .disconnected }

    private static func isRetryable(_ error: any Error) -> Bool {
        if case .server(let code, _)? = error as? VoltaError { return code == "tesla_unavailable" || code == "http_503" }
        return false
    }

    /// Fixed copy only: server messages are never echoed, so nothing from the
    /// callback can surface in the UI.
    static func describe(_ error: any Error) -> (message: String, retryable: Bool) {
        if error as? TeslaLinkError == .demoMode {
            return ("Demo mode never contacts Tesla. Pair Volta with your server to sign in.", false)
        }
        switch error as? VoltaError {
        case .server(code: "tesla_link_denied", _)?: return ("Tesla sign-in was declined, so nothing was connected.", false)
        case .server(code: "tesla_link_invalid", _)?: return ("That Tesla sign-in expired or was already used. Start again.", false)
        case .server(code: "tesla_link_failed", _)?: return ("Tesla sign-in couldn't finish. Start again.", false)
        case .server(code: "tesla_link_device_mismatch", _)?: return ("That Tesla sign-in was started on another device. Start again on this iPhone.", false)
        case .server(code: "tesla_unavailable", _)?, .server(code: "http_503", _)?: return ("Your server couldn't reach Tesla. Try again in a moment.", true)
        case .unauthorized?: return (VoltaError.unauthorized.errorDescription ?? "This device is no longer paired.", false)
        case .transport?: return ("Couldn't reach your Volta server. Check your connection and try again.", true)
        default: return ("Something went wrong connecting your Tesla account. Try again.", true)
        }
    }
}
