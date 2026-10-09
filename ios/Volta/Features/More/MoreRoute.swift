import SwiftUI

/// Every destination reachable from More. Hashable so it can drive a NavigationStack path.
enum MoreRoute: Hashable, Sendable {
    case stats, batteryHealth, batteryClimate, mileage, firmware, specs
    case switchVehicle, settings, maintenance, chargerMap
    case comingLater(ComingLaterFeature)
}

enum ComingLaterFeature: String, Hashable, Sendable, CaseIterable {
    case tires

    var title: String {
        switch self {
        case .tires: "Tires"
        }
    }

    var symbol: String {
        switch self {
        case .tires: "circle.circle"
        }
    }

    var blurb: String {
        switch self {
        case .tires: "Tire pressure history and rotation reminders, straight from your car's TPMS readings."
        }
    }
}

extension View {
    /// Registers all More destinations. Attach once inside the NavigationStack.
    func moreDestinations() -> some View {
        navigationDestination(for: MoreRoute.self) { route in
            switch route {
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
            case .comingLater(let feature): ComingLaterView(feature: feature)
            }
        }
    }
}
