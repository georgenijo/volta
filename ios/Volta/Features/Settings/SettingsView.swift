import SwiftUI

/// Settings index, pushed from More's gear button.
struct SettingsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(AppModel.self) private var model
    @State private var editingElectricityRate = false
    @State private var vehicle: Vehicle?
    @State private var placeCount: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink { AccountSettingsView() } label: { accountHeader }
                    .buttonStyle(VoltaPressStyle())
                    .accessibilityIdentifier("button.account")

                Text("Volta reads your car's history from TeslaMate on your own server. Nothing is stored in anyone else's cloud.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ScreenKit.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ScreenKit.horizontalPadding + 4)
                    .padding(.top, 14)
                    .accessibilityIdentifier("screen.settings")

                ScreenKit.SectionHeader(title: "Vehicle", dot: ScreenKit.mint)
                ScreenKit.ListCard {
                    row("car.fill", ScreenKit.mint, "Vehicle", vehicle.map { [$0.name, $0.model].compactMap { $0 }.joined(separator: " · ") } ?? "Manage your Tesla",
                        trailing: vehicle == nil ? nil : "Active", trailingTint: ScreenKit.mint) { VehicleSettingsView() }
                    row("bolt.fill", ScreenKit.mint, "Charging", "Session pricing") { ChargingSettingsView() }
                    Button { editingElectricityRate = true } label: {
                        ScreenKit.CapsRow(symbol: "dollarsign.circle", tint: ScreenKit.mint, title: "Electricity rate, $/kWh",
                            subtitle: "Fallback for estimated drive costs; default $0.20/kWh",
                            trailing: String(format: "$%.3f", model.settings.electricityRate), showsDivider: false)
                    }.buttonStyle(.plain)
                }

                ScreenKit.SectionHeader(title: "Preferences", dot: ScreenKit.blue)
                ScreenKit.ListCard {
                    row("slider.horizontal.3", ScreenKit.blue, "General", "Units, currency & language",
                        trailing: model.units.distance == .miles ? "Miles" : "Km") { GeneralSettingsView() }
                    row("mappin.and.ellipse", ScreenKit.blue, "Places", placeCount.map { $0 == 0 ? "No saved places" : "\($0) saved place\($0 == 1 ? "" : "s")" } ?? "Home, work & saved places") { PlacesView() }
                    row("lock.fill", ScreenKit.blue, "Security", "App Lock & privacy", trailing: model.appLockEnabled ? "On" : nil, trailingTint: ScreenKit.mint,
                        showsDivider: false) { SecuritySettingsView() }
                }

                ScreenKit.SectionHeader(title: "Data & help", dot: ScreenKit.secondary)
                ScreenKit.ListCard {
                    row("arrow.up.arrow.down", ScreenKit.secondary, "Data Management", "Export drives & charges") { DataManagementView() }
                    row("questionmark.bubble.fill", ScreenKit.secondary, "Support", "About Volta & help", showsDivider: false) { AboutView() }
                }

                footer
            }
            .padding(.top, 4)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .sheet(isPresented: $editingElectricityRate) {
            ElectricityRateSettingsEditor(settings: model.settings)
                .presentationDetents([.medium])
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
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(pillTint.opacity(0.22)).blur(radius: 12).frame(width: 64, height: 64)
                Circle().fill(LinearGradient(colors: [Color.voltaCardTop, Color.voltaCard], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(LinearGradient(colors: [pillTint.opacity(0.6), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                Image(systemName: "iphone").font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Account").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                Text(serverHost).font(.system(size: 13, weight: .medium)).foregroundStyle(ScreenKit.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(pillTint).frame(width: 5, height: 5).shadow(color: pillTint.opacity(0.9), radius: 3)
                Text(model.isDemoMode ? "Demo" : "Paired")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(pillTint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(pillTint.opacity(0.08), in: .capsule)
            .overlay(Capsule().strokeBorder(pillTint.opacity(0.25), lineWidth: 1))
            ScreenKit.Chevron()
        }
        .padding(16)
        .voltaCardBackground(radius: 22)
        .padding(.horizontal, ScreenKit.horizontalPadding)
        .padding(.top, 8)
        .contentShape(Rectangle())
    }

    private var pillTint: Color { model.isDemoMode ? ScreenKit.blue : ScreenKit.mint }

    private func row<Destination: View>(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String,
                                        trailing: String? = nil, trailingTint: Color = .white, showsDivider: Bool = true,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            ScreenKit.CapsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle, trailing: trailing,
                              trailingTint: trailingTint, showsDivider: showsDivider)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Image("Wordmark").resizable().scaledToFit().frame(height: 18)
                .opacity(0.4)
                .accessibilityLabel("Volta")
                .padding(.bottom, 4)
            Text("Your data stays on your server")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5).textCase(.uppercase)
                .foregroundStyle(ScreenKit.tertiary)
            Text("v\(AppInfo.version) (\(AppInfo.build))")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().tracking(1)
                .foregroundStyle(ScreenKit.tertiary)
            Text("Volta is not affiliated with, endorsed by, or sponsored by Tesla, Inc. Tesla is a registered trademark of Tesla, Inc.")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(ScreenKit.tertiary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
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

private struct ElectricityRateSettingsEditor: View {
    var settings: UserSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var value: Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite, v >= 0 else { return nil }
        return v
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Electricity rate, $/kWh", text: $text).keyboardType(.decimalPad)
                } footer: {
                    Text("Used for estimated drive costs when TeslaMate has no charge cost in a known currency. Real charge costs take precedence. USD per kWh; 0 means free. Stored on this device. This replaces the earlier per-vehicle manual trip-rate editor. Earlier saved rates are preserved but no longer used; enter your USD fallback here.")
                }
            }
            .navigationTitle("Electricity rate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let value { settings.electricityRate = value }; dismiss() }.disabled(value == nil)
                }
            }
        }.onAppear { text = String(settings.electricityRate) }
    }
}
