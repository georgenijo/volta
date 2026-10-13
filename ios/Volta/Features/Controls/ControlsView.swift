import SwiftUI

@MainActor @Observable
final class ControlsModel {
    var status: VehicleStatus?
    var locked: Bool?
    var chargingState: ChargingState?
    var chargeLimit: Int?
    var climateOn: Bool?
    var sentry: Bool?
    private var refreshGeneration = 0

    init(status: VehicleStatus?) { apply(status) }

    func apply(_ status: VehicleStatus?) {
        self.status = status
        guard let status else { return }
        locked = status.locked
        chargingState = status.chargingState
        chargeLimit = status.chargeLimit
        climateOn = status.climateOn
        sentry = status.sentryMode
    }

    func refresh(dataSource: any VoltaDataSource, vehicleID: Int,
                 surfaces: (any VehicleSurfaces)? = nil) async {
        refreshGeneration += 1
        let token = refreshGeneration
        let issued = surfaces?.nextStatusToken()
        guard let fresh = try? await dataSource.status(vehicleID: vehicleID),
              token == refreshGeneration, !Task.isCancelled else { return }
        apply(fresh)
        if let surfaces, let issued {
            surfaces.publish(VehicleRefresh(status: fresh, issued: issued), dataSource: dataSource)
        }
    }

    @discardableResult
    func send(_ command: VehicleCommand, label: String, coordinator: VehicleCommandCoordinator,
              dataSource: any VoltaDataSource, vehicleID: Int,
              surfaces: (any VehicleSurfaces)? = nil, simulate: (() -> Void)? = nil) async -> Bool {
        refreshGeneration += 1
        let outcome = await coordinator.perform(command, label: label, dataSource: dataSource, vehicleID: vehicleID)
        switch outcome {
        case .succeeded(let simulated):
            if simulated { simulate?() }
            else { await refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
            return true
        case .failed, .unknown:
            return false
        }
    }

    func setLocked(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                   vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .lock : .unlock, label: value ? "Lock" : "Unlock", coordinator: coordinator,
                   dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) { self.locked = value }
    }

    func setCharging(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                     vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .chargeStart : .chargeStop, label: value ? "Start charging" : "Stop charging",
                   coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) {
            self.chargingState = value ? .charging : .stopped
        }
    }

    func setClimate(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                    vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .climateOn : .climateOff, label: value ? "Start climate" : "Stop climate",
                   coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) { self.climateOn = value }
    }

    func setSentry(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                   vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .sentryOn : .sentryOff, label: value ? "Arm Sentry" : "Disarm Sentry",
                   coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) { self.sentry = value }
    }

    func adjustChargeLimit(by delta: Int, coordinator: VehicleCommandCoordinator,
                           dataSource: any VoltaDataSource, vehicleID: Int,
                           surfaces: (any VehicleSurfaces)? = nil) async {
        guard let old = chargeLimit else { return }
        let value = min(100, max(50, old + delta))
        guard value != old else { return }
        await send(.setChargeLimit(percent: value), label: "Set charge limit to \(value)%",
                   coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) { self.chargeLimit = value }
    }
}

