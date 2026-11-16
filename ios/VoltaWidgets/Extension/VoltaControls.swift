import AppIntents
import SwiftUI
import WidgetKit

// Control Center, Lock Screen and Action button controls. State comes from the
// App Group snapshot the widgets use; with no snapshot (not paired, demo mode)
// every control shows a neutral "Unknown". Actions run in the app process
// (see Shared/VoltaControlIntents.swift); the extension never sees credentials.

/// One read of the snapshot for a control.
struct VehicleControlState: Sendable {
    var snapshot: WidgetSnapshot?
    var now: Date

    var readout: VehicleReadout? { snapshot.map { VehicleReadout($0, now: now) } }
    var locked: Bool? { snapshot?.locked }
    var climateOn: Bool? { snapshot?.climateOn }

    /// The text under a control's title; stale readings carry their age.
    func value(_ text: (VehicleReadout) -> String) -> String {
        guard let readout else { return VehicleReadoutUnknown.value }
        return readout.controlValue(text(readout))
    }
}

struct SnapshotControlProvider: ControlValueProvider {
    var previewValue: VehicleControlState { VehicleControlState(snapshot: .fixture(), now: .now) }

    func currentValue() async throws -> VehicleControlState {
        VehicleControlState(snapshot: WidgetSnapshotStore.read(), now: .now)
    }
}

enum VoltaControlKind {
    static let lock = "com.georgenijo.volta.control.lock"
    static let climate = "com.georgenijo.volta.control.climate"
    static let chargePort = "com.georgenijo.volta.control.charge-port"
    static let battery = "com.georgenijo.volta.control.battery"
}

/// Lock toggle. Unknown state shows as off with "Unknown"; tapping it locks.
struct VehicleLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoltaControlKind.lock, provider: SnapshotControlProvider()) { state in
            ControlWidgetToggle(isOn: state.locked == true, action: SetVehicleLockIntent()) {
                Text("Car Lock")
            } valueLabel: { isOn in
                let label = VehicleToggleLabel.lock(observed: state.locked, isOn: isOn, readout: state.readout)
                Label(label.text, systemImage: label.symbol)
                    .controlWidgetActionHint(isOn ? "Unlock" : "Lock")
            }
            .tint(WTheme.blue)
        }
        .displayName("Car Lock")
        .description("Lock or unlock your car. Unlocking needs Face ID or your passcode.")
    }
}

/// Climate toggle. Unknown state shows as off with "Unknown"; tapping it turns climate on.
struct VehicleClimateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoltaControlKind.climate, provider: SnapshotControlProvider()) { state in
            ControlWidgetToggle(isOn: state.climateOn == true, action: SetVehicleClimateIntent()) {
                Text("Climate")
            } valueLabel: { isOn in
                let label = VehicleToggleLabel.climate(observed: state.climateOn, isOn: isOn, readout: state.readout)
                Label(label.text, systemImage: label.symbol)
                    .controlWidgetActionHint(isOn ? "Turn Off" : "Turn On")
            }
            .tint(WTheme.blue)
        }
        .displayName("Car Climate")
        .description("Turn your car’s climate on or off.")
    }
}

/// Opens the charge port; shows the charging state.
struct VehicleChargePortControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoltaControlKind.chargePort, provider: SnapshotControlProvider()) { state in
            ControlWidgetButton(action: OpenChargePortControlIntent()) {
                Label {
                    Text("Charge Port")
                    Text(state.value { $0.chargingText })
                } icon: {
                    Image(systemName: state.readout?.charging == .charging ? "bolt.fill" : "powerplug")
                }
                .controlWidgetActionHint("Open")
            }
            .tint(WTheme.green)
        }
        .displayName("Open Charge Port")
        .description("Open your car’s charge port door. Shows the charging state.")
    }
}

/// Battery level and range; opens Volta.
struct VehicleBatteryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoltaControlKind.battery, provider: SnapshotControlProvider()) { state in
            ControlWidgetButton(action: OpenVoltaIntent()) {
                Label {
                    Text("Battery")
                    Text(state.value { $0.batteryText })
                } icon: {
                    Image(systemName: state.readout?.batterySymbol ?? "bolt.car")
                }
                .controlWidgetActionHint("Open Volta")
            }
            .tint(WTheme.blue)
        }
        .displayName("Car Battery")
        .description("See your car’s battery and range. Opens Volta.")
    }
}
