import AuthenticationServices
import SwiftUI

/// Reads the result of Sign in with Apple. The only thing taken from the
/// credential is the identity token, which the server verifies with Apple.
enum AppleSignIn {
    enum Outcome: Equatable {
        case token(String)
        case cancelled
        case failed(String)
    }

    static func outcome(_ result: Result<Data?, any Error>) -> Outcome {
        switch result {
        case .success(let data):
            guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                return .failed("Apple didn't return a sign-in token. Try again.")
            }
            return .token(token)
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return .cancelled }
            return .failed("Sign in with Apple didn't finish. Check that this iPhone is signed in to an Apple Account, then try again.")
        }
    }
}

/// Apple's system button. It asks for no name or email.
struct AppleSignInButton: View {
    var label: SignInWithAppleButton.Label = .signIn
    var onToken: (String) -> Void
    var onFailure: (String) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SignInWithAppleButton(label) { request in
            request.requestedScopes = []
        } onCompletion: { result in
            let token = result.map { ($0.credential as? ASAuthorizationAppleIDCredential)?.identityToken }
            switch AppleSignIn.outcome(token) {
            case .token(let token): onToken(token)
            case .cancelled: break
            case .failed(let message): onFailure(message)
            }
        }
        // Apple's styles: white on a dark background, black on a light one.
        // The button takes a style, not a colour, so this follows the scheme.
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)  // appearance: Apple's button styles
        .frame(maxWidth: .infinity).frame(height: 50)
    }
}
