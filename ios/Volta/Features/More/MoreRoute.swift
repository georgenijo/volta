import SwiftUI

/// Every destination reachable from More. Hashable so it can drive a NavigationStack path.
enum MoreRoute: Hashable, Sendable {
    case tires, stats, batteryHealth, batteryClimate, mileage, firmware, specs
    case switchVehicle, settings, maintenance, chargerMap
}

extension View {
    /// Registers all More destinations. Attach once inside the NavigationStack.
    func moreDestinations() -> some View {
        navigationDestination(for: MoreRoute.self) { route in
            switch route {
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
            }
        }
    }
}
