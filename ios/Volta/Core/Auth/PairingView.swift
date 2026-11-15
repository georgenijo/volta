import SwiftUI
import UIKit

/// First run: connects this device to the owner's volta-api server with a
/// one-time code, or enters demo mode.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var code = ""
    @State private var deviceName = UIDevice.current.name

    private var canPair: Bool {
        !model.isPairing
            && code.trimmingCharacters(in: .whitespacesAndNewlines).count == 8
            && !serverURL.isEmpty
            && !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    field("Pairing code") {
                        TextField("Pairing code", text: $code, prompt: Text("8-character code"))
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("field.pairingCode")
                    }
                    field("Device name") {
                        TextField("Device name", text: $deviceName)
                            .accessibilityIdentifier("field.deviceName")
                    }
                }
                .padding(VoltaSpacing.xl)
                .background(Color.voltaCard, in: RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous).strokeBorder(Color.voltaHairline))
                if let error = model.errorMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: error, tint: .voltaRed)
                        .accessibilityLabel("Pairing error: \(error)")
                }
                PillButton(model.isPairing ? "Pairing…" : "Pair this device", size: .wide, style: .accent,
                           isBusy: model.isPairing) {
                    Task { await model.pair(serverURL: serverURL, code: code, deviceName: deviceName) }
                }
                .disabled(!canPair)
                VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
                    Text("Use the address of your volta-api server. This iPhone must be able to reach it, for example over your tailnet.")
                    Text("To get a code, run `bun run cli pair` in the API container on your server. A code works once and expires after 10 minutes.")
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
        .onAppear { serverURL = model.settings.serverURL }
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
