import SwiftUI
import WidgetKit

@main
struct VoltaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        VoltaHomeWidget()
        VoltaAccessoryWidget()
        VoltaGlanceWidgets()
        ChargingLiveActivity()
        DrivingLiveActivity()
        VehicleLockControl()
        VehicleClimateControl()
        VehicleChargePortControl()
        VehicleBatteryControl()
    }
}
