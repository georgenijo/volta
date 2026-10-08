import SwiftUI

/// Command names sent to `dataSource.command(...)`. They mirror Tesla Fleet
/// API command names so the Phase 2 server can pass them through.
enum VehicleCommand {
    static let lock = "door_lock"
    static let unlock = "door_unlock"
    static let actuateTrunk = "actuate_trunk"          // which_trunk = front | rear
    static let chargePortOpen = "charge_port_door_open"
    static let chargePortClose = "charge_port_door_close"
    static let windowControl = "window_control"        // command = vent | close
    static let chargeStart = "charge_start"
    static let chargeStop = "charge_stop"
    static let setChargeLimit = "set_charge_limit"     // percent
    static let climateStart = "auto_conditioning_start"
    static let climateStop = "auto_conditioning_stop"
    static let setSentry = "set_sentry_mode"           // on = true | false
    static let flashLights = "flash_lights"
    static let honk = "honk_horn"
    static let locate = "remote_boombox"
    static let homelink = "trigger_homelink"           // lat, lon
}

@MainActor
@Observable
final class ControlsModel {
    var status: VehicleStatus?
    // Displayed states. `nil` means unknown and renders as "Unknown"/"—".
    var locked: Bool?
    var chargingState: ChargingState?
    var chargeLimit: Int?
    var climateOn: Bool?
    var sentry: Bool?
    /// Phase 1 servers reject every command, so this starts false and every
    /// command control is disabled. A Phase 2 capability flag can pass `true`.
    var commandsAvailable: Bool
    var busy: String?
    var toast: Toast?

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    private struct Snapshot {
        var locked: Bool?
        var chargingState: ChargingState?
        var chargeLimit: Int?
        var climateOn: Bool?
        var sentry: Bool?
    }

    private var refreshGeneration = 0

    init(status: VehicleStatus?, commandsAvailable: Bool = false) {
        self.commandsAvailable = commandsAvailable
        apply(status)
    }

    /// Whether command controls are interactive right now.
    var canSend: Bool { commandsAvailable && busy == nil }

    func apply(_ status: VehicleStatus?) {
        self.status = status
        guard let status else { return }
        locked = status.locked
        chargingState = status.chargingState
        chargeLimit = status.chargeLimit
        climateOn = status.climateOn
        sentry = status.sentryMode
    }

    /// Refreshes status. Refreshes may overlap (initial `.task`, pull-to-refresh,
    /// "Refresh status"), so each takes a generation number and only the newest,
    /// uncancelled one may publish. Commands also bump the generation, so a
    /// refresh that started before a command can't overwrite its result.
    /// Failures and cancellations keep the current state.
    /// A published status also goes to `surfaces` (widgets, Live Activities).
    func refresh(dataSource: any VoltaDataSource, vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        guard busy == nil else { return }
        refreshGeneration += 1
        let token = refreshGeneration
        let issued = surfaces?.nextStatusToken()  // before the /status request: orders publishes
        guard let fresh = try? await dataSource.status(vehicleID: vehicleID) else { return }
        guard token == refreshGeneration, !Task.isCancelled, busy == nil else { return }
        apply(fresh)
        if let surfaces, let issued {
            surfaces.publish(VehicleRefresh(status: fresh, issued: issued), dataSource: dataSource)
        }
    }

    // MARK: Intents

    @discardableResult
    func setLocked(_ new: Bool, dataSource: any VoltaDataSource, vehicleID: Int) async -> Bool {
        await perform(new ? VehicleCommand.lock : VehicleCommand.unlock, label: new ? "Lock" : "Unlock",
                      dataSource: dataSource, vehicleID: vehicleID) { self.locked = new }
    }

    @discardableResult
    func setCharging(_ new: Bool, dataSource: any VoltaDataSource, vehicleID: Int) async -> Bool {
        await perform(new ? VehicleCommand.chargeStart : VehicleCommand.chargeStop,
                      label: new ? "Start charging" : "Stop charging",
                      dataSource: dataSource, vehicleID: vehicleID) { self.chargingState = new ? .charging : .stopped }
    }

