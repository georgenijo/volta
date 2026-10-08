import SwiftUI

/// Settings index, pushed from More's gear button.
struct SettingsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(AppModel.self) private var model
    @State private var vehicle: Vehicle?
    @State private var placeCount: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavigationLink { AccountSettingsView() } label: { accountHeader }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("button.account")

                Text("Volta reads your car's history from TeslaMate on your own server. Nothing is stored in anyone else's cloud.")
                    .font(.system(size: 14))
                    .foregroundStyle(ScreenKit.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ScreenKit.horizontalPadding)
                    .padding(.top, 14).padding(.bottom, 26)
                    .accessibilityIdentifier("screen.settings")

                HairlineDivider()
                row("car.fill", "Vehicle", vehicle.map { [$0.name, $0.model].compactMap { $0 }.joined(separator: " · ") } ?? "Manage your Tesla",
                    trailing: vehicle == nil ? nil : "Active", trailingTint: ScreenKit.green) { VehicleSettingsView() }
                row("bolt.fill", "Charging", "Session pricing") { ChargingSettingsView() }
                row("slider.horizontal.3", "General", "Units, currency & language",
                    trailing: model.units.distance == .miles ? "Miles" : "Km") { GeneralSettingsView() }
                row("mappin.and.ellipse", "Places", placeCount.map { $0 == 0 ? "No saved places" : "\($0) saved place\($0 == 1 ? "" : "s")" } ?? "Home, work & saved places") { PlacesView() }
                row("lock.fill", "Security", "App Lock & privacy", trailing: model.appLockEnabled ? "On" : nil, trailingTint: ScreenKit.green) { SecuritySettingsView() }
                row("arrow.up.arrow.down", "Data Management", "Export drives & charges") { DataManagementView() }
                row("questionmark.bubble.fill", "Support", "About Volta & help") { AboutView() }

                footer
            }
            .padding(.top, 4)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .accessibilityIdentifier("scroll.settings")
        .screenKitPage("Settings")
        .task(id: vehicleID) {
            let source = dataSource, id = vehicleID
            async let vehicles = try? source.vehicles()
            async let places = try? source.places(vehicleID: id)
            let fetched = await vehicles
            vehicle = model.selectedVehicle ?? fetched?.first { $0.id == id }
            placeCount = await places?.count
        }
    }

    private var serverHost: String {
        if model.isDemoMode { return "Demo data" }
        let url = model.settings.serverURL
        return URL(string: url)?.host() ?? url
    }

    private var accountHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.voltaCard)
                Circle().strokeBorder(Color.voltaHairline, lineWidth: 1)
                Image(systemName: "iphone").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Account").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text(serverHost).font(.system(size: 15)).foregroundStyle(ScreenKit.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: model.isDemoMode ? "sparkles" : "checkmark.seal.fill")
                Text(model.isDemoMode ? "Demo" : "Paired")
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(pillTint)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(pillTint.opacity(0.12), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, ScreenKit.horizontalPadding)
        .padding(.top, 12)
        .contentShape(Rectangle())
    }

    private var pillTint: Color { model.isDemoMode ? ScreenKit.blue : ScreenKit.green }

    private func row<Destination: View>(_ symbol: String, _ title: String, _ subtitle: String,
                                        trailing: String? = nil, trailingTint: Color = .white,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            ScreenKit.CapsRow(symbol: symbol, title: title, subtitle: subtitle, trailing: trailing, trailingTint: trailingTint)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Image("Wordmark").resizable().scaledToFit().frame(height: 20)
                .opacity(0.55)
                .accessibilityLabel("Volta")
                .padding(.bottom, 4)
            Text("Your data stays on your server")
                .font(.system(size: 11, weight: .semibold)).tracking(2).textCase(.uppercase)
                .foregroundStyle(ScreenKit.secondary)
            Text("v\(AppInfo.version) (\(AppInfo.build))")
                .font(.system(size: 13, weight: .medium, design: .monospaced)).tracking(1.5)
                .foregroundStyle(ScreenKit.secondary)
            Text("Volta is not affiliated with, endorsed by, or sponsored by Tesla, Inc. Tesla is a registered trademark of Tesla, Inc.")
                .font(.system(size: 12)).foregroundStyle(ScreenKit.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

/// Brand wordmark from the asset catalog.
struct SettingsWordmark: View {
    var height: CGFloat = 20
    var body: some View {
        Image("Wordmark").resizable().scaledToFit().frame(height: height)
            .accessibilityLabel("Volta")
    }
}

#Preview("Populated") {
    NavigationStack { SettingsView() }.voltaPreviewEnvironment()
}

#Preview("Empty") {
    NavigationStack { SettingsView() }.voltaPreviewEnvironment(empty: true)
}
