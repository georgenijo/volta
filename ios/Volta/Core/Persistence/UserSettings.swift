import Foundation
import Observation

@MainActor @Observable
final class UserSettings {
    @ObservationIgnored private let defaults: UserDefaults?
    var units: UnitPreferences { didSet { if let data = try? JSONEncoder().encode(units) { defaults?.set(data, forKey: "units") } } }
    var serverURL: String { didSet { defaults?.set(serverURL, forKey: "serverURL") } }
    var appLockEnabled: Bool { didSet { defaults?.set(appLockEnabled, forKey: "appLockEnabled") } }
    var selectedVehicleID: Int? { didSet { defaults?.set(selectedVehicleID, forKey: "selectedVehicleID") } }
    /// The user picked `selectedVehicleID`; only automatic choices may move to
    /// a vehicle that has data. A selection saved before this flag existed has
    /// unknown provenance, so it is kept as the user's.
    var selectedVehicleIsExplicit: Bool { didSet { defaults?.set(selectedVehicleIsExplicit, forKey: "selectedVehicleIsExplicit") } }
    var emptyDemo: Bool { didSet { defaults?.set(emptyDemo, forKey: "emptyDemo") } }
    var demoMode: Bool { didSet { defaults?.set(demoMode, forKey: "demoMode") } }
    /// Show a Live Activity while the car is being driven (charging always shows one).
    var drivingLiveActivity: Bool { didSet { defaults?.set(drivingLiveActivity, forKey: "drivingLiveActivity") } }
    /// nil keeps launch-only settings entirely in memory.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        units = defaults?.data(forKey: "units").flatMap { try? JSONDecoder().decode(UnitPreferences.self, from: $0) } ?? .default
        serverURL = defaults?.string(forKey: "serverURL") ?? ""
        appLockEnabled = defaults?.bool(forKey: "appLockEnabled") ?? false
        let selectedVehicleID = defaults?.object(forKey: "selectedVehicleID") as? Int
        self.selectedVehicleID = selectedVehicleID
        selectedVehicleIsExplicit = defaults?.object(forKey: "selectedVehicleIsExplicit") as? Bool ?? (selectedVehicleID != nil)
        demoMode = defaults?.bool(forKey: "demoMode") ?? false
        emptyDemo = defaults?.bool(forKey: "emptyDemo") ?? false
        drivingLiveActivity = defaults?.bool(forKey: "drivingLiveActivity") ?? false
    }
}
