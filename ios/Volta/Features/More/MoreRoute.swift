import SwiftUI

/// Every destination reachable from More. Hashable so it can drive a NavigationStack path
/// on a compact window and the sidebar selection on a regular-width one.
enum MoreRoute: Hashable, Sendable {
    case tires, stats, batteryHealth, batteryClimate, mileage, firmware, specs
    case switchVehicle, settings, maintenance, chargerMap
    /// Pages Settings pushes. They are routes so they stay in the More
    /// path and close with Settings when another area is picked.
    case account, vehicleSettings, chargingSettings, generalSettings
    case places, security, dataManagement, support

    /// The page this route opens.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .tires: TiresView()
        case .stats: StatsView()
        case .batteryHealth: BatteryHealthView()
        case .batteryClimate: BatteryClimateView()
        case .mileage: MileageTrackerView()
        case .firmware: FirmwareTrackerView()
        case .specs: SpecsWarrantyView()
        case .switchVehicle: SwitchVehicleView()
        case .settings: SettingsView()
        case .maintenance: MaintenanceView()
        case .chargerMap: ChargerMapView()
        case .account: AccountSettingsView()
        case .vehicleSettings: VehicleSettingsView()
        case .chargingSettings: ChargingSettingsView()
        case .generalSettings: GeneralSettingsView()
        case .places: PlacesView()
        case .security: SecuritySettingsView()
        case .dataManagement: DataManagementView()
        case .support: AboutView()
        }
    }
}

extension View {
    /// Registers all More destinations. Attach once inside the NavigationStack.
    func moreDestinations() -> some View {
        navigationDestination(for: MoreRoute.self) { $0.destination }
    }
}
