import SwiftUI
import UIKit

/// First run: connects this device to the owner's volta-api server with
/// Sign in with Apple or a one-time code, or enters demo mode.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var code = ""
    @State private var deviceName = UIDevice.current.name
    @State private var usesCode = false

    private var canSignIn: Bool {
        !model.isPairing && !serverURL.isEmpty
            && !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canPair: Bool {
        canSignIn && code.trimmingCharacters(in: .whitespacesAndNewlines).count == 8
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "bolt.shield.fill").font(.system(size: 52))
                    .foregroundStyle(Color.voltaBlue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                    Text("VOLTA").font(.system(.largeTitle, weight: .heavy)).tracking(5)
                        .foregroundStyle(Color.voltaTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your Tesla. Your server.").font(.title3).foregroundStyle(Color.voltaTextSecondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    field("Server URL") {
                        TextField("Server URL", text: $serverURL, prompt: Text("https://your-server.tailnet.ts.net"))
                            .keyboardType(.URL).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("field.serverURL")
                    }
                    field("Device name") {
                        TextField("Device name", text: $deviceName)
                            .accessibilityIdentifier("field.deviceName")
                    }
                    if usesCode {
                        field("Pairing code") {
                            TextField("Pairing code", text: $code, prompt: Text("8-character code"))
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .font(.body.monospaced())
                                .accessibilityIdentifier("field.pairingCode")
                        }
                    }
                }
                .padding(VoltaSpacing.xl)
                .background(Color.voltaCard, in: RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous).strokeBorder(Color.voltaHairline))
                if let error = model.errorMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: error, tint: .voltaRed)
                        .accessibilityLabel("Sign-in error: \(error)")
                }
                VStack(spacing: VoltaSpacing.md) {
                    if usesCode {
                        PillButton(model.isPairing ? "Pairing…" : "Pair this device", size: .wide, style: .accent,
                                   isBusy: model.isPairing) {
                            Task { await model.pair(serverURL: serverURL, code: code, deviceName: deviceName) }
                        }
                        .disabled(!canPair)
                    } else {
                        AppleSignInButton { token in
                            Task { await model.signInWithApple(serverURL: serverURL, identityToken: token, deviceName: deviceName) }
                        } onFailure: { model.errorMessage = $0 }
                        .disabled(!canSignIn).opacity(canSignIn ? 1 : 0.5)
                        .accessibilityIdentifier("button.signInWithApple")
                        if model.isPairing {
                            HStack(spacing: VoltaSpacing.sm) {
                                ProgressView().tint(Color.voltaTextSecondary)
                                Text("Signing in…").font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Button(usesCode ? "Sign in with Apple instead" : "Use a pairing code instead") {
                        usesCode.toggle(); model.errorMessage = nil
                    }
                    .font(.system(.callout, weight: .medium)).foregroundStyle(Color.voltaBlue)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                    .disabled(model.isPairing)
                    .accessibilityIdentifier("button.pairingMethod")
                }
                VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                    Text("Use the address of your volta-api server. This iPhone must be able to reach it, for example over your tailnet.")
                    if usesCode {
                        Text("To get a code, run `bun run cli pair` in the API container on your server. A code works once and expires after 10 minutes.")
                    } else {
                        Text("Your server accepts only an Apple Account enrolled on it. Enroll yours from Settings on a paired iPhone, or run `bun run cli apple-enroll` on your server and sign in within 10 minutes.")
                    }
                }
                .font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                Button("Try demo mode") { model.tryDemoMode() }
                    .font(.system(.callout, weight: .medium)).foregroundStyle(Color.voltaBlue)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                    .disabled(model.isPairing)
            }
            .padding(28).padding(.top, 36).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .voltaScreenBackground()
        .onAppear { serverURL = model.settings.serverURL.isEmpty ? APIDataSource.builtInServerURL() : model.settings.serverURL }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).voltaLabelStyle().accessibilityHidden(true)
            content()
                .foregroundStyle(Color.voltaTextPrimary)
                .padding(VoltaSpacing.md)
                .background(Color.voltaBackground, in: RoundedRectangle(cornerRadius: VoltaRadius.control, style: .continuous))
        }
    }
}
