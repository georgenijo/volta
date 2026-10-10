import SwiftUI

/// Server connection, this device, Tesla account, and unpairing.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dataSource) private var dataSource
    @State private var confirmUnpair = false
    @State private var device: Device?
    @State private var isUnpairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isDemoMode {
                    ScreenKit.GroupCard(title: "Mode", footer: "Synthetic history generated on this iPhone. Nothing is sent anywhere.") {
                        ScreenKit.ValueRow(title: "Data", showsDivider: false) {
                            Text("Demo").font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                } else {
                    ScreenKit.GroupCard(title: "Server", footer: "Reached privately over Tailscale. The API is never exposed to the public internet.") {
                        ScreenKit.ValueRow(title: "Server URL", subtitle: model.settings.serverURL.isEmpty ? "—" : model.settings.serverURL, showsDivider: true) {
                            StatusDot(color: ScreenKit.mint)
                        }
                        ScreenKit.ValueRow(title: "Connection", showsDivider: false) {
                            Text("Tailnet · HTTPS").font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                    ScreenKit.GroupCard(title: "This device", footer: "This iPhone holds only a Volta device token in the Keychain — never your Tesla credentials.") {
                        ScreenKit.ValueRow(title: "Name") {
                            Text(device?.name ?? UIDevice.current.name).font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                        ScreenKit.ValueRow(title: "Paired", showsDivider: false) {
                            Text(device.map { $0.createdAt.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                }
                TeslaAccountSection()
                if let error = model.errorMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: error, tint: ScreenKit.amber) { model.errorMessage = nil }
                }
                Button(role: .destructive) { confirmUnpair = true } label: {
                    HStack {
                        if isUnpairing { ProgressView().tint(ScreenKit.red) } else { Image(systemName: "xmark.circle") }
                        Text(unpairTitle)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ScreenKit.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(ScreenKit.red.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(ScreenKit.red.opacity(0.22), lineWidth: 1)
                    }
                }
                .buttonStyle(VoltaPressStyle())
                .disabled(isUnpairing)
                .accessibilityIdentifier("button.unpair")
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Account")
        .task(id: model.pairingState) {
            // `/v1/me` exists only on the real API; demo mode has no device record.
            guard let api = dataSource as? APIDataSource else { device = nil; return }
            device = try? await api.me()
        }
        .confirmationDialog(dialogTitle, isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button(unpairTitle, role: .destructive) { Task { await unpair() } }
        } message: {
            Text(dialogMessage)
        }
    }

    private var unpairTitle: String {
        if model.isLaunchDemo { return "Exit launch demo" }
        return model.isDemoMode ? "Leave demo mode" : "Unpair this iPhone"
    }
    private var dialogTitle: String { model.isDemoMode ? "\(unpairTitle)?" : "Unpair this iPhone?" }
    private var dialogMessage: String {
        if model.isLaunchDemo { return "Your saved pairing and security settings will be preserved." }
        if model.isDemoMode { return "Volta returns to the pairing screen." }
        return "The device token is revoked on your server. You'll need a new pairing code to reconnect."
    }

    /// Paired: revoke on the server first, then disconnect locally (AppModel keeps the
    /// local token if revoke fails and surfaces `errorMessage`). Demo: local exit only.
    private func unpair() async {
        isUnpairing = true
        defer { isUnpairing = false }
        if model.pairingState == .paired && !model.isLaunchDemo { await model.revokeAndUnpair() }
        else { model.unpair() }
    }
}

/// The selected vehicle's live identity and state.
struct VehicleSettingsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<(Vehicle?, VehicleStatus?)> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { value in
                let (vehicle, status) = value
                if let vehicle {
                    VStack(alignment: .leading, spacing: 24) {
                        ScreenKit.GroupCard(title: vehicle.name) {
                            ScreenKit.ValueRow(title: "Model") { secondary([vehicle.model, vehicle.trim].compactMap { $0 }.joined(separator: " ")) }
                            ScreenKit.ValueRow(title: "Status") {
                                HStack(spacing: 6) {
                                    StatusDot(color: status?.state == .offline ? ScreenKit.red : status?.state == .asleep ? ScreenKit.secondary : ScreenKit.mint)
                                    secondary(status?.state.rawValue.capitalized ?? "—")
                                }
                            }
                            ScreenKit.ValueRow(title: "Odometer") { secondary(units.formatDistance(status?.odometerKm, fractionDigits: 0)) }
                            ScreenKit.ValueRow(title: "Software", showsDivider: false) { secondary(status?.firmware ?? vehicle.firmware ?? "—") }
                        }
                        ScreenKit.GroupCard(title: "Data source", footer: "TeslaMate on your server collects everything Volta shows. Vehicle commands arrive in a later phase.") {
                            ScreenKit.ValueRow(title: "Logger") { secondary("TeslaMate") }
                            ScreenKit.ValueRow(title: "Last update", showsDivider: false) {
                                secondary(status.map { VoltaFormat.relativeDate($0.updatedAt) } ?? "—")
                            }
                        }
                    }
                } else {
                    EmptyState(systemImage: "car", title: "No vehicle", message: "TeslaMate hasn't reported a vehicle yet.").padding(.top, 60)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Vehicle")
        .task(id: vehicleID) { await load() }
    }

    private func secondary(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text).font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
    }

    private func load() async {
        let source = dataSource, id = vehicleID
        do {
            let vehicle = try await source.vehicles().first { $0.id == id }
            let status = try? await source.status(vehicleID: id)
            state = .loaded((vehicle, status))
        } catch is CancellationError {
        } catch { state = .failed(error.localizedDescription) }
    }
}

/// How sessions are priced. TeslaMate prices each charge from the cost per kWh on
/// the geofence where it happened; Volta shows those costs as recorded and does
/// not estimate missing ones.
struct ChargingSettingsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<[Place]> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { places in
                VStack(alignment: .leading, spacing: 24) {
                    let priced = places.filter { $0.costPerKwh != nil }
                    ScreenKit.GroupCard(title: "Charging prices",
                                        footer: "Set a cost per kWh on a geofence in TeslaMate to price sessions there. Sessions without a recorded cost show as \u{2014}.") {
                        if priced.isEmpty {
                            ScreenKit.ValueRow(title: "No priced places", subtitle: "Costs come from TeslaMate geofences", showsDivider: false) { EmptyView() }
                        } else {
                            ForEach(Array(priced.enumerated()), id: \.element.id) { index, place in
                                ScreenKit.ValueRow(title: place.name, showsDivider: index < priced.count - 1) {
                                    Text("\(VoltaFormat.money(place.costPerKwh, currency: units.currency))/kWh")
                                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Coming later")
                            Text("A home-rate fallback for sessions TeslaMate couldn't price.")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Charging")
        .task(id: vehicleID) { await load() }
    }

    private func load() async {
        do { state = .loaded(try await dataSource.places(vehicleID: vehicleID)) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

/// Units, currency, language.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    private var distance: Binding<UnitPreferences.Distance> {
        Binding(get: { model.units.distance }, set: { model.units.distance = $0 })
    }
    private var temperature: Binding<UnitPreferences.Temperature> {
        Binding(get: { model.units.temperature }, set: { model.units.temperature = $0 })
    }
    private var pressure: Binding<UnitPreferences.Pressure> {
        Binding(get: { model.units.pressure ?? .psi }, set: { model.units.pressure = $0 })
    }
    private var drivingLiveActivity: Binding<Bool> {
        Binding(get: { model.drivingLiveActivity }, set: { model.drivingLiveActivity = $0 })
    }
    private var currency: Binding<String> {
        Binding(get: { model.units.currency }, set: { model.units.currency = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenKit.GroupCard(title: "Units", footer: "Your server stores metric values; Volta converts for display.") {
                    ScreenKit.ValueRow(title: "Distance") {
                        ScreenKit.Segmented(options: [(UnitPreferences.Distance.miles, "mi"), (.kilometers, "km")], selection: distance)
                            .frame(width: 150)
                    }
                    ScreenKit.ValueRow(title: "Temperature") {
                        ScreenKit.Segmented(options: [(UnitPreferences.Temperature.fahrenheit, "°F"), (.celsius, "°C")], selection: temperature)
                            .frame(width: 150)
                    }
                    ScreenKit.ValueRow(title: "Tire pressure") {
                        ScreenKit.Segmented(options: [(UnitPreferences.Pressure.psi, "psi"), (.bar, "bar")], selection: pressure)
                            .frame(width: 150)
                    }
                    ScreenKit.ValueRow(title: "Currency", showsDivider: false) {
                        Picker("Currency", selection: currency) {
                            ForEach(currencyOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(ScreenKit.secondary)
                    }
                }
                ScreenKit.GroupCard(title: "Live Activities", footer: "Charging always shows on the Lock Screen and in the Dynamic Island. Driving is optional.") {
                    ScreenKit.ValueRow(title: "Show while driving", showsDivider: false) {
                        Toggle("Show while driving", isOn: drivingLiveActivity)
                            .labelsHidden()
                            .tint(.voltaBlue)
                    }
                }
                ScreenKit.GroupCard(title: "Language", footer: "Volta follows your iPhone's language.") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        ScreenKit.ValueRow(title: "App language", showsDivider: false) {
                            Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")?.uppercased() ?? "ENGLISH")
                                .font(.system(size: 14, weight: .semibold)).tracking(1.2).foregroundStyle(.white)
                            ScreenKit.Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("General")
    }

    /// Keeps a currency saved from elsewhere selectable even if it isn't in the short list.
    private var currencyOptions: [String] {
        let current = model.units.currency
        return SettingsOptions.currencies.contains(current) ? SettingsOptions.currencies : [current] + SettingsOptions.currencies
    }
}

#Preview("Account") { NavigationStack { AccountSettingsView() }.voltaPreviewEnvironment() }
#Preview("Vehicle") { NavigationStack { VehicleSettingsView() }.voltaPreviewEnvironment() }
#Preview("Vehicle empty") { NavigationStack { VehicleSettingsView() }.voltaPreviewEnvironment(empty: true) }
#Preview("Charging") { NavigationStack { ChargingSettingsView() }.voltaPreviewEnvironment() }
#Preview("Charging empty") { NavigationStack { ChargingSettingsView() }.voltaPreviewEnvironment(empty: true) }
#Preview("General") { NavigationStack { GeneralSettingsView() }.voltaPreviewEnvironment() }
