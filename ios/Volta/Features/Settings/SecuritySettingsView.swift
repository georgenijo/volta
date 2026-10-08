import LocalAuthentication
import SwiftUI

/// Face ID app lock and privacy notes.
struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var biometry: LABiometryType = .none

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenKit.GroupCard(title: "App lock", footer: "Locks Volta whenever it leaves the foreground. Unlock with \(biometryName) or your passcode.") {
                    ToggleRow(systemImage: biometrySymbol, title: "Require \(biometryName)",
                              subtitle: model.isConfiguringAppLock ? "Confirming…" : model.appLockEnabled ? "Volta is locked when closed" : "Off",
                              isOn: Binding(get: { model.appLockEnabled }, set: { on in Task { await model.setAppLockEnabled(on) } }))
                        .padding(.horizontal, 16)
                        .disabled(model.isConfiguringAppLock)
                        .accessibilityIdentifier("toggle.appLock")
                }
                if let errorMessage = model.errorMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: errorMessage, tint: ScreenKit.amber) { model.errorMessage = nil }
                }
                ScreenKit.GroupCard(title: "Privacy") {
                    privacyRow("server.rack", "Your data stays on your server", "Drives, charges and locations live in your TeslaMate database.")
                    privacyRow("key", "No Tesla credentials on this phone", "Tesla tokens stay inside TeslaMate on your server.")
                    privacyRow("network.badge.shield.half.filled", "Private network only", "Volta talks to your server over Tailscale. No analytics, no trackers.", last: true)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Security")
        .onAppear {
            let context = LAContext()
            _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            biometry = context.biometryType
        }
    }

    private var biometryName: String {
        switch biometry {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Passcode"
        }
    }

    private var biometrySymbol: String {
        switch biometry {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "lock"
        }
    }

    // Enabling goes through AppModel.setAppLockEnabled, which authenticates first so
    // nobody locks themselves out, and drives the app frame's lock screen.

    private func privacyRow(_ symbol: String, _ title: String, _ detail: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(ScreenKit.green).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 13)).foregroundStyle(ScreenKit.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            if !last { HairlineDivider(leadingInset: 56) }
        }
    }
}

#Preview { NavigationStack { SecuritySettingsView() }.voltaPreviewEnvironment() }
