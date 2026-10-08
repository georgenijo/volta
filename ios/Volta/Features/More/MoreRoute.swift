import SwiftUI

/// Every destination reachable from More. Hashable so it can drive a NavigationStack path.
enum MoreRoute: Hashable, Sendable {
    case stats, batteryHealth, batteryClimate, mileage, firmware, specs
    case switchVehicle, settings
    case comingLater(ComingLaterFeature)
}

enum ComingLaterFeature: String, Hashable, Sendable, CaseIterable {
    case automations, tires, maintenance, chargerMap, planRoute

    var title: String {
        switch self {
        case .automations: "Automations"
        case .tires: "Tires"
        case .maintenance: "Maintenance"
        case .chargerMap: "Charger Map"
        case .planRoute: "Plan a route"
        }
    }

    var symbol: String {
        switch self {
        case .automations: "bolt"
        case .tires: "circle.circle"
        case .maintenance: "wrench.and.screwdriver"
        case .chargerMap: "mappin.and.ellipse"
        case .planRoute: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    var blurb: String {
        switch self {
        case .automations: "Rules that react to your car — like a nudge when you get home below 30% or sentry on at work."
        case .tires: "Tire pressure history and rotation reminders, straight from your car's TPMS readings."
        case .maintenance: "A private service log: rotations, filters, wipers and anything else you want to remember."
        case .chargerMap: "Nearby chargers with live stall counts, alongside the places you already charge."
        case .planRoute: "Trip planning with arrival charge estimates based on your own driving efficiency."
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
            case .comingLater(let feature): ComingLaterView(feature: feature)
            }
        }
    }
}
