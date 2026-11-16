import Foundation

/// After the car accepts a command, the status Volta reads straight away
/// usually still shows the old state: the car reports the change over Fleet
/// Telemetry a moment later (well under a second when it streams, up to its
/// 15-second reporting interval at worst). So the status is read again after
/// these pauses until it shows what was asked for: about 0.5, 2, 5, 11 and 19
/// seconds after the first read.
enum CommandSettle {
    static let pauses: [Duration] = [.milliseconds(500), .milliseconds(1500), .seconds(3), .seconds(6), .seconds(8)]
}

extension VehicleCommand {
    /// Whether `status` shows what this command asked for. nil when the status
    /// has no field for it (honk, frunk, seat heat), so there is nothing to
    /// wait for. An unknown value counts as not yet shown.
    func isReflected(in status: VehicleStatus) -> Bool? {
        switch self {
        case .lock: return status.locked == true
        case .unlock: return status.locked == false
        case .climateOn: return status.climateOn == true
        case .climateOff: return status.climateOn == false
        case .sentryOn: return status.sentryMode == true
        case .sentryOff: return status.sentryMode == false
        case .chargeStart: return status.chargingState == .charging
        case .chargeStop:
            guard let state = status.chargingState else { return false }
            return state != .charging
        case .setChargeLimit(let percent): return status.chargeLimit == percent
        case .setTemperatures(let driver, _):
            guard let observed = status.driverTempSettingC else { return false }
            return abs(observed - driver) < 0.25
        case .openChargePort: return status.chargePortDoorOpen == true
        case .closeChargePort: return status.chargePortDoorOpen == false
        // Defrost runs the climate; turning it off leaves the climate as it was.
        case .defrost(true): return status.climateOn == true
        case .defrost(false), .actuateTrunk, .windowControl, .honk, .flash,
             .triggerHomeLink, .wakeUp, .seatHeater, .steeringWheelHeat:
            return nil
        }
    }

    /// The status shows this command's result, so it is worth reading again.
    var hasObservableState: Bool {
        switch self {
        case .lock, .unlock, .climateOn, .climateOff, .sentryOn, .sentryOff, .chargeStart, .chargeStop,
             .setChargeLimit, .setTemperatures, .openChargePort, .closeChargePort, .defrost(true):
            true
        case .defrost(false), .actuateTrunk, .windowControl, .honk, .flash, .triggerHomeLink, .wakeUp,
             .seatHeater, .steeringWheelHeat:
            false
        }
    }
}
