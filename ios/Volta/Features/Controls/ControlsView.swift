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

    @Environment(\.units) private var units

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    if !model.commandsAvailable {
                        readOnlyNotice.padding(.top, 24)
                    }
                    section("Access", count: 4) { access }.padding(.top, 30)
                    section("Charging", count: 3) { chargingSection }.padding(.top, 30)
                    section("Comfort & security", count: 3) { comfort }.padding(.top, 30)
                    section("Locate", count: 4) { locate }.padding(.top, 30)
                }
                .padding(.horizontal, VoltaSpacing.screen)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("scroll.controls")
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { toastView }
            .background(alignment: .top) { ScreenKit.TopGlow() }
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
            Text("Controls")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.controls")
            HStack {
                GlassCircleButton(systemImage: "xmark", size: 48, accessibilityLabel: "Close") { dismiss() }
                Spacer()
                Menu {
                    Button("Refresh status", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.voltaTextPrimary)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Options")
            }
        }
        .padding(.horizontal, VoltaSpacing.screen - 4)
        .padding(.top, VoltaSpacing.xl)
        .padding(.bottom, VoltaSpacing.md)
        .background { ScreenKit.HeaderScrim() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(model.status?.state.color ?? Color.voltaTextTertiary)
                    .frame(width: 6, height: 6)
                    .shadow(color: (model.status?.state.color ?? .clear).opacity(0.8), radius: 3)
                Text(vehicleName ?? "Vehicle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.voltaTextPrimary)
                if let state = model.status?.state {
                    Text(state.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.voltaTextSecondary)
                }
                Spacer(minLength: 8)
                if let freshness = model.status?.telemetryFreshness {
                    Text(freshness.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.voltaTextTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    caption("Cabin")
                    BigNumber(cabinValue, unit: model.status?.insideTempC == nil ? nil : units.temperatureUnit,
                              size: 76, weight: .bold)
                    Text(climateLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.voltaTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cabin \(units.formatTemperature(model.status?.insideTempC)), \(climateLine)")
                Spacer(minLength: 0)
                LockDial(locked: model.locked)
            }

            statStrip
        }
        .padding(.top, 12)
    }

    private var cabinValue: String {
        guard let c = model.status?.insideTempC else { return "—" }
        return VoltaFormat.number(units.temperatureValue(celsius: c), digits: 0)
    }

    private var climateLine: String {
        let climate = StateDisplay.climate(model.climateOn)
        let set = model.status?.driverTempSettingC.map { "Set \(units.formatTemperature($0))" }
        let state = climate.isKnown ? "Climate \(climate.text.lowercased())" : "Climate unknown"
        return [set, state].compactMap { $0 }.joined(separator: " · ")
    }

    private var statStrip: some View {
        HStack(spacing: 0) {
            stat("Battery", model.status.map { "\($0.batteryLevel)" } ?? "—", unit: model.status == nil ? nil : "%")
            stripDivider
            stat("Range", rangeValue, unit: rangeValue == "—" ? nil : units.distanceUnit)
            stripDivider
            stat("Outside", model.status?.outsideTempC.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—",
                 unit: model.status?.outsideTempC == nil ? nil : units.temperatureUnit)
            stripDivider
            stat("Limit", model.chargeLimit.map { "\($0)" } ?? "—", unit: model.chargeLimit == nil ? nil : "%")
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Color.voltaHairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.voltaHairline).frame(height: 1) }
    }

    private var rangeValue: String {
        guard let km = model.status?.estRangeKm ?? model.status?.ratedRangeKm else { return "—" }
        return VoltaFormat.number(units.distanceValue(km: km), digits: 0)
    }

    private var stripDivider: some View {
        Rectangle().fill(Color.voltaHairline).frame(width: 1, height: 30)
    }

    private func stat(_ title: String, _ value: String, unit: String?) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == "—" ? Color.voltaTextTertiary : Color.voltaTextPrimary)
                if let unit {
                    Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                }
            }
            caption(title)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(Color.voltaTextTertiary)
    }

    private var readOnlyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.voltaBlue)
                .shadow(color: Color.voltaBlue.opacity(0.6), radius: 6)
                .padding(.top, 1)
            Text("Read-only for now. Controls show live status; commands arrive in a later update.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.voltaTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.voltaBlue.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.voltaBlue.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private func section<Content: View>(_ title: String, count: Int? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                caption(title).accessibilityAddTraits(.isHeader)
                Spacer()
                if let count {
                    Text("\(count) controls")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.voltaTextTertiary)
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private var access: some View {
        LazyVGrid(columns: grid, spacing: 12) {
            stateTile(StateDisplay.doors(model.locked), title: "Doors", subtitle: "Lock & unlock",
                      isOn: model.locked, inactiveTone: .caution) { new in
                await model.setLocked(new, dataSource: dataSource, vehicleID: vehicleID)
            }
            actionTile(icon: "car.side.front.open", title: "Frunk", subtitle: "Front trunk", button: "Open") {
                run(VehicleCommand.actuateTrunk, params: ["which_trunk": "front"], label: "Open frunk")
            }
            actionTile(icon: "car.side.rear.open", title: "Trunk", subtitle: "Rear trunk", button: "Open") {
                run(VehicleCommand.actuateTrunk, params: ["which_trunk": "rear"], label: "Open trunk")
            }
            pairTile(icon: "window.vertical.open", title: "Windows", subtitle: "No data",
                     left: ("Vent", { run(VehicleCommand.windowControl, params: ["command": "vent"], label: "Vent windows") }),
                     right: ("Close", { run(VehicleCommand.windowControl, params: ["command": "close"], label: "Close windows") }))
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
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                stateHeader(StateDisplay.charging(model.chargingState), title: "Charging", subtitle: "Start, stop & limit",
                            isOn: model.chargingState.map { $0 == .charging }) { new in
                    await model.setCharging(new, dataSource: dataSource, vehicleID: vehicleID)
                }
                .padding(.bottom, 14)
                Rectangle().fill(Color.voltaHairline).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        caption("Charge limit")
                        Text(model.status.map { "Battery \($0.batteryLevel)%" } ?? "Battery —")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
                    Spacer()
                    LimitStepper(value: model.chargeLimit, isEnabled: model.canSend) { delta in
                        Task { await model.adjustChargeLimit(by: delta, dataSource: dataSource, vehicleID: vehicleID) }
                    }
                }
                .padding(.top, 12)
            }
            .modifier(TileSurface(tone: tone(StateDisplay.charging(model.chargingState), inactive: .idle)))

            pairTile(icon: "powerplug", title: "Charge port", subtitle: chargePortStatus, wide: true,
                     left: ("Open", { run(VehicleCommand.chargePortOpen, label: "Open charge port") }),
                     right: ("Close", { run(VehicleCommand.chargePortClose, label: "Close charge port") }))
        }
    }

    private var comfort: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: grid, spacing: 12) {
                stateTile(StateDisplay.climate(model.climateOn), title: "Climate", subtitle: "Precondition the cabin",
                          isOn: model.climateOn) { new in
                    await model.setClimate(new, dataSource: dataSource, vehicleID: vehicleID)
                }
                stateTile(StateDisplay.sentry(model.sentry), title: "Sentry", subtitle: "Security recording",
                          isOn: model.sentry) { new in
                    await model.setSentry(new, dataSource: dataSource, vehicleID: vehicleID)
                }
            }
            NavigationLink {
                ClimateControlsView(status: model.status, commandsAvailable: model.commandsAvailable)
            } label: {
                HStack(spacing: 14) {
                    TileGlyph(symbol: "thermometer.medium", tone: .idle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Climate controls").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                        Text("Seats, defrost & more").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.voltaTextTertiary)
                }
                .modifier(TileSurface(tone: nil))
                .contentShape(Rectangle())
            }
            .buttonStyle(VoltaPressStyle())
        }
    }

    private var locate: some View {
        LazyVGrid(columns: grid, spacing: 12) {
            actionTile(icon: "headlight.high.beam.fill", title: "Flash Lights", subtitle: "Flash the lights", button: "Flash") {
                run(VehicleCommand.flashLights, label: "Flash lights")
            }
            actionTile(icon: "megaphone.fill", title: "Honk Horn", subtitle: "Sound the horn", button: "Honk") {
                run(VehicleCommand.honk, label: "Honk")
            }
            actionTile(icon: "location.fill", title: "Locate", subtitle: "Play a sound to find it", button: "Ping") {
                run(VehicleCommand.locate, label: "Ping")
            }
            actionTile(icon: "house.fill", title: "HomeLink", subtitle: "Open nearby garage", button: "Open") {
                var params: [String: String] = [:]
                if let loc = model.status?.location {
                    params = ["lat": "\(loc.latitude)", "lon": "\(loc.longitude)"]
                }
                run(VehicleCommand.homelink, params: params, label: "HomeLink")
            }
        }
    }

    // MARK: Tile builders

    private func tone(_ display: StateDisplay, inactive: TileTone) -> TileTone {
        switch display.tone {
        case .active: .active
        case .inactive: inactive
        case .unknown: .unknown
        }
    }

    /// A lit tile for a command toggle whose state may be unknown. Known states
    /// are a toggle button (disabled unless commands can be sent); unknown
    /// states show "Unknown" with a dashed indicator and no control.
    @ViewBuilder
    private func stateTile(_ display: StateDisplay, title: String, subtitle: String, isOn: Bool?,
                           inactiveTone: TileTone = .idle, send: @escaping (Bool) async -> Void) -> some View {
        let tone = tone(display, inactive: inactiveTone)
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TileGlyph(symbol: display.symbol, tone: tone)
                Spacer()
                StateLight(tone: tone).padding(.top, 6)
            }
            Spacer(minLength: 14)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
            Text(display.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone == .idle ? Color.voltaTextSecondary : tone.color)
                .padding(.top, 3)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.voltaTextTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .modifier(TileSurface(tone: tone))

        if let isOn {
            Button { Task { await send(!isOn) } } label: { content.contentShape(Rectangle()) }
                .buttonStyle(VoltaPressStyle())
                .disabled(!model.canSend)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(display.text)
                .accessibilityAddTraits(.isToggle)
                .accessibilityHint(model.commandsAvailable ? "" : "Commands aren't available yet")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), state unknown")
        }
    }

    /// Full-width state header used inside the Charging tile.
    @ViewBuilder
    private func stateHeader(_ display: StateDisplay, title: String, subtitle: String, isOn: Bool?,
                             send: @escaping (Bool) async -> Void) -> some View {
        let tone = tone(display, inactive: .idle)
        let content = HStack(spacing: 14) {
            TileGlyph(symbol: display.symbol, tone: tone)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Text(display.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone == .idle ? Color.voltaTextSecondary : tone.color)
                StateLight(tone: tone)
            }
        }
        if let isOn {
            Button { Task { await send(!isOn) } } label: { content.contentShape(Rectangle()) }
                .buttonStyle(VoltaPressStyle())
                .disabled(!model.canSend)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(display.text)
                .accessibilityAddTraits(.isToggle)
                .accessibilityHint(model.commandsAvailable ? "" : "Commands aren't available yet")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), state unknown")
        }
    }

    private func actionTile(icon: String, title: String, subtitle: String, button: String,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TileGlyph(symbol: icon, tone: .idle)
                Spacer()
                VerbChip(title: button, action: action)
                    .opacity(model.commandsAvailable ? 1 : 0.55)
                    .disabled(!model.canSend)
            }
            Spacer(minLength: 18)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                .lineLimit(1).minimumScaleFactor(0.85)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.voltaTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 3)
        }
        .frame(minHeight: 112, alignment: .topLeading)
        .modifier(TileSurface(tone: nil))
        .accessibilityElement(children: .contain)
    }

    private func pairTile(icon: String, title: String, subtitle: String, wide: Bool = false,
                          left: (String, () -> Void), right: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if wide {
                HStack(spacing: 14) {
                    TileGlyph(symbol: icon, tone: .idle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                        Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 14)
            } else {
                TileGlyph(symbol: icon, tone: .idle)
                Spacer(minLength: 12)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.voltaTextPrimary)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                    .lineLimit(1).padding(.top, 3).padding(.bottom, 10)
            }
            HStack(spacing: 8) {
                VerbChip(title: left.0, stretch: true, action: left.1)
                VerbChip(title: right.0, stretch: true, action: right.1)
            }
            .opacity(model.commandsAvailable ? 1 : 0.55)
            .disabled(!model.canSend)
        }
        .frame(minHeight: wide ? nil : 112, alignment: .topLeading)
        .modifier(TileSurface(tone: nil))
        .accessibilityElement(children: .contain)
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
                    .foregroundStyle(toast.isError ? Color.voltaAmber : Color.voltaMint)
                Text(toast.message)
                    .font(.system(size: 13, weight: .medium))
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

