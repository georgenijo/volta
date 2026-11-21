import SwiftUI

/// Everything a control needs to send a command: the shared model, the
/// app's command coordinator and the vehicle. Built by a view from its
/// environment, so the Dashboard and Controls send through one path.
@MainActor
struct VehicleCommandContext {
    let model: ControlsModel
    let coordinator: VehicleCommandCoordinator
    let dataSource: any VoltaDataSource
    let vehicleID: Int
    let surfaces: (any VehicleSurfaces)?

    /// The server (or demo) can run `command` for this vehicle at all.
    func supports(_ command: VehicleCommand) -> Bool {
        coordinator.supports(command, dataSource: dataSource, vehicleID: vehicleID)
    }

    /// `command` can be sent now: supported, and nothing else in flight or unresolved.
    func canStart(_ command: VehicleCommand) -> Bool {
        model.canStart(command, coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID)
    }

    /// The coordinator's latest activity is `command` and still sending.
    func isSending(_ command: VehicleCommand) -> Bool {
        guard let activity = coordinator.activity(dataSource: dataSource, vehicleID: vehicleID) else { return false }
        return activity.phase == .pending && activity.command == command
    }

    func send(_ command: VehicleCommand) {
        Task { await model.send(command, coordinator: coordinator, dataSource: dataSource,
                                vehicleID: vehicleID, surfaces: surfaces) }
    }

    func stepChargeLimit(by delta: Int) {
        model.stepChargeLimit(by: delta, coordinator: coordinator, dataSource: dataSource,
                              vehicleID: vehicleID, surfaces: surfaces)
    }

    func stepCabinTarget(by steps: Int) {
        model.stepCabinTarget(by: steps, coordinator: coordinator, dataSource: dataSource,
                              vehicleID: vehicleID, surfaces: surfaces)
    }

    var logKey: String { VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID) }

    func refresh() async {
        await model.refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces)
    }
}

// MARK: - Charge limit

/// The one charge limit stepper, used by the Now card and Controls. Steps
/// move the shown value at once; one command is sent after a short pause.
struct ChargeLimitStepper: View {
    var context: VehicleCommandContext

    var body: some View {
        let model = context.model
        let value = model.displayedChargeLimit
        let enabled = value.map { context.canStart(.setChargeLimit(percent: $0)) } ?? false
        ValueStepper(label: "Charge limit",
                     value: value.map { "\($0)%" } ?? "—",
                     accessibilityValue: value.map { "\($0) percent" } ?? "Unknown",
                     canDecrease: enabled && (value ?? 0) > ControlsModel.chargeLimitRange.lowerBound,
                     canIncrease: enabled && (value ?? 100) < ControlsModel.chargeLimitRange.upperBound,
                     decrease: { context.stepChargeLimit(by: -ControlsModel.chargeLimitStep) },
                     increase: { context.stepChargeLimit(by: ControlsModel.chargeLimitStep) })
            .accessibilityIdentifier("stepper.chargeLimit")
    }
}

// MARK: - Command log

/// "Sent this session": commands sent from this device since launch, newest
/// first, with their outcome in words that match the evidence.
struct CommandLogList: View {
    var log: VehicleCommandLog
    var key: String
    var limit = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = Array(log.entries(for: key).prefix(limit))
        VStack(alignment: .leading, spacing: VoltaSpacing.sm) {
            Text("Sent this session")
                .voltaLabelStyle()
                .padding(.leading, VoltaSpacing.xs)
                .accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text("Nothing sent from this device yet.")
                    .font(.subheadline)
                    .foregroundStyle(Color.voltaTextSecondary)
                    .padding(.leading, VoltaSpacing.xs)
                    .frame(minHeight: 32, alignment: .leading)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry, now: context.date)
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(VoltaMotion.animation(VoltaMotion.arrive, reduceMotion: reduceMotion), value: entries.map(\.id))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list.commandLog")
    }

    private func row(_ entry: VehicleCommandLog.Entry, now: Date) -> some View {
        let time = Self.relative(entry.updatedAt, now: now)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: VoltaSpacing.md) {
                icon(entry.outcome)
                Text(entry.label).font(.body).foregroundStyle(Color.voltaTextPrimary)
                Spacer(minLength: VoltaSpacing.sm)
                Text("\(entry.outcome.text) · \(time)").font(.subheadline)
                    .foregroundStyle(Self.color(entry.outcome))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: VoltaSpacing.md) {
                    icon(entry.outcome)
                    Text(entry.label).font(.body).foregroundStyle(Color.voltaTextPrimary)
                }
                Text("\(entry.outcome.text) · \(time)").font(.subheadline)
                    .foregroundStyle(Self.color(entry.outcome))
            }
        }
        .padding(.horizontal, VoltaSpacing.xs)
        .frame(minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.label), \(entry.outcome.text), \(time)")
    }

    /// The outcome's symbol. It stays in place while the outcome changes, so
    /// it can swap (replace), bounce when the command is accepted or
    /// confirmed, and wiggle when it fails.
    @ViewBuilder
    private func icon(_ outcome: VehicleCommandLog.Outcome) -> some View {
        ZStack {
            if outcome == .sending { ProgressView().controlSize(.mini).tint(Color.voltaTextSecondary) }
            Image(systemName: Self.symbol(outcome))
                .opacity(outcome == .sending ? 0 : 1)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating,
                              isActive: !reduceMotion && [.accepted, .confirmed, .simulated].contains(outcome))
                .symbolEffect(.wiggle, options: .nonRepeating, isActive: !reduceMotion && outcome == .failed)
        }
        .animation(VoltaMotion.animation(VoltaMotion.snappy, reduceMotion: reduceMotion), value: outcome)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Self.color(outcome))
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    static func symbol(_ outcome: VehicleCommandLog.Outcome) -> String {
        switch outcome {
        case .sending: "clock"
        case .simulated: "theatermasks"
        case .accepted: "checkmark"
        case .confirmed: "checkmark.circle"
        case .failed: "xmark"
        case .unknown: "questionmark"
        }
    }

    /// Outcomes are neutral; only a failure is red and an unknown outcome amber.
    static func color(_ outcome: VehicleCommandLog.Outcome) -> Color {
        switch outcome {
        case .failed: .voltaRed
        case .unknown: .voltaAmber
        default: .voltaTextSecondary
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 45 ? "just now" : VoltaFormat.relativeDate(date, now: now)
    }
}

