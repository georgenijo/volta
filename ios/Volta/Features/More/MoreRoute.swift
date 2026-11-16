import SwiftUI

/// Every destination reachable from More. Hashable so it can drive a NavigationStack path
/// on a compact window and the sidebar selection on a regular-width one.
enum MoreRoute: Hashable, Sendable {
    case tires, stats, batteryHealth, batteryClimate, mileage, firmware, specs
    case leaseMileage, chargingInsights
    case switchVehicle, settings, maintenance, chargerMap
    /// Pages Settings pushes. They are routes so they stay in the More
    /// path and close with Settings when another area is picked.
    case account, vehicleSettings, chargingSettings, generalSettings
    case places, security, dataManagement, support
    /// Pages Charger Map pushes: a place's sessions, then one session.
    case chargerPlace(ChargerLocation), chargerSession(ChargeSummary)

    /// The page this route opens.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .tires: TiresView()
        case .stats: StatsView()
        case .batteryHealth: BatteryHealthView()
        case .batteryClimate: BatteryClimateView()
        case .mileage: MileageTrackerView()
        case .leaseMileage: LeaseMileageView()
        case .chargingInsights: ChargingInsightsView()
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
        case .chargerPlace(let location): ChargerLocationSessionsView(location: location)
        case .chargerSession(let session): ChargingDetailView(charge: session)
        }
    }
}

extension EnvironmentValues {
    /// Pushes a More page onto the stack that owns the current page. Charger
    /// Map opens from More and from the Charging tab; pushing through the
    /// owner keeps its pages in that tab's path, which is what survives a
    /// fold and what Back walks.
    @Entry var pushMoreRoute: (@MainActor @Sendable (MoreRoute) -> Void)? = nil
}

extension View {
    /// Registers all More destinations. Attach once inside the NavigationStack.
    func moreDestinations() -> some View {
        navigationDestination(for: MoreRoute.self) { $0.destination }
    }
}
