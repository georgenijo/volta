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
                .preferredColorScheme(.dark)
        }
    }
}

private struct VoltaRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    private let background = Color(red: 0.055, green: 0.059, blue: 0.067)
    private var needsPrivacy: Bool { model.isPaired && model.appLockEnabled && scenePhase != .active }
    var body: some View {
        Group {
            if model.needsCredentialRetry {
                VStack(spacing: 20) {
                    Text(model.errorMessage ?? "Unlock your iPhone to access Volta.")
                    Button("Retry secure storage") { model.restorePairing() }
                }.padding(32)
            } else if !model.isPaired { PairingView() }
            else if model.vehicles.isEmpty {
                VStack(spacing: 20) {
                    if model.isLoadingVehicles || !model.hasLoadedVehicles {
                        ProgressView("Loading vehicles…").tint(Color.voltaTextSecondary).foregroundStyle(Color.voltaTextSecondary)
                    } else {
                        TeslaSignInPanel(note: "No vehicles yet · waiting for your server to record one.", error: model.errorMessage)
                        HStack(spacing: 18) {
                            PillButton("Retry", systemImage: "arrow.clockwise") { Task { await model.loadVehicles() } }
                            Button(model.isLaunchDemo ? "Exit launch demo" : "Disconnect") { model.unpair() }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.voltaTextSecondary)
                                .padding(.vertical, 9)
                                .contentShape(.rect)
                                .buttonStyle(VoltaPressStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .top) {
                    VoltaTopGlow.gradient.frame(height: VoltaTopGlow.height).ignoresSafeArea().allowsHitTesting(false)
                }
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
            }
        }
        // Keep the main screen's navigation and scroll state mounted while locked.
        .opacity(model.isLocked || needsPrivacy ? 0 : 1)
        .disabled(model.isLocked || needsPrivacy)
        .accessibilityHidden(model.isLocked || needsPrivacy)
        .overlay {
            if needsPrivacy {
                background.ignoresSafeArea().overlay {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 52)).foregroundStyle(.blue)
                }
            } else if model.isLocked {
                ZStack {
                    background.ignoresSafeArea()
                    VStack(spacing: 24) {
                        Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.blue)
                        Text("Volta is locked").font(.title.bold())
                        if let error = model.errorMessage { Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                        Button("Unlock with Face ID or passcode") { Task { await model.unlock() } }
                            .buttonStyle(.borderedProminent).disabled(model.isUnlocking)
                        Button(model.isLaunchDemo ? "Exit launch demo" : "Disconnect this device") { model.disconnectLockedDevice() }
                            .foregroundStyle(.secondary)
                        Text(model.isLaunchDemo ? "Your saved pairing and security settings will be preserved." : "Disconnecting removes your stored device token.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(32)
                }
            }
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
}