    @discardableResult
    func adjustChargeLimit(by delta: Int, dataSource: any VoltaDataSource, vehicleID: Int) async -> Bool {
        guard let old = chargeLimit else { return false }
        let new = min(100, max(50, old + delta))
        guard new != old else { return false }
        return await perform(VehicleCommand.setChargeLimit, params: ["percent": "\(new)"],
                             label: "Charge limit \(new)%", dataSource: dataSource, vehicleID: vehicleID) {
            self.chargeLimit = new
        }
    }

    @discardableResult
    func setClimate(_ new: Bool, dataSource: any VoltaDataSource, vehicleID: Int) async -> Bool {
        await perform(new ? VehicleCommand.climateStart : VehicleCommand.climateStop,
                      label: new ? "Start climate" : "Stop climate",
                      dataSource: dataSource, vehicleID: vehicleID) { self.climateOn = new }
    }

    @discardableResult
    func setSentry(_ new: Bool, dataSource: any VoltaDataSource, vehicleID: Int) async -> Bool {
        await perform(VehicleCommand.setSentry, params: ["on": new ? "true" : "false"],
                      label: new ? "Arm Sentry" : "Disarm Sentry",
                      dataSource: dataSource, vehicleID: vehicleID) { self.sentry = new }
    }

    /// Sends a command. Returns false, without touching state or calling the
    /// data source, when commands are unavailable or another command is in
    /// flight. Otherwise applies `optimistic`, sends, and restores the
    /// previous state if the command fails.
    @discardableResult
    func perform(_ name: String, params: [String: String] = [:], label: String,
                 dataSource: any VoltaDataSource, vehicleID: Int,
                 optimistic: (() -> Void)? = nil) async -> Bool {
        guard canSend else { return false }
        refreshGeneration += 1  // invalidate refreshes already in flight
        let snapshot = Snapshot(locked: locked, chargingState: chargingState, chargeLimit: chargeLimit,
                                climateOn: climateOn, sentry: sentry)
        busy = label
        defer { busy = nil }
        withAnimation(.snappy) { optimistic?() }
        do {
            try await dataSource.command(vehicleID: vehicleID, name: name, params: params)
            show("\(label) sent", isError: false)
            return true
        } catch {
            withAnimation(.snappy) {
                locked = snapshot.locked
                chargingState = snapshot.chargingState
                chargeLimit = snapshot.chargeLimit
                climateOn = snapshot.climateOn
                sentry = snapshot.sentry
            }
            if (error as? VoltaError) == .commandsUnavailable {
                commandsAvailable = false
                show("Commands aren't connected yet. \(label) wasn't sent.", isError: true)
            } else if !(error is CancellationError) {
                show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
            }
            return false
        }
    }

    private func show(_ message: String, isError: Bool) {
        let toast = Toast(message: message, isError: isError)
        withAnimation(.snappy) { self.toast = toast }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(.easeOut) { self.toast = nil }
        }
    }
}

