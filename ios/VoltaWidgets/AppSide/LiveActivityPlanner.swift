import Foundation

// APP TARGET ONLY. Pure decisions for Volta's Live Activities: which running
// activity to update, finish (final content) or dismiss, and whether to start
// one. `WidgetSync` applies a plan through ActivityKit; tests exercise the
// planner directly.

/// A running (active or stale) Live Activity as the planner sees it.
struct RunningActivity<Attributes: Hashable, State: Hashable>: Hashable {
    var id: String
    var attributes: Attributes
    var state: State
}

/// What to do with one running activity.
enum ExistingActivityAction<State: Hashable>: Hashable {
    /// Leave it untouched (e.g. the vehicle reported an unknown state). It goes stale on its own.
    case keep
    case update(State)
    /// The session ended: show this final content briefly, then dismiss.
    case finish(State)
    /// End immediately: another vehicle, a superseded session, a duplicate, or disabled.
    case dismiss
}

struct LiveActivityPlan<Attributes: Hashable, State: Hashable>: Hashable {
    struct Start: Hashable {
        var attributes: Attributes
        var state: State
    }
    /// Keyed by `RunningActivity.id`; every running activity has an entry.
    var existing: [String: ExistingActivityAction<State>] = [:]
    var start: Start?
}

enum LiveActivityPlanner {
    typealias ChargingRunning = RunningActivity<ChargingActivityAttributes, ChargingActivityAttributes.ContentState>
    typealias ChargingPlan = LiveActivityPlan<ChargingActivityAttributes, ChargingActivityAttributes.ContentState>
    typealias DrivingRunning = RunningActivity<DrivingActivityAttributes, DrivingActivityAttributes.ContentState>
    typealias DrivingPlan = LiveActivityPlan<DrivingActivityAttributes, DrivingActivityAttributes.ContentState>

    // MARK: Charging

    enum ChargingObservation: Hashable { case charging, completed, stopped, unknown }

    static func chargingObservation(_ status: VehicleStatus) -> ChargingObservation {
        switch status.chargingState {
        case .charging: return .charging
        case .complete: return .completed
        case .stopped, .disconnected: return .stopped
        case nil:
            switch status.state {
            case .charging: return .charging
            case .driving: return .stopped
            default: return .unknown
            }
        }
    }

    /// - Parameters:
    ///   - latestCharge: newest `ChargeSummary` for this vehicle (open when `end == nil`), if fetched.
    ///   - canStart: Live Activities are enabled for the app.
    static func planCharging(existing: [ChargingRunning], status: VehicleStatus, vehicleName: String,
                             latestCharge: ChargeSummary?, usesMiles: Bool, canStart: Bool,
                             now: Date) -> ChargingPlan {
        let observation = chargingObservation(status)
        let session = liveSession(status)
        // An open record of another session (TeslaMate not caught up yet) is not this charge's history.
        let openCharge = latestCharge.flatMap { $0.end == nil && matches(status, $0) ? $0 : nil }
        var startCharge = openCharge
        var plan = ChargingPlan()
        var claimed = false
        for activity in existing {
            let action: ExistingActivityAction<ChargingActivityAttributes.ContentState>
            if activity.attributes.vehicleId != status.vehicleId || claimed {
                action = .dismiss
            } else {
                switch observation {
                case .unknown:
                    action = .keep
                case .charging:
                    // The live session decides when both are known, whatever history says.
                    // An activity's own history charge that isn't the live session has ended.
                    let tracked = activity.state.statusSessionId
                    let same: Bool
                    if let tracked, let session {
                        same = tracked == session
                        // The record the previous session already claimed is not the new one's.
                        if !same, let id = activity.attributes.chargeId, id == openCharge?.id { startCharge = nil }
                    } else if session != nil, activity.attributes.chargeId == nil {
                        same = false  // no identity at all: replaced once the live session is known
                    } else if let own = latestCharge, own.id == activity.attributes.chargeId, !matches(status, own) {
                        same = false
                    } else {
                        same = sameSession(activity.attributes.chargeId, openCharge?.id)
                    }
                    action = same
                        ? .update(chargingState(status: status, openCharge: openCharge, previous: activity.state))
                        : .dismiss
                case .completed, .stopped:
                    action = .finish(finalChargingState(status: status, observation: observation,
                                                        attributes: activity.attributes,
                                                        latestCharge: latestCharge, previous: activity.state))
                }
            }
            if action != .dismiss { claimed = true }
            plan.existing[activity.id] = action
        }
        if observation == .charging, !claimed, canStart,
           now.timeIntervalSince(status.updatedAt) < VoltaLiveActivityTiming.chargingStaleAfter {
            let attributes = ChargingActivityAttributes(
                vehicleId: status.vehicleId,
                chargeId: startCharge?.id,
                vehicleName: vehicleName,
                placeName: startCharge?.placeName ?? status.location?.placeName,
                startedAt: startCharge?.start,
                startBatteryLevel: startCharge?.startBatteryLevel,
                fastCharger: startCharge?.fastCharger,
                usesMiles: usesMiles)
            plan.start = .init(attributes: attributes,
                               state: chargingState(status: status, openCharge: startCharge, previous: nil))
        }
        return plan
    }

