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
        let openCharge = latestCharge?.end == nil ? latestCharge : nil
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
                    action = sameSession(activity.attributes.chargeId, openCharge?.id)
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
                chargeId: openCharge?.id,
                vehicleName: vehicleName,
                placeName: openCharge?.placeName ?? status.location?.placeName,
                startedAt: openCharge?.start,
                startBatteryLevel: openCharge?.startBatteryLevel,
                fastCharger: openCharge?.fastCharger,
                usesMiles: usesMiles)
            plan.start = .init(attributes: attributes,
                               state: chargingState(status: status, openCharge: openCharge, previous: nil))
        }
        return plan
    }

    static func chargingState(status: VehicleStatus, openCharge: ChargeSummary?,
                              previous: ChargingActivityAttributes.ContentState?) -> ChargingActivityAttributes.ContentState {
        .init(batteryLevel: status.batteryLevel,
              chargeLimit: status.chargeLimit,
              chargerPowerKw: status.chargerPowerKw,
              fullAt: status.minutesToFull.map { status.updatedAt.addingTimeInterval(Double($0) * 60) },
              energyAddedKwh: openCharge?.energyAddedKwh ?? previous?.energyAddedKwh,
              rangeKm: status.estRangeKm ?? status.ratedRangeKm,
              phase: .charging,
              updatedAt: status.updatedAt,
              endedAt: nil)
    }

    /// Final content: no power or countdown, the end time, and the last known totals.
    static func finalChargingState(status: VehicleStatus, observation: ChargingObservation,
                                   attributes: ChargingActivityAttributes, latestCharge: ChargeSummary?,
                                   previous: ChargingActivityAttributes.ContentState) -> ChargingActivityAttributes.ContentState {
        let closed = latestCharge.flatMap { charge in
            charge.end != nil && attributes.chargeId != nil && charge.id == attributes.chargeId ? charge : nil
        }
        return .init(batteryLevel: closed?.endBatteryLevel ?? status.batteryLevel,
                     chargeLimit: status.chargeLimit ?? previous.chargeLimit,
                     chargerPowerKw: nil,
                     fullAt: nil,
                     energyAddedKwh: closed?.energyAddedKwh ?? previous.energyAddedKwh,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm ?? previous.rangeKm,
                     phase: observation == .completed ? .completed : .stopped,
                     updatedAt: status.updatedAt,
                     endedAt: closed?.end ?? status.updatedAt)
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