struct ControlsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.vehicleSurfaces) private var surfaces
    @Environment(\.vehicleCommandCoordinator) private var sharedCoordinator
    @Environment(AppModel.self) private var app: AppModel?

    let vehicleName: String?
    @State private var model: ControlsModel
    @State private var localCoordinator = VehicleCommandCoordinator()
    @State private var confirmation: CommandConfirmation?
    @State private var controlNotice: String?
    private let iconInset: CGFloat = 52

    init(initialStatus: VehicleStatus?, vehicleName: String?) {
        self.vehicleName = vehicleName
        _model = State(initialValue: ControlsModel(status: initialStatus))
    }

    private var coordinator: VehicleCommandCoordinator { sharedCoordinator ?? localCoordinator }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity
                    readiness.padding(.top, VoltaSpacing.lg)
                    if let controlNotice {
                        InlineBanner(systemImage: "location.slash", message: controlNotice, tint: .voltaAmber)
                            .padding(.top, VoltaSpacing.md)
                    }
                    access.padding(.top, VoltaSpacing.xxl)
                    chargingSection.padding(.top, VoltaSpacing.xxl)
                    comfort.padding(.top, VoltaSpacing.xxl)
                    security.padding(.top, VoltaSpacing.xxl)
                    locate.padding(.top, VoltaSpacing.xxl)
                }
                .padding(.horizontal, VoltaSpacing.screen + 4)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.controls")
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { activityBanner }
            .background(Color.voltaBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.voltaBackground)
        .presentationCornerRadius(34)
        .preferredColorScheme(.dark)
        .task(id: vehicleID) { await load() }
        .alert(item: $confirmation) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  primaryButton: .cancel(), secondaryButton: .destructive(Text(item.button)) { run(item.command, label: item.label) })
        }
    }

    private func load() async {
        await coordinator.refreshCapabilities(dataSource: dataSource, vehicleID: vehicleID)
        await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces)
    }

    private var header: some View {
        ZStack {
            Text("CONTROLS").font(.system(.headline, weight: .semibold)).tracking(3)
                .foregroundStyle(Color.voltaTextPrimary).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.controls")
            HStack {
                GlassCircleButton(systemImage: "xmark", size: 52, accessibilityLabel: "Close") { dismiss() }
                Spacer()
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary).frame(width: 52, height: 52).contentShape(Circle())
                }.glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Refresh controls")
            }
        }
        .padding(.horizontal, VoltaSpacing.screen - 4).padding(.top, VoltaSpacing.xl)
        .padding(.bottom, VoltaSpacing.md).background(Color.voltaBackground.opacity(0.94))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let freshness = model.status?.telemetryFreshness {
                Text(freshness.label).font(.caption).foregroundStyle(Color.voltaTextSecondary)
            }
            Text(vehicleName ?? "Vehicle").font(.system(.title, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
            if let state = model.status?.state {
                HStack(spacing: 8) {
                    StatusDot(color: state.color, size: 6)
                    Text(state.displayName).font(.subheadline).foregroundStyle(Color.voltaTextSecondary)
                }
            }
        }.padding(.top, VoltaSpacing.lg)
    }

    @ViewBuilder private var readiness: some View {
        if dataSource.simulatesVehicleCommands {
            InlineBanner(systemImage: "theatermasks", message: "Demo mode: controls are simulated on this device. No vehicle is contacted.", tint: .voltaBlue)
        } else if let capability = coordinator.capability(dataSource: dataSource, vehicleID: vehicleID), !capability.available {
            VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                InlineBanner(systemImage: readinessSymbol(capability.reason), message: readinessMessage(capability.reason), tint: .voltaAmber)
                if needsTeslaConsent(capability.reason) {
                    PillButton("Enable vehicle controls", systemImage: "key.horizontal", style: .accent) {
                        Task { await app?.tesla.refresh(); app?.tesla.enableVehicleControls() }
                    }
                    .disabled(app?.tesla.isBusy == true)
                    Text(TeslaLinkModel.commandScopeDisclosure).font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                    if let message = app?.tesla.failureMessage {
                        InlineBanner(systemImage: "exclamationmark.circle", message: message, tint: .voltaAmber)
                    }
                }
            }
        } else if coordinator.capability(dataSource: dataSource, vehicleID: vehicleID) == nil {
            InlineBanner(systemImage: "arrow.triangle.2.circlepath", message: "Checking command readiness…", tint: .voltaBlue)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Access", rule: true) { EmptyView() }.padding(.bottom, VoltaSpacing.sm)
            stateControl(StateDisplay.doors(model.locked), title: "Doors", subtitle: "Observed lock state",
                         value: model.locked, on: .lock, off: .unlock, onLabel: "Lock", offLabel: "Unlock") { value in
                confirm(value ? .lock : .unlock, label: value ? "Lock" : "Unlock",
                        title: value ? "Lock the vehicle?" : "Unlock the vehicle?",
                        message: value ? "This will remotely lock all doors." : "This will remotely unlock all doors. Make sure the vehicle is secure.")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "car.side.front.open", title: "Frunk", subtitle: "Front trunk", button: "Open", command: .actuateTrunk(whichTrunk: .front)) {
                confirm(.actuateTrunk(whichTrunk: .front), label: "Open frunk", title: "Open the frunk?", message: "The frunk can only be closed by hand. Make sure nothing is above it.")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "car.side.rear.open", title: "Trunk", subtitle: "Rear trunk", button: "Open", command: .actuateTrunk(whichTrunk: .rear)) {
                confirm(.actuateTrunk(whichTrunk: .rear), label: "Open trunk", title: "Actuate the trunk?", message: "This sends Tesla's remote trunk actuation command. Check clearance first.")
            }
            HairlineDivider(leadingInset: iconInset)
            pairRow(icon: "powerplug", title: "Charge port", subtitle: chargePortStatus,
                    left: ("Open", .openChargePort, { confirm(.openChargePort, label: "Open charge port", title: "Open the charge port?", message: "This remotely opens the vehicle's charge port door.") }),
                    right: ("Close", .closeChargePort, { confirm(.closeChargePort, label: "Close charge port", title: "Close the charge port?", message: "Make sure no charging connector is inserted.") }))
            HairlineDivider()
            pairRow(icon: "window.vertical.open", title: "Windows", subtitle: "Observed position unavailable",
                    left: ("Vent", .windowControl(command: .vent), { confirm(.windowControl(command: .vent), label: "Vent windows", title: "Vent the windows?", message: "This slightly opens the windows and may expose the cabin to weather.") }),
                    right: ("Close", .windowControl(command: .close), { confirm(.windowControl(command: .close), label: "Close windows", title: "Close the windows?", message: "Make sure hands and objects are clear of every window.") }))
            HairlineDivider()
            actionRow(icon: "power", title: "Wake vehicle", subtitle: "Request the vehicle to wake", button: "Wake", command: .wakeUp) {
                run(.wakeUp, label: "Wake request")
            }
        }
    }

    private var chargePortStatus: String {
        let door = model.status?.chargePortDoorOpen.map { $0 ? "Open" : "Closed" } ?? "Door state not recorded"
        let latch: String? = switch model.status?.chargePortLatch {
        case "ChargePortLatchEngaged": "Latched"
        case "ChargePortLatchDisengaged": "Unlatched"
        case "ChargePortLatchBlocking": "Latch blocked"
        default: nil
        }
        return latch.map { "\(door) · \($0)" } ?? door
    }

    private var chargingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Charging", rule: true) { EmptyView() }.padding(.bottom, VoltaSpacing.sm)
            stateControl(StateDisplay.charging(model.chargingState), title: "Charging", subtitle: "Observed charging state",
                         value: model.chargingState.map { $0 == .charging }, on: .chargeStart, off: .chargeStop,
                         onLabel: "Start", offLabel: "Stop") { value in
                run(value ? .chargeStart : .chargeStop, label: value ? "Start charging" : "Stop charging")
            }
            HStack {
                Text("Charge limit").font(.voltaRowSubtitle).foregroundStyle(Color.voltaTextSecondary)
                Spacer()
                LimitStepper(value: model.chargeLimit, isEnabled: canSend(.setChargeLimit(percent: model.chargeLimit ?? 80))) { delta in
                    Task { await model.adjustChargeLimit(by: delta, coordinator: coordinator, dataSource: dataSource,
                                                         vehicleID: vehicleID, surfaces: surfaces) }
                }
            }.padding(.leading, iconInset).padding(.vertical, VoltaSpacing.sm)
        }
    }

    private var comfort: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Comfort", rule: true) { EmptyView() }.padding(.bottom, VoltaSpacing.sm)
            stateControl(StateDisplay.climate(model.climateOn), title: "Climate", subtitle: "Observed climate state",
                         value: model.climateOn, on: .climateOn, off: .climateOff, onLabel: "On", offLabel: "Off") { value in
                run(value ? .climateOn : .climateOff, label: value ? "Start climate" : "Stop climate")
            }
            HairlineDivider(leadingInset: iconInset)
            NavigationLink { ClimateControlsView(model: model) } label: {
                ListRow(systemImage: "thermometer.medium", title: "Climate controls", subtitle: "Temperature, seats, steering & defrost", showsChevron: true)
            }.buttonStyle(.plain)
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Security", rule: true) { EmptyView() }.padding(.bottom, VoltaSpacing.sm)
            stateControl(StateDisplay.sentry(model.sentry), title: "Sentry", subtitle: "Observed security state",
                         value: model.sentry, on: .sentryOn, off: .sentryOff, onLabel: "Arm", offLabel: "Disarm") { value in
                run(value ? .sentryOn : .sentryOff, label: value ? "Arm Sentry" : "Disarm Sentry")
            }
        }
    }

    private var locate: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Locate & nearby", rule: true) { EmptyView() }.padding(.bottom, VoltaSpacing.sm)
            actionRow(icon: "headlight.high.beam.fill", title: "Flash lights", subtitle: "Flash the exterior lights", button: "Flash", command: .flash) {
                run(.flash, label: "Flash lights")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "megaphone.fill", title: "Honk horn", subtitle: "Sound the vehicle horn", button: "Honk", command: .honk) {
                confirm(.honk, label: "Honk horn", title: "Honk the horn?", message: "This will immediately sound the vehicle horn and may disturb people nearby.")
            }
            HairlineDivider(leadingInset: iconInset)
            ListRow(systemImage: "location.fill", iconColor: .voltaTextTertiary, title: "Locate sound",
                    subtitle: "Locate sound isn’t supported by Tesla’s command service") {
                Text("Unavailable").font(.footnote).foregroundStyle(Color.voltaTextTertiary)
            }
            HairlineDivider(leadingInset: iconInset)
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let nearby = Self.homeLinkCommand(status: model.status, now: context.date)
                actionRow(icon: "house.fill", title: "HomeLink",
                          subtitle: nearby == nil ? "Needs a location observed within 5 minutes" : "Activate a nearby garage door",
                          button: "Activate", command: nearby ?? .triggerHomeLink(latitude: 0, longitude: 0), extraEnabled: nearby != nil) {
                    guard let command = homeLinkCommand else { return }
                    confirm(command, label: "Activate HomeLink", title: "Activate HomeLink now?",
                            message: "This may open or close a nearby garage door. Confirm the area is clear and you can observe the door.")
                }
            }
        }
    }

    private var homeLinkCommand: VehicleCommand? {
        Self.homeLinkCommand(status: model.status)
    }

    static func homeLinkCommand(status: VehicleStatus?, now: Date = .now) -> VehicleCommand? {
        guard let status, let observedAt = status.locationUpdatedAt, let location = status.location else { return nil }
        let age = now.timeIntervalSince(observedAt)
        guard (0...300).contains(age) else { return nil }
        return .triggerHomeLink(latitude: location.latitude, longitude: location.longitude)
    }

    @ViewBuilder
    private func stateControl(_ display: StateDisplay, title: String, subtitle: String, value: Bool?,
                              on: VehicleCommand, off: VehicleCommand, onLabel: String, offLabel: String,
                              send: @escaping (Bool) -> Void) -> some View {
        if let value {
            let command = value ? off : on
            ToggleRow(systemImage: display.symbol, title: title, subtitle: subtitle, status: display.text,
                      isOn: Binding(get: { value }, set: { send($0) }), onColor: .voltaGreen, isEnabled: canSend(command))
        } else {
            VStack(spacing: VoltaSpacing.sm) {
                ListRow(systemImage: display.symbol, iconColor: .voltaTextTertiary, title: title, subtitle: subtitle) {
                    Text("Unknown").font(.system(.body, weight: .medium)).foregroundStyle(Color.voltaTextTertiary)
                }
                HStack(spacing: VoltaSpacing.lg) {
                    commandButton(offLabel, command: off) { send(false) }
                    commandButton(onLabel, command: on) { send(true) }
                }.padding(.leading, iconInset)
            }.padding(.bottom, VoltaSpacing.sm)
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String, button: String,
                           command: VehicleCommand, extraEnabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        ListRow(systemImage: icon, title: title, subtitle: subtitle) {
            PillButton(button, action: action).opacity(canSend(command) && extraEnabled ? 1 : 0.45)
                .disabled(!canSend(command) || !extraEnabled)
        }
    }

    private func pairRow(icon: String, title: String, subtitle: String,
                         left: (String, VehicleCommand, () -> Void), right: (String, VehicleCommand, () -> Void)) -> some View {
        VStack(spacing: VoltaSpacing.md) {
            ListRow(systemImage: icon, title: title, subtitle: subtitle)
            HStack(spacing: VoltaSpacing.lg) {
                commandButton(left.0, command: left.1, action: left.2)
                commandButton(right.0, command: right.1, action: right.2)
            }
        }.padding(.bottom, VoltaSpacing.lg)
    }

    private func commandButton(_ title: String, command: VehicleCommand, action: @escaping () -> Void) -> some View {
        PillButton(title, size: .wide, action: action).opacity(canSend(command) ? 1 : 0.45).disabled(!canSend(command))
    }
    private func canSend(_ command: VehicleCommand) -> Bool {
        coordinator.canStart(command, dataSource: dataSource, vehicleID: vehicleID)
    }
    private func run(_ command: VehicleCommand, label: String) {
        Task {
            if case .triggerHomeLink = command, homeLinkCommand != command {
                controlNotice = "The vehicle location changed or expired. Refresh status before activating HomeLink."
                return
            }
            controlNotice = nil
            await model.send(command, label: label, coordinator: coordinator, dataSource: dataSource,
                             vehicleID: vehicleID, surfaces: surfaces)
        }
    }
    private func confirm(_ command: VehicleCommand, label: String, title: String, message: String) {
        guard canSend(command) else { return }
        confirmation = CommandConfirmation(command: command, label: label, title: title, message: message, button: label)
    }

    @ViewBuilder private var activityBanner: some View {
        VehicleCommandActivityBanner(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID) {
            Task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
        }
    }
    private func needsTeslaConsent(_ reason: String?) -> Bool {
        ["authorization_required", "reauthorization_required", "command_scope_required"].contains(reason)
    }
    private func readinessSymbol(_ reason: String?) -> String {
        needsTeslaConsent(reason) ? "key.horizontal" : "antenna.radiowaves.left.and.right.slash"
    }
    private func readinessMessage(_ reason: String?) -> String {
        switch reason {
        case "command_scope_required": "Vehicle controls need one-time Tesla consent. Read-only telemetry remains connected."
        case "authorization_required": "Connect Tesla before enabling vehicle controls."
        case "reauthorization_required": "Reconnect Tesla to restore vehicle control access."
        case "vehicle_not_found": "This vehicle is not configured for commands."
        case "stub_mode": "This server is in simulation mode; live controls are unavailable."
        case "intent_storage_unavailable": "Secure command storage is unavailable. No vehicle command will be sent."
        default: "Vehicle controls are not enabled on this server. Live status remains read-only."
        }
    }
}

