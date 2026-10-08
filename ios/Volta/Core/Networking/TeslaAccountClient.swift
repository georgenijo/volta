import Foundation

/// Sign in with Tesla, device-authenticated. The server owns the OAuth exchange
/// and every Tesla token; the client only ever sees the authorization URL and
/// hands back the callback URL.
protocol TeslaAccountClient: Sendable {
    func teslaStatus() async throws -> TeslaStatus
    func startTeslaLink() async throws -> TeslaLinkStart
    func completeTeslaLink(callbackURL: URL) async throws -> TeslaStatus
    /// Forgets a pending login (user cancelled). Best effort.
    func cancelTeslaLink() async throws
    func disconnectTesla() async throws
}

struct TeslaStatus: Decodable, Equatable, Sendable {
    struct Collector: Decodable, Equatable, Sendable { let enabled: Bool }
    struct Budget: Decodable, Equatable, Sendable {
        let monthlyLimitUsd: Double
        let spentUsd: Double
        let paused: Bool
    }
    let available: Bool
    let connected: Bool
    let needsReauth: Bool
    let linkPending: Bool
    let collector: Collector?
    let budget: Budget?
}

struct TeslaLinkStart: Decodable, Equatable, Sendable {
    let authorizationUrl: URL
    let callbackScheme: String
    let expiresAt: Date
}

enum TeslaLinkError: Error, Equatable {
    /// Demo mode never contacts Tesla.
    case demoMode
}

/// Demo mode: Tesla linking looks available but never leaves the device.
extension MockDataSource: TeslaAccountClient {
    func teslaStatus() async throws -> TeslaStatus {
        TeslaStatus(available: true, connected: false, needsReauth: false, linkPending: false,
                    collector: .init(enabled: false), budget: nil)
    }
    func startTeslaLink() async throws -> TeslaLinkStart { throw TeslaLinkError.demoMode }
    func completeTeslaLink(callbackURL: URL) async throws -> TeslaStatus { throw TeslaLinkError.demoMode }
    func cancelTeslaLink() async throws { }
    func disconnectTesla() async throws { }
}