// MARK: - Retry

extension VehicleCommandCoordinator {
    /// Retries a saved request and writes the result to its session log
    /// entry, but only when the server answered the retry definitely. A retry
    /// that could not start, or that came back unresolved again, says
    /// nothing about the original send, so its entry stays "Outcome unknown".
    @discardableResult
    func retry(_ activity: Activity, log: VehicleCommandLog, dataSource: any VoltaDataSource,
               vehicleID: Int) async -> Outcome {
        let answeredBefore = wasAnswered(activity.id)
        let result = await retry(activity.id, dataSource: dataSource, vehicleID: vehicleID)
        if !answeredBefore, wasAnswered(activity.id) {
            log.settleRetry(of: activity.command,
                            key: VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID),
                            with: result)
        }
        return result
    }
}

// MARK: - Activity banner

/// The coordinator's latest command activity (sending, accepted, simulated,
/// failed, outcome unknown) with its retry and acknowledgement actions.
struct VehicleCommandActivityBanner: View {
    let coordinator: VehicleCommandCoordinator
    let dataSource: any VoltaDataSource
    let vehicleID: Int
    /// The session log a retried request's result is written back to.
    var log: VehicleCommandLog = .shared
    let refreshObservedStatus: () -> Void
    private struct Confirmation: Identifiable {
        let id = UUID()
        let activity: VehicleCommandCoordinator.Activity
        let isRetry: Bool
    }
    @State private var confirmation: Confirmation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = coordinator.activity(dataSource: dataSource, vehicleID: vehicleID)
        Group {
            if let activity = current {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: VoltaSpacing.md) {
                        // One symbol for the whole life of the command: a
                        // spinner over it while sending, then it swaps to the
                        // outcome and bounces (accepted) or wiggles (failed).
                        ZStack {
                            if activity.phase == .pending { ProgressView().tint(Color.voltaTextPrimary) }
                            Image(systemName: symbol(activity.phase))
                                .foregroundStyle(color(activity.phase))
                                .opacity(activity.phase == .pending ? 0 : 1)
                                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                                .symbolEffect(.bounce, options: .nonRepeating,
                                              isActive: !reduceMotion && [.success, .simulated].contains(activity.phase))
                                .symbolEffect(.wiggle, options: .nonRepeating,
                                              isActive: !reduceMotion && activity.phase == .failure)
                        }
                        .font(.body.weight(.semibold))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                        Text(activity.message).font(.subheadline).foregroundStyle(Color.voltaTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        Spacer(minLength: 0)
                        action(activity, now: context.date)
                    }
                    .padding(.horizontal, VoltaSpacing.lg).padding(.vertical, VoltaSpacing.md)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: VoltaRadius.control))
                    .padding(.horizontal, VoltaSpacing.screen).padding(.bottom, VoltaSpacing.xl)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("banner.commandActivity")
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(VoltaMotion.animation(VoltaMotion.arrive, reduceMotion: reduceMotion), value: current)
        .alert(item: $confirmation) { item in
            let activity = item.activity
            if item.isRetry {
                return Alert(title: Text("Retry \(activity.label.lowercased())?"),
                             message: Text("If the original request was not accepted, this can execute it now. " + activity.command.retryCaution),
                             primaryButton: .cancel(), secondaryButton: .destructive(Text("Retry \(activity.label)")) {
                    Task {
                        let result = await coordinator.retry(activity, log: log, dataSource: dataSource, vehicleID: vehicleID)
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
                    .frame(minHeight: 44)
                    .disabled(coordinator.isBusy(dataSource: dataSource, vehicleID: vehicleID))
            }
        } else if coordinator.pending(dataSource: dataSource, vehicleID: vehicleID).isEmpty {
            Button { coordinator.clearActivity(dataSource: dataSource, vehicleID: vehicleID) } label: {
                Image(systemName: "xmark").foregroundStyle(Color.voltaTextSecondary)
                    .frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel("Dismiss result")
        }
    }

    private func symbol(_ phase: VehicleCommandCoordinator.Phase) -> String {
        switch phase { case .success, .simulated: "checkmark.circle.fill"; case .failure: "xmark.circle.fill"; case .unknown: "questionmark.circle.fill"; case .pending: "clock" }
    }
    /// Done reads in ink, failed in red, unknown in amber.
    private func color(_ phase: VehicleCommandCoordinator.Phase) -> Color {
        switch phase { case .success, .simulated: .voltaTextPrimary; case .failure: .voltaRed; case .unknown: .voltaAmber; case .pending: .voltaTextSecondary }
    }
}