// MARK: - Controls tiles

/// State light for a control tile: mint when active, amber for caution
/// (e.g. unlocked), a faint bar when idle, dashed when the state is unknown.
private enum TileTone: Equatable {
    case active, caution, idle, unknown

    var color: Color {
        switch self {
        case .active: .voltaMint
        case .caution: .voltaAmber
        case .idle: .voltaTextSecondary
        case .unknown: .voltaTextTertiary
        }
    }
}

private struct StateLight: View {
    var tone: TileTone

    var body: some View {
        Group {
            switch tone {
            case .active, .caution:
                Capsule().fill(tone.color)
                    .frame(width: 18, height: 3)
                    .shadow(color: tone.color.opacity(0.9), radius: 3)
                    .shadow(color: tone.color.opacity(0.5), radius: 9)
            case .idle:
                Capsule().fill(Color.white.opacity(0.14)).frame(width: 18, height: 3)
            case .unknown:
                Capsule()
                    .strokeBorder(Color.voltaTextTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 18, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small tinted symbol tile in the top-left of a control tile.
private struct TileGlyph: View {
    var symbol: String
    var tone: TileTone

    private var tint: Color {
        switch tone {
        case .active, .caution: tone.color
        case .idle: .white.opacity(0.85)
        case .unknown: .voltaTextTertiary
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(tone == .idle ? 0.07 : 0.16), tint.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tint.opacity(tone == .idle ? 0.08 : 0.22), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// Lit tile surface. Active and caution tiles pick up a faint top edge of light.
private struct TileSurface: ViewModifier {
    var tone: TileTone?

    private var glow: Color? {
        switch tone {
        case .active?, .caution?: tone?.color
        default: nil
        }
    }

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voltaCardBackground(radius: 20)
            .overlay(alignment: .top) {
                if let glow {
                    LinearGradient(colors: [.clear, glow.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                        .padding(.horizontal, 22)
                        .shadow(color: glow.opacity(0.6), radius: 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Quiet verb button ("Open", "Honk") used inside action tiles.
private struct VerbChip: View {
    var title: String
    var stretch = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary.opacity(isEnabled ? 1 : 0.7))
                .padding(.horizontal, 14)
                .frame(minWidth: 58, minHeight: 34)
                .frame(maxWidth: stretch ? .infinity : nil)
                .background(
                    LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom),
                    in: .capsule
                )
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(VoltaPressStyle())
    }
}

/// Hero lock dial: an open ring that glows mint when locked, amber when
/// unlocked, and shows a dashed tertiary ring when the state is unknown.
private struct LockDial: View {
    var locked: Bool?

    private var tint: Color {
        switch locked {
        case true?: .voltaMint
        case false?: .voltaAmber
        case nil: .voltaTextTertiary
        }
    }

    var body: some View {
        let display = StateDisplay.doors(locked)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(locked == nil ? 0 : 0.14), .clear], center: .center, startRadius: 0, endRadius: 64))
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            if locked != nil {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .blur(radius: 6)
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.35), tint, tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
            } else {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.voltaTextTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                    .rotationEffect(.degrees(135))
            }
            VStack(spacing: 6) {
                Image(systemName: display.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(locked == nil ? Color.voltaTextTertiary : .white)
                    .shadow(color: tint.opacity(locked == nil ? 0 : 0.6), radius: 8)
                Text(display.text)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
            }
            .offset(y: 4)
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Doors, \(display.text)")
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
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value ?? 0)))
                if value != nil {
                    Text("%").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.voltaTextSecondary)
                }
            }
            .frame(minWidth: 52)
            .foregroundStyle(value == nil ? Color.voltaTextTertiary : Color.voltaTextPrimary)
            button("plus", delta: 5, label: "Increase limit")
        }
        .padding(.vertical, 1)
        .background {
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(value.map { "Charge limit \($0) percent" } ?? "Charge limit unknown")
    }

    private var interactive: Bool { isEnabled && value != nil }

    private func button(_ symbol: String, delta: Int, label: String) -> some View {
        Button { change(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.voltaTextPrimary.opacity(interactive ? 0.9 : 0.35))
                .frame(width: 42, height: 38)
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

                HStack(alignment: .bottom, spacing: 0) {
                    reading("Cabin", celsius: status?.insideTempC, hero: true)
                    Spacer(minLength: 12)
                    reading("Set · driver", celsius: status?.driverTempSettingC, hero: false)
                }
                .padding(.top, VoltaSpacing.xl)
                .padding(.horizontal, 4)

                Text("Comfort")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Color.voltaTextTertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 30)
                    .padding(.bottom, 12)
                VStack(spacing: 0) {
                    ListRow(systemImage: "thermometer.medium", title: "Cabin", subtitle: "Inside temperature") {
                        Text(units.formatTemperature(status?.insideTempC)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
                    HairlineDivider(leadingInset: 46)
                    ListRow(systemImage: "dial.medium", title: "Set temperature", subtitle: "Driver") {
                        Text(units.formatTemperature(status?.driverTempSettingC)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.voltaTextSecondary)
                    }
                    HairlineDivider(leadingInset: 46)
                    ListRow(systemImage: "carseat.left.and.heat.waves", title: "Seat heaters", subtitle: "No data")
                    HairlineDivider(leadingInset: 46)
                    ListRow(systemImage: "windshield.front.and.heat.waves", title: "Defrost", subtitle: "No data")
                    HairlineDivider(leadingInset: 46)
                    ListRow(systemImage: "steeringwheel.and.heat.waves", title: "Steering wheel heat", subtitle: "No data")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .voltaCardBackground(radius: 22)
                if !commandsAvailable {
                    Text("Adjusting climate needs vehicle commands, which aren't connected yet.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.voltaTextTertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, VoltaSpacing.lg)
                }
            }
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.bottom, 40)
        }
        .background(alignment: .top) { ScreenKit.TopGlow() }
        .background(Color.voltaBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func reading(_ title: String, celsius: Double?, hero: Bool) -> some View {
        VStack(alignment: hero ? .leading : .trailing, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(1.3).textCase(.uppercase)
                .foregroundStyle(Color.voltaTextTertiary)
            if hero {
                BigNumber(celsius.map { VoltaFormat.number(units.temperatureValue(celsius: $0), digits: 0) } ?? "—",
                          unit: celsius == nil ? nil : units.temperatureUnit, size: 64, weight: .bold)
            } else {
                Text(units.formatTemperature(celsius))
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(celsius == nil ? Color.voltaTextTertiary : Color.voltaTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
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
