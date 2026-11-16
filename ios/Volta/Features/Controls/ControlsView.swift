import SwiftUI

/// Vehicle controls. A sheet in a compact window (one column); a pushed
/// two-pane screen in a regular-width window wider than tall, with Back and
/// Refresh in the system bars. The model normally comes from the Dashboard,
/// so switching between the two forms (folding or unfolding iPhone Duo)
/// keeps its state.
struct ControlsView: View {
    enum Presentation { case sheet, pushed }
    /// What the pushed screen's second pane shows.
    enum SecondPane: Hashable { case main, climate }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.vehicleSurfaces) private var surfaces
    @Environment(\.vehicleCommandCoordinator) private var sharedCoordinator
    @Environment(\.units) private var units
    @Environment(AppModel.self) private var app: AppModel?

    let vehicleName: String?
    let presentation: Presentation
    let secondPane: SecondPane
    @State private var model: ControlsModel
    @State private var localCoordinator = VehicleCommandCoordinator()
    @State private var confirmation: CommandConfirmation?
    @State private var controlNotice: String?

    /// A sheet with its own model (the live charging sheet's "Manage charging").
    init(initialStatus: VehicleStatus?, vehicleName: String?) {
        self.vehicleName = vehicleName
        presentation = .sheet
        secondPane = .main
        _model = State(initialValue: ControlsModel(status: initialStatus))
    }

    /// Controls for a model the caller owns.
    init(model: ControlsModel, vehicleName: String?, presentation: Presentation, secondPane: SecondPane = .main) {
        self.vehicleName = vehicleName
        self.presentation = presentation
        self.secondPane = secondPane
        _model = State(initialValue: model)
    }

    private var coordinator: VehicleCommandCoordinator { sharedCoordinator ?? localCoordinator }
    private var context: VehicleCommandContext {
        VehicleCommandContext(model: model, coordinator: coordinator, dataSource: dataSource,
                              vehicleID: vehicleID, surfaces: surfaces)
    }

    var body: some View {
        Group {
            switch presentation {
            case .sheet: sheet
            case .pushed: pushed
            }
        }
        .preferredColorScheme(.dark)
        .task(id: vehicleID) { if secondPane == .main { await load() } }
        .alert(item: $confirmation) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  primaryButton: .cancel(), secondaryButton: .destructive(Text(item.button)) { run(item.command) })
        }
    }

    private func load() async {
        await coordinator.refreshCapabilities(dataSource: dataSource, vehicleID: vehicleID)
        await context.refresh()
    }

    // MARK: Forms

    private var sheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
                    statusLine
                    banners
                    access
                    charging
                    comfort
                    security
                    CommandLogList(log: model.log, key: context.logKey)
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, VoltaSpacing.sm)
                .padding(.bottom, 96)
                .voltaReadableWidth()
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.controls")
            .overlay(alignment: .bottom) { activityBanner }
            .background(Color.voltaBackground.ignoresSafeArea())
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                        .tint(Color.voltaTextPrimary)
                }
                ToolbarItem(placement: .principal) {
                    Text("CONTROLS").font(.system(.headline, weight: .semibold)).tracking(3)
                        .foregroundStyle(Color.voltaTextPrimary).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.controls")
                }
                refreshItem
            }
            .refreshable { await load() }
            .navigationDestination(isPresented: $model.climateOpen) { ClimateControlsView(model: model) }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.voltaBackground)
        .presentationCornerRadius(34)
    }

    /// Pushed: Access, Charging and the session log on one side of the fold;
    /// banners, Comfort and Security on the other. "Seats, wheel & defrost"
    /// pushes the same screen with the climate details in the second pane.
    private var pushed: some View {
        VoltaPanes {
            ScrollView {
                VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
                    VStack(alignment: .leading, spacing: VoltaSpacing.xs) {
                        Text("Controls")
                            .font(.system(.largeTitle, weight: .bold))
                            .foregroundStyle(Color.voltaTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(secondPane == .main ? "screen.controls" : "")
                        statusLine
                    }
                    access
                    charging
                    CommandLogList(log: model.log, key: context.logKey)
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.top, VoltaSpacing.sm)
                .padding(.bottom, VoltaSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier(secondPane == .main ? "scroll.controls" : "")
            .refreshable { await load() }
        } secondary: {
            Group {
                switch secondPane {
                case .main:
                    ScrollView {
                        VStack(alignment: .leading, spacing: VoltaSpacing.xl) {
                            banners
                            comfort
                            security
                        }
                        .padding(.horizontal, VoltaSpacing.screen)
                        .padding(.top, VoltaSpacing.sm)
                        .padding(.bottom, 96)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await load() }
                case .climate:
                    ClimateControlsView(model: model, embedded: true)
                }
            }
            .overlay(alignment: .bottom) { activityBanner }
        }
        .background(Color.voltaBackground.ignoresSafeArea())
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar { refreshItem }
    }

    private var refreshItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await load() } } label: { Label("Refresh controls", systemImage: "arrow.clockwise") }
                .tint(Color.voltaTextPrimary)
        }
    }

    // MARK: Header

    /// "FRIDAY · 72% · Charging · updated just now"
    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let detail = Self.statusDetail(model.status, now: timeline.date)
            // One line, or the name above the detail when they don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusName
                    if let detail { statusDetailText("· \(detail)") }
                }
                VStack(alignment: .leading, spacing: 2) {
                    statusName
                    if let detail { statusDetailText(detail) }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusName: some View {
        Text(vehicleName ?? "Vehicle")
            .font(.system(.subheadline, weight: .semibold))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Color.voltaTextPrimary)
    }

    private func statusDetailText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.voltaTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func statusDetail(_ status: VehicleStatus?, now: Date = .now) -> String? {
        guard let status else { return nil }
        let state = status.isCharging ? "Charging" : status.state.displayName
        let age = now.timeIntervalSince(status.updatedAt)
        let updated = age < 60 ? "updated just now" : "updated \(VoltaFormat.relativeDate(status.updatedAt, now: now))"
        return "\(status.batteryLevel)% · \(state) · \(updated)"
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if dataSource.simulatesVehicleCommands || !(coordinator.capability(dataSource: dataSource, vehicleID: vehicleID)?.available ?? false) || controlNotice != nil {
            VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                readiness
                if let controlNotice {
                    InlineBanner(systemImage: "location.slash", message: controlNotice, tint: .voltaAmber)
                }
            }
        }
    }

    @ViewBuilder private var readiness: some View {
        if dataSource.simulatesVehicleCommands {
            InlineBanner(systemImage: "theatermasks", message: "Demo controls are simulated. No vehicle is contacted.", tint: .voltaBlue)
        } else if let capability = coordinator.capability(dataSource: dataSource, vehicleID: vehicleID), !capability.available {
            VStack(alignment: .leading, spacing: VoltaSpacing.md) {
                InlineBanner(systemImage: Self.readinessSymbol(capability.reason), message: Self.readinessMessage(capability.reason), tint: .voltaAmber)
                if Self.needsTeslaConsent(capability.reason) {
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

    // MARK: Access

    private var access: some View {
        ControlGroup(title: "Access") {
            doorsRow
            TwoUpRow {
                HalfControl(systemImage: "car.side.front.open", title: "Frunk", button: "Open",
                            accessibilityLabel: "Open frunk") { request(.actuateTrunk(whichTrunk: .front)) }
                    .disabled(!canSend(.actuateTrunk(whichTrunk: .front)))
            } trailing: {
                HalfControl(systemImage: "car.side.rear.open", title: "Trunk", button: "Open",
                            accessibilityLabel: "Open trunk") { request(.actuateTrunk(whichTrunk: .rear)) }
                    .disabled(!canSend(.actuateTrunk(whichTrunk: .rear)))
            }
            ControlRow(systemImage: "window.vertical.open", title: "Windows", subtitle: "Position not recorded") {
                button("Vent", .windowControl(command: .vent), accessibility: "Vent windows")
                button("Close", .windowControl(command: .close), accessibility: "Close windows")
            }
            ControlRow(systemImage: "powerplug", title: "Charge port", subtitle: chargePortStatus) {
                ForEach(Self.chargePortCommands(doorOpen: model.status?.chargePortDoorOpen), id: \.self) { command in
                    button(command == .openChargePort ? "Open" : "Close", command,
                           accessibility: command == .openChargePort ? "Open charge port" : "Close charge port")
                }
            }
        }
    }

    /// States the lock, then offers the one action that changes it (both when
    /// unknown). Both keep their confirmation.
    private var doorsRow: some View {
        let display = StateDisplay.doors(model.locked)
        return ControlRow(systemImage: display.symbol,
                          iconColor: model.locked == false ? .voltaAmber : .voltaTextPrimary.opacity(0.85),
                          title: "Doors", subtitle: display.text,
                          subtitleColor: model.locked == false ? .voltaAmber : .voltaTextSecondary) {
            switch model.locked {
            case true?: button("Unlock", .unlock, accessibility: "Doors locked. Unlock")
            case false?: button("Lock", .lock, accessibility: "Doors unlocked. Lock")
            case nil:
                button("Unlock", .unlock, accessibility: "Lock state unknown. Unlock")
                button("Lock", .lock, accessibility: "Lock state unknown. Lock")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row.doors")
    }

    /// The port actions that apply: Open when the door is closed, Close when
    /// it is open, both when its state was not recorded.
    static func chargePortCommands(doorOpen: Bool?) -> [VehicleCommand] {
        switch doorOpen {
        case true?: [.closeChargePort]
        case false?: [.openChargePort]
        case nil: [.openChargePort, .closeChargePort]
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

    // MARK: Charging

    private var charging: some View {
        ControlGroup(title: "Charging") {
            chargingRow
            ControlRow(systemImage: "gauge.with.dots.needle.67percent", title: "Charge limit",
                       subtitle: model.status.map { "\($0.batteryLevel)% now" }) {
                ChargeLimitStepper(context: context)
            }
        }
    }

    @ViewBuilder private var chargingRow: some View {
        let state = model.chargingState
        let charging = state == .charging
        let subtitle = Self.chargingSubtitle(state: state, status: model.status)
        if state == nil {
            ControlRow(systemImage: "bolt", iconColor: .voltaTextSecondary, title: "Charging", subtitle: subtitle) {
                button("Start", .chargeStart, accessibility: "Charging state unknown. Start charging")
                button("Stop", .chargeStop, accessibility: "Charging state unknown. Stop charging")
            }
        } else {
            let pluggedIn = state != .disconnected
            let command: VehicleCommand = charging ? .chargeStop : .chargeStart
            ControlRow(systemImage: charging ? "bolt.fill" : "bolt",
                       iconColor: charging ? .voltaGreen : .voltaTextPrimary.opacity(0.85),
                       title: "Charging", subtitle: subtitle) {
                Toggle("Charging", isOn: Binding(get: { charging }, set: { run($0 ? .chargeStart : .chargeStop) }))
                    .labelsHidden()
                    .tint(.voltaBlue)
                    .disabled(!pluggedIn || !canSend(command))
                    .accessibilityValue(subtitle)
            }
        }
    }

    /// "7.7 kW · 48m to 80%" while charging; "Not plugged in" explains the
    /// disabled switch.
    static func chargingSubtitle(state: ChargingState?, status: VehicleStatus?) -> String {
        switch state {
        case .charging?:
            let parts = [status?.chargerPowerKw.map { "\(VoltaFormat.number($0, digits: $0 >= 20 ? 0 : 1)) kW" },
                         NowCardContent.timeToLimit(status)]
            let text = parts.compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? "Charging" : text
        case .complete?: return "Complete · plugged in"
        case .stopped?: return "Stopped · plugged in"
        case .disconnected?: return "Not plugged in"
        case nil: return "State not recorded"
        }
    }

    // MARK: Comfort

    private var comfort: some View {
        ControlGroup(title: "Comfort") {
            toggleRow(StateDisplay.climate(model.climateOn), title: "Climate",
                      subtitle: climateSubtitle, value: model.climateOn, on: .climateOn, off: .climateOff,
                      onLabel: "Start", offLabel: "Stop")
            ControlRow(systemImage: "thermometer.medium", title: "Temperature") {
                let target = model.displayedCabinTargetC
                let command = VehicleCommand.setTemperatures(driverTempC: target ?? 20, passengerTempC: target ?? 20)
                let enabled = target != nil && canSend(command)
                ValueStepper(label: "Cabin temperature",
                             value: target.map { "\(VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0))°" } ?? "—",
                             accessibilityValue: target.map { units.formatTemperature($0) } ?? "Unknown",
                             canDecrease: enabled && (target ?? 0) > ControlsModel.cabinRangeC.lowerBound,
                             canIncrease: enabled && (target ?? 100) < ControlsModel.cabinRangeC.upperBound,
                             decrease: { context.stepCabinTarget(by: -1) },
                             increase: { context.stepCabinTarget(by: 1) })
            }
            climateLink
        }
    }

    private var climateSubtitle: String {
        let state = StateDisplay.climate(model.climateOn).text
        guard let inside = model.status?.insideTempC else { return state }
        return "\(state) · \(VoltaFormat.number(units.temperatureValue(celsius: inside), digits: 0))° inside"
    }

    @ViewBuilder private var climateLink: some View {
        let row = ControlRow(systemImage: "carseat.left.and.heat.waves", title: "Seats, wheel & defrost",
                             trailingStaysInline: true) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.voltaTextTertiary)
        }
        .contentShape(.rect)
        // The model holds "open", so the screen follows Controls between a
        // sheet (pushed inside it) and the pushed screen (its second pane,
        // which the owner of the navigation stack shows).
        Button { model.climateOpen = true } label: { row }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.climate")
            .accessibilityAddTraits(secondPane == .climate ? .isSelected : [])
            .disabled(secondPane == .climate)
    }

    // MARK: Security and locate

    private var security: some View {
        ControlGroup(title: "Security & locate") {
            toggleRow(StateDisplay.sentry(model.sentry), title: "Sentry",
                      subtitle: model.sentry.map { $0 ? "On" : "Off" } ?? "Unknown",
                      value: model.sentry, on: .sentryOn, off: .sentryOff, onLabel: "Arm", offLabel: "Disarm",
                      activeIcon: .voltaRed)
            TwoUpRow {
                HalfControl(systemImage: "headlight.high.beam", title: "Lights", button: "Flash",
                            accessibilityLabel: "Flash lights") { request(.flash) }
                    .disabled(!canSend(.flash))
            } trailing: {
                HalfControl(systemImage: "megaphone", title: "Horn", button: "Honk",
                            accessibilityLabel: "Honk horn") { request(.honk) }
                    .disabled(!canSend(.honk))
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let nearby = Self.homeLinkCommand(status: model.status, now: context.date)
                ControlRow(systemImage: "house", title: "HomeLink",
                           subtitle: nearby == nil ? "Needs a location observed within 5 minutes" : "Uses the car's location") {
                    ControlButton("Activate") {
                        guard let command = homeLinkCommand else { return }
                        request(command)
                    }
                    .disabled(nearby == nil || !canSend(nearby ?? .triggerHomeLink(latitude: 0, longitude: 0)))
                    .accessibilityLabel("Activate HomeLink")
                }
            }
            if let state = model.status?.state, state == .asleep || state == .offline {
                ControlRow(systemImage: "power", title: "Wake",
                           subtitle: "\(state.displayName) · last seen \(VoltaFormat.relativeDate(model.status?.updatedAt ?? .now))") {
                    button("Wake", .wakeUp, accessibility: "Wake the vehicle")
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

    // MARK: Building blocks

    /// A system switch tinted the accent blue when the state is known; Start
    /// and Stop buttons when it is not.
    @ViewBuilder
    private func toggleRow(_ display: StateDisplay, title: String, subtitle: String, value: Bool?,
                           on: VehicleCommand, off: VehicleCommand, onLabel: String, offLabel: String,
                           activeIcon: Color? = nil) -> some View {
        if let value {
            ControlRow(systemImage: display.symbol,
                       iconColor: value ? (activeIcon ?? .voltaTextPrimary) : .voltaTextPrimary.opacity(0.85),
                       title: title, subtitle: subtitle) {
                Toggle(title, isOn: Binding(get: { value }, set: { request($0 ? on : off) }))
                    .labelsHidden()
                    .tint(.voltaBlue)
                    .disabled(!canSend(value ? off : on))
                    .accessibilityValue(display.text)
            }
        } else {
            ControlRow(systemImage: display.symbol, iconColor: .voltaTextSecondary, title: title, subtitle: "Unknown") {
                button(onLabel, on, accessibility: "\(title) state unknown. \(on.controlLabel)")
                button(offLabel, off, accessibility: "\(title) state unknown. \(off.controlLabel)")
            }
        }
    }

    private func button(_ title: String, _ command: VehicleCommand, accessibility: String) -> some View {
        ControlButton(title, isBusy: context.isSending(command)) { request(command) }
            .disabled(!canSend(command))
            .accessibilityLabel(accessibility)
    }

    private func canSend(_ command: VehicleCommand) -> Bool { context.canStart(command) }

    /// Asks first when the command has a confirmation, then sends.
    private func request(_ command: VehicleCommand) {
        guard canSend(command) else { return }
        if let required = CommandConfirmation.required(for: command) {
            confirmation = required
        } else {
            run(command)
        }
    }

    private func run(_ command: VehicleCommand) {
        if case .triggerHomeLink = command, homeLinkCommand != command {
            controlNotice = "The vehicle location changed or expired. Refresh status before activating HomeLink."
            return
        }
        controlNotice = nil
        context.send(command)
    }

    @ViewBuilder private var activityBanner: some View {
        VehicleCommandActivityBanner(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID,
                                     log: model.log) {
            Task { await context.refresh() }
        }
    }

    static func needsTeslaConsent(_ reason: String?) -> Bool {
        ["authorization_required", "reauthorization_required", "command_scope_required"].contains(reason)
    }
    static func readinessSymbol(_ reason: String?) -> String {
        needsTeslaConsent(reason) ? "key.horizontal" : "antenna.radiowaves.left.and.right.slash"
    }
    static func readinessMessage(_ reason: String?) -> String {
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

// MARK: - Seats, wheel & defrost

struct ClimateControlsView: View {
    let model: ControlsModel
    /// Shown as the second pane of the pushed Controls screen: no bar title
    /// (with bars on the side a title keeps a horizontal bar alive), an
    /// inline heading instead.
    var embedded = false
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.vehicleCommandCoordinator) private var sharedCoordinator
    @Environment(\.vehicleSurfaces) private var surfaces
    @State private var localCoordinator = VehicleCommandCoordinator()

    init(model: ControlsModel, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
    }

    /// The targets being edited live in the model (see `climateOpen`); until
    /// one is edited it shows the observed driver setting.
    private var observedTargetC: Double { model.status?.driverTempSettingC ?? 20 }
    private var driverTarget: Binding<Double> {
        Binding(get: { model.climateDriverDraftC ?? observedTargetC }, set: { model.climateDriverDraftC = $0 })
    }
    private var passengerTarget: Binding<Double> {
        Binding(get: { model.climatePassengerDraftC ?? observedTargetC }, set: { model.climatePassengerDraftC = $0 })
    }
    private var coordinator: VehicleCommandCoordinator { sharedCoordinator ?? localCoordinator }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if embedded {
                    Text("Seats, wheel & defrost")
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.climate")
                        .padding(.top, VoltaSpacing.sm)
                }
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
            }
            .padding(.horizontal, VoltaSpacing.screen + (embedded ? 0 : 4))
            .padding(.bottom, 96)
        }
        .accessibilityIdentifier("scroll.climate")
        .overlay(alignment: .bottom) {
            if !embedded {
                VehicleCommandActivityBanner(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID,
                                     log: model.log) {
                    Task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
                }
            }
        }
        .background(Color.voltaBackground.ignoresSafeArea())
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .principal) {
                    Text("Climate").font(.voltaScreenTitle).foregroundStyle(Color.voltaTextPrimary)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.climate")
                }
            }
        }
    }

    private var temperatureControl: some View {
        VStack(alignment: .leading, spacing: VoltaSpacing.md) {
            temperatureRow(title: "Driver target", value: driverTarget)
            temperatureRow(title: "Passenger target", value: passengerTarget)
            let command = VehicleCommand.setTemperatures(driverTempC: driverTarget.wrappedValue,
                                                          passengerTempC: passengerTarget.wrappedValue)
            PillButton("Set cabin temperatures", size: .wide, style: .accent) {
                send(command, label: "Set cabin temperatures")
            }
            .disabled(!canSend(command))
            .padding(.leading, 52)
        }.padding(.bottom, VoltaSpacing.md)
    }

    private func temperatureRow(title: String, value: Binding<Double>) -> some View {
        ListRow(systemImage: "dial.medium", title: title, subtitle: "15–28 °C") {
            HStack(spacing: 0) {
                Button { value.wrappedValue = max(15, value.wrappedValue - 0.5) } label: {
                    Image(systemName: "minus.circle.fill").imageScale(.large)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }.accessibilityLabel("Decrease \(title.lowercased())")
                Text(units.formatTemperature(value.wrappedValue)).monospacedDigit()
                    .frame(minWidth: 58)
                Button { value.wrappedValue = min(28, value.wrappedValue + 0.5) } label: {
                    Image(systemName: "plus.circle.fill").imageScale(.large)
                        .frame(width: 44, height: 44).contentShape(.rect)
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
                        .disabled(!canSend(command))
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
                    .disabled(!canSend(off))
                PillButton("On", size: .wide) { send(on, label: "Turn on \(title.lowercased())") }
                    .disabled(!canSend(on))
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

#Preview("Controls") {
    @Previewable @State var shown = true
    Color.black.sheet(isPresented: $shown) {
        ControlsView(initialStatus: nil, vehicleName: "Friday").environment(\.dataSource, MockDataSource())
    }
}