    /// `openCharge` must already match the status (see `matches`); `previous` is nil for a new activity.
    static func chargingState(status: VehicleStatus, openCharge: ChargeSummary?,
                              previous: ChargingActivityAttributes.ContentState?) -> ChargingActivityAttributes.ContentState {
        let session = liveSession(status)
        // The activity follows the live session it started with, or first saw alongside its history.
        let tracked = previous == nil || openCharge != nil ? previous?.statusSessionId ?? session : previous?.statusSessionId
        let live = tracked != nil && tracked == session ? status.chargeEnergyAddedKwh : nil
        return .init(batteryLevel: status.batteryLevel,
                     chargeLimit: status.chargeLimit,
                     chargerPowerKw: status.chargerPowerKw,
                     fullAt: status.chargeReadyAt ?? status.minutesToFull.map { status.updatedAt.addingTimeInterval(Double($0) * 60) },
                     energyAddedKwh: live ?? openCharge?.energyAddedKwh ?? previous?.energyAddedKwh,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm,
                     phase: .charging,
                     updatedAt: status.updatedAt,
                     endedAt: nil,
                     statusSessionId: tracked)
    }

    /// How long TeslaMate's start of a charge may trail (positive) or lead (negative) Fleet
    /// Telemetry's start of the same charge. Telemetry sees a start first; TeslaMate's poll
    /// trailed it by 27 minutes in practice. Outside this, the two are different sessions.
    static let teslaMateStartLag: ClosedRange<TimeInterval> = -5 * 60 ... 60 * 60

    /// The status's live Fleet Telemetry session, whose counter `chargeEnergyAddedKwh` is.
    /// Telemetry sessions have negative ids; a positive one is TeslaMate's open process.
    static func liveSession(_ status: VehicleStatus) -> Int? {
        guard status.chargeStartedAt != nil, let id = status.activeChargeId, id < 0 else { return nil }
        return id
    }

    /// Whether a history charge is the status's live session: the same id, or a TeslaMate
    /// record starting with it (the two number one charge differently). Without a live
    /// session there is nothing to contradict history.
    static func matches(_ status: VehicleStatus, _ charge: ChargeSummary) -> Bool {
        guard let session = liveSession(status), let started = status.chargeStartedAt else { return true }
        return charge.id == session || teslaMateStartLag.contains(charge.start.timeIntervalSince(started))
    }

    /// Final content: no power or countdown, the end time, and the last known totals.
    static func finalChargingState(status: VehicleStatus, observation: ChargingObservation,
                                   attributes: ChargingActivityAttributes, latestCharge: ChargeSummary?,
                                   previous: ChargingActivityAttributes.ContentState) -> ChargingActivityAttributes.ContentState {
        // The activity's charge, by its history id or the live session it followed.
        let ids = [attributes.chargeId, previous.statusSessionId].compactMap { $0 }
        let closed = latestCharge.flatMap { $0.end != nil && ids.contains($0.id) ? $0 : nil }
        // Without a closed summary, the tracked session's own final counter.
        let tracked = previous.statusSessionId
        let counter = tracked != nil && tracked == liveSession(status) ? status.chargeEnergyAddedKwh : nil
        return .init(batteryLevel: closed?.endBatteryLevel ?? status.batteryLevel,
                     chargeLimit: status.chargeLimit ?? previous.chargeLimit,
                     chargerPowerKw: nil,
                     fullAt: nil,
                     energyAddedKwh: closed?.energyAddedKwh ?? counter ?? previous.energyAddedKwh,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm ?? previous.rangeKm,
                     phase: observation == .completed ? .completed : .stopped,
                     updatedAt: status.updatedAt,
                     endedAt: closed?.end ?? status.updatedAt,
                     statusSessionId: previous.statusSessionId)
    }

