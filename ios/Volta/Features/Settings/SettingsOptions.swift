import SwiftUI

/// Settings choices. All app-wide settings (server URL, units, app lock,
/// selected vehicle) live on AppModel / UserSettings.
enum SettingsOptions {
    static let currencies = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "NOK", "SEK"]
}

extension View {
    /// Injects a launch-demo AppModel plus the value environments, matching what
    /// VoltaApp provides. For previews only; never touches Keychain or saved pairing.
    @MainActor
    func voltaPreviewEnvironment(empty: Bool = false) -> some View {
        let settings = UserSettings(defaults: UserDefaults(suiteName: "volta.preview") ?? .standard)
        let model = AppModel(settings: settings, launchArguments: ["-demo-mode", "YES"])
        let source = MockDataSource(empty: empty)
        return self
            .environment(model)
            .environment(model.settings)
            .environment(\.dataSource, source)
            .environment(\.vehicleID, model.selectedVehicleID)
            .environment(\.units, model.units)
            .preferredColorScheme(.dark)
    }
}
