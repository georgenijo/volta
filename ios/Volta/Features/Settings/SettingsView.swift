import SwiftUI

/// Settings index: pushed from More's gear button, or beside More's sidebar
/// on a regular-width window. Its rows push `MoreRoute` values, so it belongs
/// in a stack that registers `moreDestinations()`.
struct SettingsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(AppModel.self) private var model
    @State private var vehicle: Vehicle?
    @State private var placeCount: Int?

    var body: some View {
        ScreenKit.Page(scroll: "settings", spacing: 0) {
            VStack(spacing: 0) {
                NavigationLink(value: MoreRoute.account) { accountHeader }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("button.account")

                Text("Volta reads your car's history from TeslaMate on your own server. Nothing is stored in anyone else's cloud.")
                    .font(.subheadline)
                    .foregroundStyle(ScreenKit.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ScreenKit.horizontalPadding)
                    .padding(.top, 14).padding(.bottom, 26)
                    .accessibilityIdentifier("screen.settings")

                HairlineDivider()
                Group {
                    row("car", "Vehicle", vehicle.map { [$0.name, $0.model].compactMap { $0 }.joined(separator: " · ") } ?? "Manage your Tesla",
                        to: .vehicleSettings)
                    row("bolt", "Charging", "Electricity rate and costs",
                        trailing: model.settings.electricityRate.map { VoltaFormat.money($0, currency: model.units.currency) + "/kWh" }, to: .chargingSettings)
                    row("slider.horizontal.3", "General", "Units, currency and language",
                        trailing: model.units.distance == .miles ? "Miles" : "Kilometres", to: .generalSettings)
                    row("mappin.and.ellipse", "Places", placeCount.map { $0 == 0 ? "No saved places" : "\($0) saved place\($0 == 1 ? "" : "s")" } ?? "Home, work and saved places", to: .places)
                    row("lock", "Security", "App lock and privacy", trailing: model.appLockEnabled ? "On" : "Off", to: .security)
                    row("arrow.up.arrow.down", "Data management", "Export JSON, CSV and GPX", to: .dataManagement)
                    row("questionmark.bubble", "Support", "About Volta and help", to: .support)
                }

                footer
            }
            // Rows run edge to edge on a phone; the page supplies the side padding.
            .padding(.horizontal, -ScreenKit.horizontalPadding)
            .padding(.top, -4)
        }
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
                Image(systemName: "iphone").font(.title2.weight(.medium)).foregroundStyle(Color.voltaInk.opacity(0.85))
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Account").font(.title2.weight(.bold)).foregroundStyle(.voltaTextPrimary)
                Text(serverHost).font(.subheadline).foregroundStyle(ScreenKit.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: model.isDemoMode ? "sparkles" : "checkmark.seal.fill")
                Text(model.isDemoMode ? "Demo" : "Paired")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.voltaBlueText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ScreenKit.blue.opacity(0.12), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, ScreenKit.horizontalPadding)
        .padding(.top, 12)
        .contentShape(Rectangle())
    }

    private func row(_ symbol: String, _ title: String, _ subtitle: String,
                     trailing: String? = nil, to route: MoreRoute) -> some View {
        NavigationLink(value: route) {
            ScreenKit.CapsRow(symbol: symbol, title: title, subtitle: subtitle, trailing: trailing)
        }
        .buttonStyle(.plain)
        // `row.settings.<title>` for UI tests, as in `row.settings.data-management`.
        .accessibilityIdentifier("row.settings." + title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Image("Wordmark").resizable().scaledToFit().frame(height: 20)
                .opacity(0.55)
                .accessibilityLabel("Volta")
                .padding(.bottom, 4)
            Text("Your data stays on your server")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ScreenKit.secondary)
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.footnote).monospacedDigit()
                .foregroundStyle(ScreenKit.secondary)
            Text("Volta is not affiliated with, endorsed by, or sponsored by Tesla, Inc. Tesla is a registered trademark of Tesla, Inc.")
                .font(.caption).foregroundStyle(ScreenKit.tertiary)
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
    NavigationStack { SettingsView().moreDestinations() }.voltaPreviewEnvironment()
}

#Preview("Empty") {
    NavigationStack { SettingsView().moreDestinations() }.voltaPreviewEnvironment(empty: true)
}