    // MARK: Driving

    enum DrivingObservation: Hashable { case driving, ended, unknown }

    static func drivingObservation(_ status: VehicleStatus) -> DrivingObservation {
        switch status.state {
        case .driving: .driving
        // Offline can be a tunnel or a dead zone mid-drive; let the activity go stale instead.
        case .offline: .unknown
        case .online, .asleep, .charging, .updating: .ended
        }
    }

    /// - Parameters:
    ///   - latestDrive: newest `DriveSummary` for this vehicle (open when `end == nil`), if fetched.
    ///   - enabled: the user wants a Live Activity while driving.
    static func planDriving(existing: [DrivingRunning], status: VehicleStatus, vehicleName: String,
                            latestDrive: DriveSummary?, usesMiles: Bool, enabled: Bool, canStart: Bool,
                            now: Date) -> DrivingPlan {
        let observation = drivingObservation(status)
        let openDrive = latestDrive?.end == nil ? latestDrive : nil
        var plan = DrivingPlan()
        var claimed = false
        for activity in existing {
            let action: ExistingActivityAction<DrivingActivityAttributes.ContentState>
            if !enabled || activity.attributes.vehicleId != status.vehicleId || claimed {
                action = .dismiss
            } else {
                switch observation {
                case .unknown:
                    action = .keep
                case .driving:
                    action = sameSession(activity.attributes.driveId, openDrive?.id)
                        ? .update(drivingState(status: status, openDrive: openDrive, previous: activity.state))
                        : .dismiss
                case .ended:
                    action = .finish(finalDrivingState(status: status, attributes: activity.attributes,
                                                       latestDrive: latestDrive, previous: activity.state))
                }
            }
            if action != .dismiss { claimed = true }
            plan.existing[activity.id] = action
        }
        if enabled, observation == .driving, !claimed, canStart,
           now.timeIntervalSince(status.updatedAt) < VoltaLiveActivityTiming.drivingStaleAfter {
            let attributes = DrivingActivityAttributes(
                vehicleId: status.vehicleId,
                driveId: openDrive?.id,
                vehicleName: vehicleName,
                startedAt: openDrive?.start,
                startAddress: openDrive?.startAddress,
                startBatteryLevel: openDrive?.startBatteryLevel,
                usesMiles: usesMiles)
            plan.start = .init(attributes: attributes,
                               state: drivingState(status: status, openDrive: openDrive, previous: nil))
        }
        return plan
    }

    static func drivingState(status: VehicleStatus, openDrive: DriveSummary?,
                             previous: DrivingActivityAttributes.ContentState?) -> DrivingActivityAttributes.ContentState {
        .init(batteryLevel: status.batteryLevel,
              rangeKm: status.estRangeKm ?? status.ratedRangeKm,
              distanceKm: openDrive?.distanceKm ?? previous?.distanceKm,
              energyUsedKwh: openDrive?.energyUsedKwh ?? previous?.energyUsedKwh,
              phase: .driving,
              updatedAt: status.updatedAt,
              endedAt: nil)
    }

    static func finalDrivingState(status: VehicleStatus, attributes: DrivingActivityAttributes,
                                  latestDrive: DriveSummary?,
                                  previous: DrivingActivityAttributes.ContentState) -> DrivingActivityAttributes.ContentState {
        let closed = latestDrive.flatMap { drive in
            drive.end != nil && attributes.driveId != nil && drive.id == attributes.driveId ? drive : nil
        }
        return .init(batteryLevel: closed?.endBatteryLevel ?? status.batteryLevel,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm ?? previous.rangeKm,
                     distanceKm: closed?.distanceKm ?? previous.distanceKm,
                     energyUsedKwh: closed?.energyUsedKwh ?? previous.energyUsedKwh,
                     phase: .ended,
                     updatedAt: status.updatedAt,
                     endedAt: closed?.end ?? status.updatedAt)
    }

    // MARK: Identity

    /// Whether a running activity still describes the observed session.
    ///
    /// - Observed id unknown (history fetch failed): keep the activity, nothing
    ///   says it changed.
    /// - Observed id known: it must equal the running id. An activity started
    ///   without an id (`nil`) is replaced once the id is known, so its
    ///   immutable attributes (start time, place, charger type, id for
    ///   finalization) come from the real session.
    static func sameSession(_ running: Int?, _ observed: Int?) -> Bool {
        guard let observed else { return true }
        return running == observed
    }
}
