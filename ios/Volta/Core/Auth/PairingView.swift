import SwiftUI
import UIKit

/// First run: signs this device in to the owner's volta-api server with
/// Sign in with Apple, and nothing else. The server address comes from the
/// build or from an earlier sign-in. Other fields appear only when they are
/// needed: the address when neither source has one or the server didn't
/// answer, and a pairing code when the server doesn't offer Sign in with Apple.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var typedServerURL = ""
    @State private var code = ""
    @State private var isWide = false
    @State private var showsServerField = false

    /// The build's address wins over a saved one, so a build can move Volta to a new server.
    private var knownServerURL: String {
        let builtIn = APIDataSource.builtInServerURL()
        return builtIn.isEmpty ? model.settings.serverURL : builtIn
    }
    private var asksForServer: Bool { knownServerURL.isEmpty || showsServerField }
    private var serverURL: String { asksForServer ? typedServerURL : knownServerURL }
    private var needsPairingCode: Bool { model.needsPairingCode(for: serverURL) }
    private var deviceName: String { UIDevice.current.name }
    private var canSignIn: Bool { !model.isPairing && !serverURL.isEmpty }
    private var canPair: Bool { canSignIn && code.trimmingCharacters(in: .whitespacesAndNewlines).count == 8 }

    var body: some View {
        Group {
            // On iPhone Duo's inner display the brand and the button each get
            // a side, so neither sits across the fold.
            if horizontalSizeClass == .regular && isWide {
                VoltaPanes {
                    centered(brand)
                } secondary: {
                    centered(controls.frame(maxWidth: 360))
                }
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 48)
                            brand
                            Spacer(minLength: 48)
                            controls
                        }
                        .padding(.horizontal, 28).padding(.bottom, 32)
                        .frame(maxWidth: 440)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        // Measured without the keyboard, so typing never switches layouts.
        .background {
            Color.clear
                .onGeometryChange(for: Bool.self) { ScreenKit.isWide($0.size) } action: { isWide = $0 }
                .ignoresSafeArea(.keyboard)
        }
        .voltaScreenBackground()
        .scrollDismissesKeyboard(.interactively)
        // A server that didn't answer may have moved: show its address to correct.
        .onChange(of: model.serverAddressInDoubt, initial: true) { _, inDoubt in
            guard inDoubt, !showsServerField else { return }
            if typedServerURL.isEmpty { typedServerURL = knownServerURL }
            showsServerField = true
        }
    }

    private func centered<Content: View>(_ content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var controls: some View {
        VStack(spacing: VoltaSpacing.lg) {
            if asksForServer { serverField }
            if needsPairingCode { codeField }
            if let error = model.errorMessage {
                InlineBanner(systemImage: "exclamationmark.triangle", message: error, tint: .voltaRed)
                    .accessibilityLabel("Sign-in error: \(error)")
            }
            if needsPairingCode {
                PillButton(model.isPairing ? "Connecting…" : "Connect", size: .wide, style: .accent, isBusy: model.isPairing) {
                    Task { await model.pair(serverURL: serverURL, code: code, deviceName: deviceName) }
                }
                .disabled(!canPair)
            } else {
                AppleSignInButton { token in
                    Task { await model.signInWithApple(serverURL: serverURL, identityToken: token, deviceName: deviceName) }
                } onFailure: { model.errorMessage = $0 }
                .disabled(!canSignIn).opacity(canSignIn ? 1 : 0.5)
                .overlay {
                    if model.isPairing {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white)
                        ProgressView().tint(.black).accessibilityLabel("Signing in")
                    }
                }
                .accessibilityIdentifier("button.signInWithApple")
            }
        }
    }

    private var brand: some View {
        VStack(spacing: VoltaSpacing.lg) {
            Image(systemName: "bolt.shield.fill").font(.system(size: 56))
                .foregroundStyle(Color.voltaBlue).accessibilityHidden(true)
            VStack(spacing: VoltaSpacing.sm) {
                Text("VOLTA").font(.system(.largeTitle, weight: .heavy)).tracking(5)
                    .foregroundStyle(Color.voltaTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Your Tesla. Your server.").font(.title3).foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var serverField: some View {
        field("Server URL") {
            TextField("Server URL", text: $typedServerURL, prompt: Text("https://your-server.tailnet.ts.net"))
                .keyboardType(.URL).textContentType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("field.serverURL")
        }
    }

    private var codeField: some View {
        field("Pairing code") {
            TextField("Pairing code", text: $code, prompt: Text("8-character code"))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.body.monospaced())
                .accessibilityIdentifier("field.pairingCode")
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).voltaLabelStyle().accessibilityHidden(true)
            content()
                .foregroundStyle(Color.voltaTextPrimary)
                .padding(VoltaSpacing.md)
                .background(Color.voltaCard, in: RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
