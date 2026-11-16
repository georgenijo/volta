import SwiftUI

@main
struct VoltaApp: App {
    @State private var model = AppModel()
    init() { ExportFiles.removeAll() } // Sweep exports left by a previous run.
    var body: some Scene {
        WindowGroup {
            VoltaRootView()
                .environment(model)
                .environment(model.settings)
                .environment(\.dataSource, model.dataSource)
                .environment(\.vehicleID, model.selectedVehicleID)
                .environment(\.units, model.units)
                .environment(\.vehicleSurfaces, model.refreshSurfaces)
                .environment(\.vehicleCommandCoordinator, model.commandCoordinator)
                .preferredColorScheme(.dark)
                // Most layouts are tuned to absolute sizes; larger text sizes wrap labels.
                // Screens built on text styles opt out with `followsSystemTextSize()`.
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
    }
}

private struct VoltaRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDisconnect = false
    private var needsPrivacy: Bool { model.isPaired && model.appLockEnabled && scenePhase != .active }
    var body: some View {
        Group {
            if model.needsCredentialRetry {
                VStack(spacing: VoltaSpacing.xl) {
                    Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(Color.voltaBlue)
                        .accessibilityHidden(true)
                    Text(model.errorMessage ?? "Unlock your iPhone to access Volta.")
                        .font(.callout).foregroundStyle(Color.voltaTextSecondary).multilineTextAlignment(.center)
                    PillButton("Try Again", systemImage: "arrow.clockwise", style: .accent) { model.restorePairing() }
                }
                .padding(VoltaSpacing.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .voltaScreenBackground()
            } else if !model.isPaired { PairingView() }
            else if model.vehicles.isEmpty {
                VStack(spacing: 20) {
                    if model.isLoadingVehicles || !model.hasLoadedVehicles {
                        ProgressView("Loading vehicles…").tint(Color.voltaTextSecondary).foregroundStyle(Color.voltaTextSecondary)
                    } else {
                        TeslaSignInPanel(note: "No vehicles yet · waiting for your server to record one.", error: model.errorMessage)
                        HStack(spacing: 18) {
                            PillButton("Retry", systemImage: "arrow.clockwise") { Task { await model.loadVehicles() } }
                            Button(model.isLaunchDemo ? "Exit demo" : "Disconnect") { disconnect { model.unpair() } }
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.voltaTextSecondary)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                                .buttonStyle(VoltaPressStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .voltaScreenBackground()
                .task(id: model.tesla.state == .connected) {
                    // Just connected: the collector needs a moment to discover the vehicle.
                    guard model.tesla.state == .connected else { return }
                    for _ in 0..<12 where model.vehicles.isEmpty {
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        await model.loadVehicles()
                    }
                }
            } else {
                MainShell().id("\(model.pairingState)-\(model.selectedVehicleID)")
                    .onAppear { StartupTrace.mark(.shell) }
            }
        }
        // Keep the main screen's navigation and scroll state mounted while locked.
        .opacity(model.isLocked || needsPrivacy ? 0 : 1)
        .disabled(model.isLocked || needsPrivacy)
        .accessibilityHidden(model.isLocked || needsPrivacy)
        .overlay {
            if needsPrivacy {
                Color.voltaBackground.ignoresSafeArea().overlay {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 52)).foregroundStyle(Color.voltaBlue)
                }
            } else if model.isLocked {
                ZStack {
                    Color.voltaBackground.ignoresSafeArea()
                    VStack(spacing: VoltaSpacing.xl) {
                        Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(Color.voltaBlue)
                            .accessibilityHidden(true)
                        Text("Volta is locked").font(.title.bold()).foregroundStyle(Color.voltaTextPrimary)
                        if let error = model.errorMessage {
                            Text(error).font(.callout).foregroundStyle(Color.voltaTextSecondary).multilineTextAlignment(.center)
                        }
                        PillButton("Unlock with Face ID or Passcode", systemImage: "faceid", size: .wide, style: .accent,
                                   isBusy: model.isUnlocking) { Task { await model.unlock() } }
                            .disabled(model.isUnlocking)
                        Button(model.isLaunchDemo ? "Exit demo" : "Disconnect this device") {
                            disconnect { model.disconnectLockedDevice() }
                        }
                        .font(.callout.weight(.medium)).foregroundStyle(Color.voltaTextSecondary)
                        .frame(minHeight: 44).contentShape(.rect)
                        Text(model.isLaunchDemo ? "Your saved pairing and security settings will be preserved." : "Disconnecting removes your stored device token.")
                            .font(.footnote).foregroundStyle(Color.voltaTextSecondary).multilineTextAlignment(.center)
                    }
                    .padding(VoltaSpacing.xxl).frame(maxWidth: 440)
                }
            }
        }
        // Disconnecting deletes the device token; reconnecting needs a new
        // pairing code from the server, so ask first.
        .confirmationDialog("Disconnect this device?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if model.isLocked { model.disconnectLockedDevice() } else { model.unpair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Volta forgets this device's token. You'll need a new pairing code from your server to connect again.")
        }
        .onAppear {
            // Runs after the transaction that first displays the root view commits.
            DispatchQueue.main.async { StartupTrace.mark(.firstFrame) }
        }
        .task(id: model.pairingState) {
            if model.needsCredentialRetry { model.restorePairing() }
            if model.isLocked { await model.unlock() }
            else { await model.loadVehicles() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
            else if phase == .active { Task { await model.becameActive(); await model.refreshTesla() } }
        }
    }

    /// Leaving the launch demo loses nothing, so it runs at once; a real
    /// disconnect asks first.
    private func disconnect(_ exitDemo: () -> Void) {
        if model.isLaunchDemo { exitDemo() } else { confirmsDisconnect = true }
    }
}