private struct CommandConfirmation: Identifiable {
    let id = UUID()
    let command: VehicleCommand
    let label: String
    let title: String
    let message: String
    let button: String
}

struct LimitStepper: View {
    var value: Int?
    var isEnabled: Bool
    var change: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            button("minus", delta: -5, label: "Decrease limit")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map(String.init) ?? "—").font(.system(.title3, weight: .semibold)).monospacedDigit()
                if value != nil { Text("%").font(.footnote).foregroundStyle(Color.voltaTextSecondary) }
            }.frame(minWidth: 64).foregroundStyle(value == nil ? Color.voltaTextTertiary : Color.voltaTextPrimary)
            button("plus", delta: 5, label: "Increase limit")
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous).fill(Color.voltaRaised)
            .overlay(RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous).strokeBorder(Color.voltaHairline)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(value.map { "Charge limit \($0) percent" } ?? "Charge limit unknown")
    }
    private var interactive: Bool { isEnabled && value != nil }
    private func button(_ symbol: String, delta: Int, label: String) -> some View {
        Button { change(delta) } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary.opacity(interactive ? 1 : 0.4)).frame(width: 48, height: 40)
        }.buttonStyle(VoltaPressStyle()).disabled(!interactive).accessibilityLabel(label)
    }
}