/// CONTROLS sheet: Access, Charging, Comfort, Security, Locate.
struct ControlsView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.vehicleSurfaces) private var surfaces

    var vehicleName: String?
    @State private var model: ControlsModel

    init(initialStatus: VehicleStatus?, vehicleName: String?, commandsAvailable: Bool = false) {
        self.vehicleName = vehicleName
        _model = State(initialValue: ControlsModel(status: initialStatus, commandsAvailable: commandsAvailable))
    }

    private let iconInset: CGFloat = 52

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity
                    if !model.commandsAvailable {
                        InlineBanner(systemImage: "antenna.radiowaves.left.and.right.slash",
                                     message: "Read-only for now. Controls show live status; commands arrive in a later update.",
                                     tint: .voltaBlue)
                            .padding(.top, VoltaSpacing.lg)
                    }
                    access.padding(.top, VoltaSpacing.xxl)
                    chargingSection.padding(.top, VoltaSpacing.xxl)
                    comfort.padding(.top, VoltaSpacing.xxl)
                    security.padding(.top, VoltaSpacing.xxl)
                    locate.padding(.top, VoltaSpacing.xxl)
                }
                .padding(.horizontal, VoltaSpacing.screen + 4)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.controls")
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { toastView }
            .background(Color.voltaBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.voltaBackground)
        .presentationCornerRadius(34)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.error, trigger: model.toast) { _, new in new?.isError == true }
        .task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("CONTROLS")
                .font(.system(.headline, weight: .semibold))
                .tracking(3)
                .foregroundStyle(Color.voltaTextPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.controls")
            HStack {
                GlassCircleButton(systemImage: "xmark", size: 52, accessibilityLabel: "Close") { dismiss() }
                Spacer()
                Menu {
                    Button("Refresh status", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Options")
            }
        }
        .padding(.horizontal, VoltaSpacing.screen - 4)
        .padding(.top, VoltaSpacing.xl)
        .padding(.bottom, VoltaSpacing.md)
        .background(Color.voltaBackground.opacity(0.94))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vehicleName ?? "Vehicle")
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
            if let state = model.status?.state {
                HStack(spacing: 8) {
                    StatusDot(color: state.color, size: 6)
                    Text(state.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.voltaTextSecondary)
                }
            }
        }
        .padding(.top, VoltaSpacing.lg)
    }

    // MARK: Sections

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Access", trailing: "5 controls", rule: true)
                .padding(.bottom, VoltaSpacing.sm)
            stateToggle(StateDisplay.doors(model.locked), title: "Doors", subtitle: "Lock & unlock",
                        isOn: model.locked) { new in
                await model.setLocked(new, dataSource: dataSource, vehicleID: vehicleID)
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "car.side.front.open", title: "Frunk", subtitle: "Front trunk", button: "Open") {
                run(VehicleCommand.actuateTrunk, params: ["which_trunk": "front"], label: "Open frunk")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "car.side.rear.open", title: "Trunk", subtitle: "Rear trunk", button: "Open") {
                run(VehicleCommand.actuateTrunk, params: ["which_trunk": "rear"], label: "Open trunk")
            }
            HairlineDivider(leadingInset: iconInset)
            pairRow(icon: "powerplug", title: "Charge port", subtitle: "No data",
                    left: ("Open", { run(VehicleCommand.chargePortOpen, label: "Open charge port") }),
                    right: ("Close", { run(VehicleCommand.chargePortClose, label: "Close charge port") }))
            HairlineDivider()
            pairRow(icon: "window.vertical.open", title: "Windows", subtitle: "No data",
                    left: ("Vent", { run(VehicleCommand.windowControl, params: ["command": "vent"], label: "Vent windows") }),
                    right: ("Close", { run(VehicleCommand.windowControl, params: ["command": "close"], label: "Close windows") }))
        }
    }

    private var chargingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Charging", rule: true) { EmptyView() }
                .padding(.bottom, VoltaSpacing.sm)
            stateToggle(StateDisplay.charging(model.chargingState), title: "Charging",
                        subtitle: "Start, stop & limit",
                        isOn: model.chargingState.map { $0 == .charging }) { new in
                await model.setCharging(new, dataSource: dataSource, vehicleID: vehicleID)
            }
            HStack {
                Text("Charge limit")
                    .font(.voltaRowSubtitle)
                    .foregroundStyle(Color.voltaTextSecondary)
                Spacer()
                LimitStepper(value: model.chargeLimit, isEnabled: model.canSend) { delta in
                    Task { await model.adjustChargeLimit(by: delta, dataSource: dataSource, vehicleID: vehicleID) }
                }
            }
            .padding(.leading, iconInset)
            .padding(.vertical, VoltaSpacing.sm)
        }
    }

    private var comfort: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Comfort", trailing: "2 controls", rule: true)
                .padding(.bottom, VoltaSpacing.sm)
            stateToggle(StateDisplay.climate(model.climateOn), title: "Climate",
                        subtitle: "Precondition the cabin", isOn: model.climateOn) { new in
                await model.setClimate(new, dataSource: dataSource, vehicleID: vehicleID)
            }
            HairlineDivider(leadingInset: iconInset)
            NavigationLink {
                ClimateControlsView(status: model.status, commandsAvailable: model.commandsAvailable)
            } label: {
                ListRow(systemImage: "thermometer.medium", title: "Climate controls",
                        subtitle: "Seats, defrost & more", showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Security", rule: true) { EmptyView() }
                .padding(.bottom, VoltaSpacing.sm)
            stateToggle(StateDisplay.sentry(model.sentry), title: "Sentry",
                        subtitle: "Security recording", isOn: model.sentry) { new in
                await model.setSentry(new, dataSource: dataSource, vehicleID: vehicleID)
            }
        }
    }

    private var locate: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Locate", trailing: "4 controls", rule: true)
                .padding(.bottom, VoltaSpacing.sm)
            actionRow(icon: "headlight.high.beam.fill", title: "Flash Lights", subtitle: "Flash the lights", button: "Flash") {
                run(VehicleCommand.flashLights, label: "Flash lights")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "megaphone.fill", title: "Honk Horn", subtitle: "Sound the horn", button: "Honk") {
                run(VehicleCommand.honk, label: "Honk")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "location.fill", title: "Locate", subtitle: "Play a sound to find it", button: "Ping") {
                run(VehicleCommand.locate, label: "Ping")
            }
            HairlineDivider(leadingInset: iconInset)
            actionRow(icon: "house.fill", title: "HomeLink", subtitle: "Open nearby garage", button: "Open") {
                var params: [String: String] = [:]
                if let loc = model.status?.location {
                    params = ["lat": "\(loc.latitude)", "lon": "\(loc.longitude)"]
                }
                run(VehicleCommand.homelink, params: params, label: "HomeLink")
            }
        }
    }

    // MARK: Row builders

    /// A command toggle for a state that may be unknown. Unknown states show
    /// "Unknown" with a neutral icon and no switch; known states show a switch
    /// that is disabled unless commands can be sent.
    @ViewBuilder
    private func stateToggle(_ display: StateDisplay, title: String, subtitle: String, isOn: Bool?,
                             send: @escaping (Bool) async -> Void) -> some View {
        if let isOn {
            ToggleRow(systemImage: display.symbol, title: title, subtitle: subtitle, status: display.text,
                      isOn: Binding(get: { isOn }, set: { new in Task { await send(new) } }),
                      onColor: .voltaGreen, isEnabled: model.canSend)
                .accessibilityHint(model.commandsAvailable ? "" : "Commands aren't available yet")
        } else {
            ListRow(systemImage: display.symbol, iconColor: .voltaTextTertiary, title: title, subtitle: subtitle) {
                Text(display.text)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Color.voltaTextTertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), state unknown")
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String, button: String,
                           action: @escaping () -> Void) -> some View {
        ListRow(systemImage: icon, title: title, subtitle: subtitle) {
            PillButton(button, action: action)
                .opacity(model.commandsAvailable ? 1 : 0.55)
                .disabled(!model.canSend)
        }
    }

    private func pairRow(icon: String, title: String, subtitle: String,
                         left: (String, () -> Void), right: (String, () -> Void)) -> some View {
        VStack(spacing: VoltaSpacing.md) {
            ListRow(systemImage: icon, title: title, subtitle: subtitle)
            HStack(spacing: VoltaSpacing.lg) {
                PillButton(left.0, size: .wide, action: left.1)
                PillButton(right.0, size: .wide, action: right.1)
            }
            .opacity(model.commandsAvailable ? 1 : 0.55)
            .disabled(!model.canSend)
        }
        .padding(.bottom, VoltaSpacing.lg)
    }

    private func run(_ name: String, params: [String: String] = [:], label: String) {
        Task {
            await model.perform(name, params: params, label: label, dataSource: dataSource, vehicleID: vehicleID)
        }
    }

    // MARK: Toast

    @ViewBuilder private var toastView: some View {
        if let toast = model.toast {
            HStack(spacing: VoltaSpacing.md) {
                Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Color.voltaAmber : Color.voltaGreen)
                Text(toast.message)
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VoltaSpacing.lg + 2)
            .padding(.vertical, VoltaSpacing.md + 2)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.bottom, VoltaSpacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .onTapGesture { withAnimation { model.toast = nil } }
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// "−  80%  +" stepper capsule. Shows "—" when the limit is unknown.
struct LimitStepper: View {
    var value: Int?
    var isEnabled: Bool
    var change: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", delta: -5, label: "Decrease limit")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { "\($0)" } ?? "—")
                    .font(.system(.title3, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value ?? 0)))
                if value != nil {
                    Text("%").font(.footnote).foregroundStyle(Color.voltaTextSecondary)
                }
            }
            .frame(minWidth: 64)
            .foregroundStyle(value == nil ? Color.voltaTextTertiary : Color.voltaTextPrimary)
            button("plus", delta: 5, label: "Increase limit")
        }
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous)
                .fill(Color.voltaRaised)
                .overlay {
                    RoundedRectangle(cornerRadius: VoltaRadius.wideButton, style: .continuous)
                        .strokeBorder(Color.voltaHairline, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(value.map { "Charge limit \($0) percent" } ?? "Charge limit unknown")
    }

    private var interactive: Bool { isEnabled && value != nil }

    private func button(_ symbol: String, delta: Int, label: String) -> some View {
        Button { change(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary.opacity(interactive ? 1 : 0.4))
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(VoltaPressStyle())
        .disabled(!interactive)
        .accessibilityLabel(label)
    }
}

/// Secondary climate page. Read-only in Phase 1.
struct ClimateControlsView: View {
    var status: VehicleStatus?
    var commandsAvailable: Bool
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VoltaHeader("Climate") {
                    GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
                } trailing: { EmptyView() }
                .padding(.horizontal, -(VoltaSpacing.screen - 4) + 4)
                VStack(spacing: 0) {
                    ListRow(systemImage: "thermometer.medium", title: "Cabin", subtitle: "Inside temperature") {
                        Text(units.formatTemperature(status?.insideTempC)).foregroundStyle(Color.voltaTextSecondary)
                    }
                    HairlineDivider(leadingInset: 52)
                    ListRow(systemImage: "dial.medium", title: "Set temperature", subtitle: "Driver") {
                        Text(units.formatTemperature(status?.driverTempSettingC)).foregroundStyle(Color.voltaTextSecondary)
                    }
                    HairlineDivider(leadingInset: 52)
                    ListRow(systemImage: "carseat.left.and.heat.waves", title: "Seat heaters", subtitle: "No data")
                    HairlineDivider(leadingInset: 52)
                    ListRow(systemImage: "windshield.front.and.heat.waves", title: "Defrost", subtitle: "No data")
                    HairlineDivider(leadingInset: 52)
                    ListRow(systemImage: "steeringwheel.and.heat.waves", title: "Steering wheel heat", subtitle: "No data")
                }
                .padding(.top, VoltaSpacing.lg)
                if !commandsAvailable {
                    Text("Adjusting climate needs vehicle commands, which aren't connected yet.")
                        .font(.footnote)
                        .foregroundStyle(Color.voltaTextSecondary)
                        .padding(.top, VoltaSpacing.xl)
                }
            }
            .padding(.horizontal, VoltaSpacing.screen + 4)
        }
        .background(Color.voltaBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview("Controls") {
    @Previewable @State var shown = true
    Color.black.sheet(isPresented: $shown) {
        ControlsView(initialStatus: nil, vehicleName: "Friday")
            .environment(\.dataSource, MockDataSource())
    }
}

#Preview("Controls – no status") {
    ControlsView(initialStatus: nil, vehicleName: nil)
        .environment(\.dataSource, FailingDataSource())
}
