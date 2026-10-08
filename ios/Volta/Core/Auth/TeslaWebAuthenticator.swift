import AuthenticationServices
import UIKit

/// Opens Tesla's sign-in page and returns the callback URL. Never logs or
/// stores the URLs it handles.
@MainActor
protocol TeslaWebAuthenticating: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

enum TeslaWebAuthError: Error, Equatable {
    case cancelled, alreadyRunning, failedToStart, failed
}

/// `ASWebAuthenticationSession` in an ephemeral browser, so no Tesla cookies
/// outlive the sign-in. One session at a time; task cancellation dismisses it.
@MainActor
final class TeslaWebAuthenticator: NSObject, TeslaWebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    /// Set before every session starts; kept so a late anchor request never fails.
    private var anchor: ASPresentationAnchor?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard session == nil, continuation == nil else { throw TeslaWebAuthError.alreadyRunning }
        try Task.checkCancellation()
        guard let window = Self.currentWindow() else { throw TeslaWebAuthError.failedToStart }
        anchor = window
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before a session existed: onCancel found nothing to dismiss.
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable [weak self] callbackURL, error in
                    let result: Result<URL, any Error>
                    if let callbackURL { result = .success(callbackURL) }
                    else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { result = .failure(TeslaWebAuthError.cancelled) }
                    else { result = .failure(TeslaWebAuthError.failed) }
                    Task { @MainActor in self?.finish(result) }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                self.session = session
                self.continuation = continuation
                if !session.start() { finish(.failure(TeslaWebAuthError.failedToStart)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func cancel() {
        guard let session else { return }
        session.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `authenticate` sets this before creating any session.
        guard let anchor else { preconditionFailure("Tesla sign-in started without a window") }
        return anchor
    }

    private static func currentWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