struct ClimateControlsView: View {
    let model: ControlsModel
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss
    @Environment(\.vehicleCommandCoordinator) private var sharedCoordinator
    @Environment(\.vehicleSurfaces) private var surfaces
    @State private var localCoordinator = VehicleCommandCoordinator()
    @State private var driverTargetC: Double
    @State private var passengerTargetC: Double

    init(model: ControlsModel) {
        self.model = model
        let observed = model.status?.driverTempSettingC ?? 20
        _driverTargetC = State(initialValue: observed)
        _passengerTargetC = State(initialValue: observed)
    }
    private var coordinator: VehicleCommandCoordinator { sharedCoordinator ?? localCoordinator }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VoltaHeader("Climate", identifier: "screen.climate") {
                    GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
                } trailing: { EmptyView() }
                .padding(.horizontal, -(VoltaSpacing.screen - 4) + 4)
                VStack(spacing: 0) {
                    ListRow(systemImage: "thermometer.medium", title: "Cabin", subtitle: "Observed inside temperature") {
                        Text(units.formatTemperature(model.status?.insideTempC)).foregroundStyle(Color.voltaTextSecondary)
                    }
                    HairlineDivider(leadingInset: 52)
                    temperatureControl
                    HairlineDivider(leadingInset: 52)
                    seatControl(title: "Driver seat", heater: 0)
                    HairlineDivider(leadingInset: 52)
                    seatControl(title: "Front passenger", heater: 1)
                    HairlineDivider(leadingInset: 52)
                    seatControl(title: "Rear left", heater: 2)
                    HairlineDivider(leadingInset: 52)
                    seatControl(title: "Rear center", heater: 4)
                    HairlineDivider(leadingInset: 52)
                    seatControl(title: "Rear right", heater: 5)
                    HairlineDivider(leadingInset: 52)
                    binaryControl(icon: "steeringwheel.and.heat.waves", title: "Steering wheel heat",
                                  off: .steeringWheelHeat(on: false), on: .steeringWheelHeat(on: true))
                    HairlineDivider(leadingInset: 52)
                    binaryControl(icon: "windshield.front.and.heat.waves", title: "Defrost",
                                  off: .defrost(on: false), on: .defrost(on: true))
                }.padding(.top, VoltaSpacing.lg)
                Text("Climate controls show explicit actions because heater and defrost state is not present in observed telemetry.")
                    .font(.footnote).foregroundStyle(Color.voltaTextSecondary).padding(.top, VoltaSpacing.xl)
            }.padding(.horizontal, VoltaSpacing.screen + 4)
        }
        .accessibilityIdentifier("scroll.climate")
        .overlay(alignment: .bottom) {
            VehicleCommandActivityBanner(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID) {
                Task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
            }
        }
        .background(Color.voltaBackground.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
    }

    private var temperatureControl: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            temperatureRow(title: "Driver target", value: $driverTargetC)
            temperatureRow(title: "Passenger target", value: $passengerTargetC)
            let command = VehicleCommand.setTemperatures(driverTempC: driverTargetC,
                                                          passengerTempC: passengerTargetC)
            PillButton("Set cabin temperatures", size: .wide, style: .accent) {
                send(command, label: "Set cabin temperatures")
            }
            .disabled(!canSend(command)).opacity(canSend(command) ? 1 : 0.45)
            .padding(.leading, 52)
        }.padding(.bottom, VoltaSpacing.md)
    }

    private func temperatureRow(title: String, value: Binding<Double>) -> some View {
        ListRow(systemImage: "dial.medium", title: title, subtitle: "15–28 °C") {
            HStack(spacing: VoltaSpacing.sm) {
                Button { value.wrappedValue = max(15, value.wrappedValue - 0.5) } label: {
                    Image(systemName: "minus.circle.fill")
                }.accessibilityLabel("Decrease \(title.lowercased())")
                Text(units.formatTemperature(value.wrappedValue)).monospacedDigit()
                    .frame(minWidth: 58)
                Button { value.wrappedValue = min(28, value.wrappedValue + 0.5) } label: {
                    Image(systemName: "plus.circle.fill")
                }.accessibilityLabel("Increase \(title.lowercased())")
            }.foregroundStyle(Color.voltaTextPrimary)
        }
    }

    private func seatControl(title: String, heater: Int) -> some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            ListRow(systemImage: "carseat.left.and.heat.waves", title: title, subtitle: "Choose heat level")
            HStack(spacing: VoltaSpacing.sm) {
                ForEach(0...3, id: \.self) { level in
                    let command = VehicleCommand.seatHeater(heater: heater, level: level)
                    PillButton(level == 0 ? "Off" : "\(level)", size: .wide) { send(command, label: "Set \(title) heat to \(level)") }
                        .disabled(!canSend(command)).opacity(canSend(command) ? 1 : 0.45)
                        .accessibilityIdentifier("button.seat.\(heater).\(level)")
                }
            }.padding(.leading, 52).padding(.bottom, VoltaSpacing.sm)
        }
    }

    private func binaryControl(icon: String, title: String, off: VehicleCommand, on: VehicleCommand) -> some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            ListRow(systemImage: icon, title: title, subtitle: "Observed state unavailable")
            HStack(spacing: VoltaSpacing.lg) {
                PillButton("Off", size: .wide) { send(off, label: "Turn off \(title.lowercased())") }
                    .disabled(!canSend(off)).opacity(canSend(off) ? 1 : 0.45)
                PillButton("On", size: .wide) { send(on, label: "Turn on \(title.lowercased())") }
                    .disabled(!canSend(on)).opacity(canSend(on) ? 1 : 0.45)
            }.padding(.leading, 52).padding(.bottom, VoltaSpacing.sm)
        }
    }

    private func canSend(_ command: VehicleCommand) -> Bool {
        coordinator.canStart(command, dataSource: dataSource, vehicleID: vehicleID)
    }
    private func send(_ command: VehicleCommand, label: String) {
        Task { await model.send(command, label: label, coordinator: coordinator, dataSource: dataSource,
                                vehicleID: vehicleID, surfaces: surfaces) }
    }
}

