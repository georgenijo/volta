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
    ///
    /// A charge has two names: its Fleet Telemetry session (negative id) and TeslaMate's process
    /// (positive id, also its charge id), which opens minutes later. An activity remembers each
    /// id the status names for it and is replaced only when the status names a different charge.
    /// History is matched by start time only when an activity starts; afterwards only exact ids
    /// count, so a record that merely starts near this charge never lends it totals.
    static func planCharging(existing: [ChargingRunning], status: VehicleStatus, vehicleName: String,
                             latestCharge: ChargeSummary?, usesMiles: Bool, canStart: Bool,
                             now: Date) -> ChargingPlan {
        let observation = chargingObservation(status)
        var plan = ChargingPlan()
        var claimed = false
        var replaced: Set<Int> = []  // ids of charges the status has moved on from
        var enriched: (identity: ChargeIdentity, previous: ChargingActivityAttributes.ContentState)?
        let canRestart = canStart && now.timeIntervalSince(status.updatedAt) < VoltaLiveActivityTiming.chargingStaleAfter
        for activity in existing {
            let action: ExistingActivityAction<ChargingActivityAttributes.ContentState>
            if activity.attributes.vehicleId != status.vehicleId || claimed {
                action = .dismiss
            } else {
                switch observation {
                case .unknown:
                    action = .keep
                case .charging:
                    switch follow(activity, status: status, latestCharge: latestCharge) {
                    case .enrich(let identity) where canRestart:
                        enriched = (identity, activity.state)
                        action = .dismiss
                    case .same(let identity), .enrich(let identity):
                        // Only an exact record, and only while no live counter is tracked.
                        let recorded = identity.session == nil
                            ? latestCharge.flatMap { $0.end == nil && $0.id == identity.teslaMate ? $0.energyAddedKwh : nil }
                            : nil
                        action = .update(chargingState(status: status, identity: identity, recordedEnergy: recorded,
                                                       previous: activity.state))
                    case .unrelated:
                        action = .keep
                    case .other(let identity):
                        replaced.formUnion([identity.session, identity.teslaMate, activity.attributes.chargeId].compactMap { $0 })
                        replaced.formUnion(identity.others)
                        action = .dismiss
                    }
                case .completed, .stopped:
                    action = .finish(finalChargingState(status: status, observation: observation,
                                                        attributes: activity.attributes,
                                                        identity: identity(of: activity, latestCharge: latestCharge),
                                                        latestCharge: latestCharge, previous: activity.state))
                }
            }
            if action != .dismiss || enriched != nil { claimed = true }
            plan.existing[activity.id] = action
        }
        if observation == .charging, canRestart, enriched != nil || !claimed {
            var identity: ChargeIdentity
            let history: ChargeSummary?
            var recorded: Double?
            if let enriched {
                // The same charge, now with its record: keep what the activity established.
                identity = enriched.identity
                history = latestCharge
                recorded = (identity.session == nil ? history?.energyAddedKwh : nil) ?? enriched.previous.energyAddedKwh
            } else {
                identity = ChargeIdentity(others: replaced)
                history = latestCharge.flatMap { $0.end == nil && !replaced.contains($0.id) && startMatches(status, $0) ? $0 : nil }
                recorded = history?.energyAddedKwh
                if let session = liveSession(status) { identity.session = session; identity.sessionStart = status.chargeStartedAt }
                if liveSession(status) == nil, let process = namedProcess(status), !replaced.contains(process) {
                    identity.teslaMate = process
                    identity.teslaMateStart = status.chargeStartedAt ?? history.flatMap { $0.id == process ? $0.start : nil }
                }
                if let history, history.id < 0 {
                    identity.session = history.id; identity.sessionStart = identity.sessionStart ?? history.start
                } else if let history, identity.teslaMate == nil {
                    identity.teslaMate = history.id; identity.teslaMateStart = history.start
                }
            }
            let attributes = ChargingActivityAttributes(
                vehicleId: status.vehicleId,
                chargeId: history?.id,
                vehicleName: vehicleName,
                placeName: history?.placeName ?? status.location?.placeName,
                startedAt: history?.start,
                startBatteryLevel: history?.startBatteryLevel,
                fastCharger: history?.fastCharger,
                usesMiles: usesMiles)
            plan.start = .init(attributes: attributes,
                               state: chargingState(status: status, identity: identity,
                                                    recordedEnergy: recorded, previous: nil))
        }
        return plan
    }

    /// The ids an activity's charge is known by, each with its start.
    struct ChargeIdentity: Hashable {
        var session: Int?
        var sessionStart: Date?
        var teslaMate: Int?
        var teslaMateStart: Date?
        /// Charges this activity replaced, whose ids it never adopts.
        var others: Set<Int> = []
    }

    enum ChargeFollow: Hashable {
        /// Still this activity's charge, with any id the status newly named for it.
        case same(ChargeIdentity)
        /// This charge, whose details the activity lacks: start again with them.
        case enrich(ChargeIdentity)
        /// The status names another charge.
        case other(ChargeIdentity)
        /// The status describes a charge that isn't the current one (a replaced charge's process, or
        /// an older one TeslaMate never closed): leave the activity as it is.
        case unrelated
    }

    static func identity(of activity: ChargingRunning, latestCharge: ChargeSummary?) -> ChargeIdentity {
        let state = activity.state
        var identity = ChargeIdentity(session: state.statusSessionId, sessionStart: state.sessionStartedAt,
                                      teslaMate: state.teslaMateChargeId, teslaMateStart: state.teslaMateStartedAt,
                                      others: Set(state.otherChargeIds ?? []))
        // Activities from earlier builds know only their history charge.
        if identity.session == nil, identity.teslaMate == nil, let id = activity.attributes.chargeId {
            if id < 0 { identity.session = id } else { identity.teslaMate = id }
        }
        // A start the status didn't give comes from the charge's own record.
        func recordedStart(_ id: Int?) -> Date? {
            guard let id else { return nil }
            return (activity.attributes.chargeId == id ? activity.attributes.startedAt : nil)
                ?? latestCharge.flatMap { $0.id == id ? $0.start : nil }
        }
        if identity.sessionStart == nil { identity.sessionStart = recordedStart(identity.session) }
        if identity.teslaMateStart == nil { identity.teslaMateStart = recordedStart(identity.teslaMate) }
        return identity
    }

    /// Whether the status still describes the activity's charge.
    static func follow(_ activity: ChargingRunning, status: VehicleStatus, latestCharge: ChargeSummary?) -> ChargeFollow {
        var identity = identity(of: activity, latestCharge: latestCharge)
        let named = status.chargeStartedAt
        if liveSession(status) == nil, let process = namedProcess(status) {
            if identity.others.contains(process) {
                return .unrelated
            } else if let known = identity.teslaMate {
                // Two TeslaMate ids compare without a start; a process older than this charge is
                // one TeslaMate never closed.
                if known != process { return startsBefore(named, identity) ? .unrelated : .other(identity) }
                if identity.teslaMateStart == nil { identity.teslaMateStart = named }
            } else if identity.session == nil, !identity.others.contains(process) {
                // Nothing to check it against: the named process is this charge.
                identity.teslaMate = process; identity.teslaMateStart = named
            }
        }
        if let session = liveSession(status), let named {
            if let known = identity.session {
                if known != session { return .other(identity) }
            } else if identity.others.contains(session) {
                return .other(identity)
            } else if identity.teslaMate != nil {
                // TeslaMate's record must start with the session; unknown start can't be checked.
                guard let start = identity.teslaMateStart, sameCharge(teslaMateStart: start, sessionStart: named)
                else { return .other(identity) }
                identity.session = session; identity.sessionStart = named
            } else {
                identity.session = session; identity.sessionStart = named
            }
        } else if let process = teslaMateProcess(status), let named, identity.teslaMate == nil,
                  !identity.others.contains(process) {
            if identity.session != nil {
                // TeslaMate names a process while telemetry is quiet. Starting with the session it is
                // this charge; starting well after, a later one; starting before, an older process
                // TeslaMate never closed, which says nothing about this charge.
                guard let start = identity.sessionStart else { return .same(identity) }
                let lag = named.timeIntervalSince(start)
                if teslaMateStartLag.contains(lag) {
                    identity.teslaMate = process; identity.teslaMateStart = named
                } else if lag > teslaMateStartLag.upperBound {
                    return .other(identity)
                } else {
                    return .unrelated
                }
            } else {
                identity.teslaMate = process; identity.teslaMateStart = named
            }
        } else if namedProcess(status) == nil, identity.session == nil, let known = identity.teslaMate,
                  let open = latestCharge, open.end == nil, open.id != known {
            return .other(identity)  // the status names no charge; history has moved on
        }
        // An activity started without history takes its charge's exact record once it appears.
        if activity.attributes.chargeId == nil, let open = latestCharge, open.end == nil {
            let exact = open.id == identity.session || open.id == identity.teslaMate
            let unnamed = identity.session == nil && identity.teslaMate == nil && !identity.others.contains(open.id)
            if unnamed {
                if open.id < 0 { identity.session = open.id; identity.sessionStart = open.start }
                else { identity.teslaMate = open.id; identity.teslaMateStart = open.start }
            }
            if exact || unnamed { return .enrich(identity) }
        }
        return .same(identity)
    }

    /// `recordedEnergy` is history's total for exactly this charge, if any; `previous` is nil for
    /// a new activity.
    static func chargingState(status: VehicleStatus, identity: ChargeIdentity, recordedEnergy: Double?,
                              previous: ChargingActivityAttributes.ContentState?) -> ChargingActivityAttributes.ContentState {
        let live = identity.session != nil && identity.session == liveSession(status) ? status.chargeEnergyAddedKwh : nil
        return .init(batteryLevel: status.batteryLevel,
                     chargeLimit: status.chargeLimit,
                     chargerPowerKw: status.chargerPowerKw,
                     fullAt: status.chargeReadyAt ?? status.minutesToFull.map { status.updatedAt.addingTimeInterval(Double($0) * 60) },
                     energyAddedKwh: live ?? recordedEnergy ?? previous?.energyAddedKwh,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm,
                     phase: .charging,
                     updatedAt: status.updatedAt,
                     endedAt: nil,
                     statusSessionId: identity.session,
                     sessionStartedAt: identity.sessionStart,
                     teslaMateChargeId: identity.teslaMate,
                     teslaMateStartedAt: identity.teslaMateStart,
                     otherChargeIds: identity.others.isEmpty ? nil : identity.others.sorted())
    }

    /// How long TeslaMate's start of a charge may trail Fleet Telemetry's start of the same
    /// charge. Telemetry sees a start first (TeslaMate's poll trailed it by 7 and 27 minutes in
    /// practice); the small lead allows for clock differences.
    static let teslaMateStartLag: ClosedRange<TimeInterval> = -60 ... 60 * 60

    /// Whether a TeslaMate process started before this activity's charge: before its own
    /// TeslaMate process (the same clock), else beyond clock differences before its session.
    static func startsBefore(_ start: Date?, _ identity: ChargeIdentity) -> Bool {
        guard let start else { return false }
        if let own = identity.teslaMateStart { return start < own }
        guard let session = identity.sessionStart else { return false }
        return start.timeIntervalSince(session) < teslaMateStartLag.lowerBound
    }

    static func sameCharge(teslaMateStart: Date, sessionStart: Date) -> Bool {
        teslaMateStartLag.contains(teslaMateStart.timeIntervalSince(sessionStart))
    }

    /// The status's live Fleet Telemetry session, whose counter `chargeEnergyAddedKwh` is.
    static func liveSession(_ status: VehicleStatus) -> Int? {
        guard status.chargeStartedAt != nil, let id = status.activeChargeId, id < 0 else { return nil }
        return id
    }

    /// The status's open TeslaMate process, named when telemetry doesn't describe the charge.
    static func teslaMateProcess(_ status: VehicleStatus) -> Int? {
        guard status.chargeStartedAt != nil, let id = status.activeChargeId, id > 0 else { return nil }
        return id
    }

    /// The TeslaMate process the status names, with or without its start.
    static func namedProcess(_ status: VehicleStatus) -> Int? {
        guard let id = status.activeChargeId, id > 0 else { return nil }
        return id
    }

    /// Whether an open history charge is the one the status describes, for a new activity.
    static func startMatches(_ status: VehicleStatus, _ charge: ChargeSummary) -> Bool {
        if let session = liveSession(status), let start = status.chargeStartedAt {
            return charge.id == session || charge.id > 0 && sameCharge(teslaMateStart: charge.start, sessionStart: start)
        }
        if let process = namedProcess(status) { return charge.id == process }
        return true
    }

    /// Final content: no power or countdown, the end time, and the last known totals.
    static func finalChargingState(status: VehicleStatus, observation: ChargingObservation,
                                   attributes: ChargingActivityAttributes, identity: ChargeIdentity,
                                   latestCharge: ChargeSummary?,
                                   previous: ChargingActivityAttributes.ContentState) -> ChargingActivityAttributes.ContentState {
        let closed = latestCharge.flatMap { $0.end != nil ? $0 : nil }
        let bySession = closed.flatMap { $0.id == identity.session ? $0 : nil }
        // The tracked session's own final counter outranks a TeslaMate record.
        let counter = identity.session != nil && identity.session == liveSession(status) ? status.chargeEnergyAddedKwh : nil
        let byTeslaMate = closed.flatMap { $0.id == identity.teslaMate || $0.id == attributes.chargeId ? $0 : nil }
        let summary = bySession ?? byTeslaMate
        return .init(batteryLevel: summary?.endBatteryLevel ?? status.batteryLevel,
                     chargeLimit: status.chargeLimit ?? previous.chargeLimit,
                     chargerPowerKw: nil,
                     fullAt: nil,
                     energyAddedKwh: bySession?.energyAddedKwh ?? counter ?? byTeslaMate?.energyAddedKwh ?? previous.energyAddedKwh,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm ?? previous.rangeKm,
                     phase: observation == .completed ? .completed : .stopped,
                     updatedAt: status.updatedAt,
                     endedAt: summary?.end ?? status.updatedAt,
                     statusSessionId: identity.session,
                     sessionStartedAt: identity.sessionStart,
                     teslaMateChargeId: identity.teslaMate,
                     teslaMateStartedAt: identity.teslaMateStart,
                     otherChargeIds: previous.otherChargeIds)
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