private struct VehicleCommandActivityBanner: View {
    let coordinator: VehicleCommandCoordinator
    let dataSource: any VoltaDataSource
    let vehicleID: Int
    let refreshObservedStatus: () -> Void
    private struct Confirmation: Identifiable {
        let id = UUID()
        let activity: VehicleCommandCoordinator.Activity
        let isRetry: Bool
    }
    @State private var confirmation: Confirmation?

    var body: some View {
        Group {
            if let activity = coordinator.activity(dataSource: dataSource, vehicleID: vehicleID) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: VoltaSpacing.md) {
                        if activity.phase == .pending { ProgressView().tint(Color.voltaTextPrimary) }
                        else { Image(systemName: symbol(activity.phase)).foregroundStyle(color(activity.phase)) }
                        Text(activity.message).font(.subheadline).foregroundStyle(Color.voltaTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        action(activity, now: context.date)
                    }
                    .padding(.horizontal, VoltaSpacing.lg).padding(.vertical, VoltaSpacing.md)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: VoltaRadius.control))
                    .padding(.horizontal, VoltaSpacing.screen).padding(.bottom, VoltaSpacing.xl)
                }
            }
        }
        .alert(item: $confirmation) { item in
            let activity = item.activity
            if item.isRetry {
                return Alert(title: Text("Retry \(activity.label.lowercased())?"),
                             message: Text("If the original request was not accepted, this can execute it now. " + activity.command.retryCaution),
                             primaryButton: .cancel(), secondaryButton: .destructive(Text("Retry \(activity.label)")) {
                    Task {
                        let result = await coordinator.retry(activity.id, dataSource: dataSource, vehicleID: vehicleID)
                        if case .succeeded(let simulated) = result, !simulated { refreshObservedStatus() }
                    }
                })
            }
            return Alert(title: Text("Allow new vehicle commands?"),
                         message: Text("The earlier \(activity.label.lowercased()) action may have run. Only continue if you checked the vehicle. This clears the saved request and allows a new deliberate action."),
                         primaryButton: .cancel(), secondaryButton: .destructive(Text("I checked the vehicle")) {
                coordinator.acknowledgeCheckedVehicle(activity.id, dataSource: dataSource, vehicleID: vehicleID)
            })
        }
    }

    @ViewBuilder private func action(_ activity: VehicleCommandCoordinator.Activity, now: Date) -> some View {
        if activity.requiresAcknowledgement {
            Button("I checked the vehicle") { confirmation = Confirmation(activity: activity, isRetry: false) }
                .buttonStyle(.borderedProminent).fixedSize()
                .disabled(coordinator.isBusy(dataSource: dataSource, vehicleID: vehicleID))
        } else if activity.canRetry {
            let remaining = max(0, activity.retryNotBefore?.timeIntervalSince(now) ?? 0)
            VStack(spacing: 4) {
                Button(remaining > 0 ? "Retry in \(Int(ceil(remaining)))s" : "Retry request") {
                    confirmation = Confirmation(activity: activity, isRetry: true)
                }
                .buttonStyle(.bordered).fixedSize()
                .disabled(remaining > 0 || coordinator.isBusy(dataSource: dataSource, vehicleID: vehicleID))
                Button("I checked the vehicle") { confirmation = Confirmation(activity: activity, isRetry: false) }
                    .font(.caption).foregroundStyle(Color.voltaTextSecondary).fixedSize()
                    .disabled(coordinator.isBusy(dataSource: dataSource, vehicleID: vehicleID))
            }
        } else if coordinator.pending(dataSource: dataSource, vehicleID: vehicleID).isEmpty {
            Button { coordinator.clearActivity(dataSource: dataSource, vehicleID: vehicleID) } label: {
                Image(systemName: "xmark").foregroundStyle(Color.voltaTextSecondary)
            }.accessibilityLabel("Dismiss result")
        }
    }

    private func symbol(_ phase: VehicleCommandCoordinator.Phase) -> String {
        switch phase { case .success, .simulated: "checkmark.circle.fill"; case .failure: "xmark.circle.fill"; case .unknown: "questionmark.circle.fill"; case .pending: "clock" }
    }
    private func color(_ phase: VehicleCommandCoordinator.Phase) -> Color {
        switch phase { case .success: .voltaGreen; case .simulated: .voltaBlue; case .failure, .unknown: .voltaAmber; case .pending: .voltaTextSecondary }
    }
}

#Preview("Controls") {
    @Previewable @State var shown = true
    Color.black.sheet(isPresented: $shown) {
        ControlsView(initialStatus: nil, vehicleName: "Friday").environment(\.dataSource, MockDataSource())
    }
}
