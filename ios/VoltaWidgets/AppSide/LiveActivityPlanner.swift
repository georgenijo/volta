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
    ///   - charges: the recent history page it came from, which may show where a charge ended.
    ///   - canStart: Live Activities are enabled for the app.
    ///
    /// A charge has two names: its Fleet Telemetry session (negative id) and TeslaMate's process
    /// (positive id, also its charge id), which opens minutes later. An activity remembers each
    /// id the status names for it and is replaced only when the status names a different charge.
    /// History is matched by start time only when an activity starts; afterwards only exact ids
    /// count, so a record that merely starts near this charge never lends it totals.
    static func planCharging(existing: [ChargingRunning], status: VehicleStatus, vehicleName: String,
                             latestCharge: ChargeSummary?, charges: [ChargeSummary]? = nil, usesMiles: Bool,
                             canStart: Bool, now: Date) -> ChargingPlan {
        let observation = chargingObservation(status)
        let page = charges ?? latestCharge.map { [$0] } ?? []
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
                    switch follow(activity, status: status, latestCharge: latestCharge, charges: charges, now: now) {
                    case .enrich(let identity) where canRestart:
                        enriched = (identity, activity.state)
                        action = .dismiss
                    case .same(let identity), .enrich(let identity):
                        // Only an exact record, and only while no live counter is tracked.
                        let recorded = identity.session == nil
                            ? latestCharge.flatMap { $0.end == nil && $0.id == identity.teslaMate ? $0.energyAddedKwh : nil }
                            : nil
                        let previous = knowingDC(activity.state, attributes: activity.attributes,
                                                 identity: identity, records: page)
                        action = .update(chargingState(status: status, identity: identity, recordedEnergy: recorded,
                                                       previous: previous))
                    case .unrelated(let identity):
                        // Keep the readings and their time; only remember what was learned.
                        let kept = remembering(identity, in: knowingDC(activity.state, attributes: activity.attributes,
                                                                       identity: identity, records: page))
                        action = kept == activity.state ? .keep : .update(kept)
                    case .other(let identity):
                        replaced.formUnion([identity.session, identity.teslaMate, activity.attributes.chargeId].compactMap { $0 })
                        replaced.formUnion(identity.others)
                        action = .dismiss
                    }
                case .completed, .stopped:
                    // Follow the charge to its end, which may come in a session it resumed in. Another
                    // charge's session is never followed, and one shown not to continue it is dropped.
                    let followed: ChargeIdentity
                    switch follow(activity, status: status, latestCharge: latestCharge, charges: charges, now: now) {
                    case .same(let identity), .enrich(let identity), .unrelated(let identity), .other(let identity):
                        followed = identity
                    }
                    action = .finish(finalChargingState(status: status, observation: observation,
                                                        attributes: activity.attributes, identity: followed,
                                                        records: page, previous: activity.state))
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
                if let session = liveSession(status) {
                    identity.session = session; identity.sessionStart = status.chargeStartedAt
                    identity.sessionStartObserved = status.chargeStartObserved != false
                    rejectEarlierProcesses(&identity, status: status, records: page, now: now)
                }
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
                // A session that resumed mid-charge recorded only its part; the charge may have started earlier.
                startedAt: enriched != nil && identity.partial && history?.id == identity.session
                    ? [history?.start, identity.sessionStart, identity.teslaMateStart].compactMap { $0 }.min()
                    : history?.start,
                startBatteryLevel: history?.startBatteryLevel,
                fastCharger: history?.fastCharger,
                usesMiles: usesMiles)
            var state = chargingState(status: status, identity: identity, recordedEnergy: recorded, previous: nil)
            if state.counterKwh == nil {
                state.counterKwh = enriched?.previous.counterKwh; state.counterAt = enriched?.previous.counterAt
            }
            // History records DC once any was drawn; its false may only mean none was seen yet.
            state.fastCharger = state.fastCharger ?? enriched?.previous.fastCharger
                ?? (history?.fastCharger == true ? true : nil)
            plan.start = .init(attributes: attributes, state: state)
        }
        return plan
    }

    /// The ids an activity's charge is known by, each with its start.
    struct ChargeIdentity: Hashable {
        var session: Int?
        var sessionStart: Date?
        var teslaMate: Int?
        var teslaMateStart: Date?
        /// The process was learned while the session was tracked, so the session is the charge's own.
        var processLearned = false
        /// False when the session began mid-charge, so the charge started before `sessionStart`.
        var sessionStartObserved = true
        /// The charge continued into `session` after a gap, so that session's record covers only its part.
        var sessionResumed = false
        /// When `session` began, if the charge resumed into it.
        var resumedAt: Date?
        /// The sessions this charge ran in before `session`, which it resumed from after gaps.
        var earlierSessions: Set<Int> = []
        /// Whether the tracked session's record covers only part of the charge.
        var partial: Bool { !sessionStartObserved || sessionResumed }
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
        /// an older one TeslaMate never closed): leave the activity's readings as they are.
        case unrelated(ChargeIdentity)
    }

    static func identity(of activity: ChargingRunning, latestCharge: ChargeSummary?) -> ChargeIdentity {
        let state = activity.state
        var identity = ChargeIdentity(session: state.statusSessionId, sessionStart: state.sessionStartedAt,
                                      teslaMate: state.teslaMateChargeId, teslaMateStart: state.teslaMateStartedAt,
                                      processLearned: state.teslaMateLearned ?? false,
                                      sessionStartObserved: state.sessionStartObserved ?? true,
                                      sessionResumed: state.sessionResumed ?? false,
                                      resumedAt: state.sessionResumedAt,
                                      earlierSessions: Set(state.earlierSessionIds ?? []),
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
    static func follow(_ activity: ChargingRunning, status: VehicleStatus, latestCharge: ChargeSummary?,
                       charges: [ChargeSummary]? = nil, now: Date? = nil) -> ChargeFollow {
        let now = now ?? status.updatedAt
        var identity = identity(of: activity, latestCharge: latestCharge)
        let records = charges ?? latestCharge.map { [$0] } ?? []
        let named = status.chargeStartedAt
        // A process that drew DC where this charge was seen on AC isn't this charge's; when the AC
        // session was the one taken on part-way, it is the session that isn't.
        if let known = identity.teslaMate, activity.state.fastCharger == false,
           records.contains(where: { $0.id == known && $0.fastCharger }) {
            if identity.session != nil, adoptedAt(identity) != nil, !identity.processLearned {
                identity.session = nil
                return .other(identity)
            }
            forget(known, in: &identity)
        }
        // A process learned while history was away answers to history that arrives later.
        let tracked = identity.session != nil && identity.session == liveSession(status)
        if let known = identity.teslaMate,
           !fits(learned: identity, records: records, counter: tracked ? status.chargeEnergyAddedKwh : nil,
                 at: counterAt(status), onAC: (chargerKind(status) ?? activity.state.fastCharger) == false, now: now) {
            forget(known, in: &identity)
        }
        let shown = knowingDC(activity.state, attributes: activity.attributes, identity: identity, records: records)
        // A session taken on as this charge part-way answers to history that arrives later, even
        // once telemetry no longer describes it.
        if liveSession(status) == nil, identity.session != nil, let adopted = adoptedAt(identity),
           !continues(identity, from: adopted, status: status, records: records, showing: shown) {
            identity.session = nil
            return .other(identity)
        }
        if liveSession(status) == nil, let process = namedProcess(status) {
            if identity.others.contains(process) {
                return .unrelated(identity)
            } else if let known = identity.teslaMate {
                // Two TeslaMate ids compare without a start; a process older than this charge is
                // one TeslaMate never closed.
                if known != process { return startsBefore(named, identity) ? .unrelated(identity) : .other(identity) }
                if identity.teslaMateStart == nil { identity.teslaMateStart = named }
            } else if identity.session == nil, !identity.others.contains(process) {
                // Nothing to check it against: the named process is this charge.
                identity.teslaMate = process; identity.teslaMateStart = named
            }
        }
        if let session = liveSession(status), let named {
            // A session that began mid-charge may be this charge resumed after a gap, or joined late.
            let resumed = status.chargeStartObserved == false
            if let known = identity.session {
                if known != session {
                    guard resumed, !identity.others.contains(session),
                          continues(identity, from: named, status: status, records: records,
                                    showing: shown)
                    else { return .other(identity) }
                    // Without the new session's counter a restart can't be ruled out yet.
                    if awaitsCounter(status, identity: identity, shown: activity.state.energyAddedKwh,
                                     records: records) { return .unrelated(identity) }
                    // The charge's start, and whether it was seen, stay those already known.
                    identity.earlierSessions.insert(known)
                    identity.session = session; identity.sessionResumed = true; identity.resumedAt = named
                } else {
                    // A session taken on as this charge part-way answers to history that arrives later.
                    if adoptedAt(identity) != nil,
                       !continues(identity, from: named, status: status, records: records,
                                  showing: shown) {
                        identity.session = nil  // the session belongs to the charge replacing this one
                        return .other(identity)
                    }
                    if resumed, let start = identity.sessionStart, abs(named.timeIntervalSince(start)) < 1 {
                        identity.sessionStartObserved = false  // the status now says so about this session
                    }
                }
            } else if identity.others.contains(session) {
                return .other(identity)
            } else if identity.teslaMate != nil {
                // TeslaMate's record must start with the session, or the session joined it late.
                if let start = identity.teslaMateStart, sameCharge(teslaMateStart: start, sessionStart: named) {
                    identity.sessionStartObserved = !resumed
                } else if resumed, continues(identity, from: named, status: status, records: records,
                                             showing: shown) {
                    if awaitsCounter(status, identity: identity, shown: activity.state.energyAddedKwh,
                                     records: records) { return .unrelated(identity) }
                    identity.sessionStartObserved = false
                } else {
                    return .other(identity)
                }
                identity.session = session; identity.sessionStart = named
                identity.sessionResumed = false; identity.resumedAt = nil
            } else {
                identity.session = session; identity.sessionStart = named; identity.sessionStartObserved = !resumed
            }
            rejectEarlierProcesses(&identity, status: status, records: records, now: now)
        } else if let process = teslaMateProcess(status), let named, identity.teslaMate == nil,
                  !identity.others.contains(process) {
            if identity.session != nil {
                // TeslaMate names a process while telemetry is quiet. Starting with the session it is
                // this charge; starting well after, a later one; starting before, an older process
                // TeslaMate never closed, which says nothing about this charge.
                guard let start = identity.sessionStart else { return .same(identity) }
                let lag = named.timeIntervalSince(start)
                // A session that began mid-charge may have joined a process already under way.
                if teslaMateStartLag.contains(lag) || lag < 0 && !identity.sessionStartObserved {
                    // Not a process that drew DC when this charge was seen on AC, or one this charge's
                    // counter can't account for.
                    var learned = identity
                    learned.teslaMate = process; learned.teslaMateStart = named; learned.processLearned = true
                    if activity.state.fastCharger == false && records.contains(where: { $0.id == process && $0.fastCharger })
                        || !fits(learned: learned, records: records, counter: activity.state.counterKwh,
                                 at: activity.state.counterAt, onAC: activity.state.fastCharger == false, now: now) {
                        identity.others.insert(process)
                        return .unrelated(identity)
                    }
                    identity = learned
                } else if lag > teslaMateStartLag.upperBound {
                    return .other(identity)
                } else {
                    return .unrelated(identity)
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
                     counterKwh: live ?? previous?.counterKwh,
                     counterAt: live != nil ? counterAt(status) : previous?.counterAt,
                     fastCharger: (identity.session != nil && identity.session == liveSession(status) ? chargerKind(status) : nil)
                        ?? previous?.fastCharger,
                     rangeKm: status.estRangeKm ?? status.ratedRangeKm,
                     phase: .charging,
                     updatedAt: status.updatedAt,
                     endedAt: nil,
                     statusSessionId: identity.session,
                     sessionStartedAt: identity.sessionStart,
                     teslaMateChargeId: identity.teslaMate,
                     teslaMateStartedAt: identity.teslaMateStart,
                     teslaMateLearned: identity.processLearned && identity.teslaMate != nil ? true : nil,
                     sessionStartObserved: identity.sessionStartObserved ? nil : false,
                     sessionResumed: identity.sessionResumed ? true : nil,
                     sessionResumedAt: identity.resumedAt,
                     earlierSessionIds: identity.earlierSessions.isEmpty ? nil : identity.earlierSessions.sorted(),
                     otherChargeIds: identity.others.isEmpty ? nil : identity.others.sorted())
    }

    /// How long TeslaMate's start of a charge may trail Fleet Telemetry's start of the same
    /// charge. Telemetry sees a start first (TeslaMate's poll trailed it by 7 and 27 minutes in
    /// practice); the small lead allows for clock differences.
    static let teslaMateStartLag: ClosedRange<TimeInterval> = -60 ... 60 * 60

    /// How far the car's charge counter may read below the total shown (a lagging TeslaMate total,
    /// rounding) before it counts as restarted for a new charge.
    static let counterSlack = 0.5

    static func remembering(_ identity: ChargeIdentity, in state: ChargingActivityAttributes.ContentState)
        -> ChargingActivityAttributes.ContentState {
        var state = state
        state.statusSessionId = identity.session
        state.sessionStartedAt = identity.sessionStart
        state.teslaMateChargeId = identity.teslaMate
        state.teslaMateStartedAt = identity.teslaMateStart
        state.teslaMateLearned = identity.processLearned && identity.teslaMate != nil ? true : nil
        state.sessionStartObserved = identity.sessionStartObserved ? nil : false
        state.sessionResumed = identity.sessionResumed ? true : nil
        state.sessionResumedAt = identity.resumedAt
        state.earlierSessionIds = identity.earlierSessions.isEmpty ? nil : identity.earlierSessions.sorted()
        state.otherChargeIds = identity.others.isEmpty ? nil : identity.others.sorted()
        return state
    }

    /// The activity's state with the DC its charge is known to have drawn, which its attributes or
    /// own records may show before the state saved it.
    static func knowingDC(_ state: ChargingActivityAttributes.ContentState, attributes: ChargingActivityAttributes,
                          identity: ChargeIdentity, records: [ChargeSummary]) -> ChargingActivityAttributes.ContentState {
        guard state.fastCharger == nil, attributes.fastCharger == true || records.contains(where: {
            $0.fastCharger && ($0.id == identity.teslaMate || $0.id == identity.session
                || identity.earlierSessions.contains($0.id))
        }) else { return state }
        var state = state
        state.fastCharger = true
        return state
    }

    /// Whether a session that began mid-charge at `start` continues this activity's charge: it
    /// began after the charge did on the same kind of charger, the car's counter hasn't restarted
    /// below what the activity read or shows, and no history record says the charge ended or
    /// another began.
    static func continues(_ identity: ChargeIdentity, from start: Date, status: VehicleStatus,
                          records: [ChargeSummary], showing state: ChargingActivityAttributes.ContentState) -> Bool {
        let own = [identity.sessionStart, identity.teslaMateStart].compactMap { $0 }.min()
        if let own, start.timeIntervalSince(own) < teslaMateStartLag.lowerBound { return false }
        if let was = state.fastCharger, let now = chargerKind(status), was != now { return false }
        // The counter the activity last read came before this reading; a recorded total it shows
        // may have been fetched after.
        guard reaches(status.chargeEnergyAddedKwh, state.counterKwh),
              counts(status.chargeEnergyAddedKwh, toward: state.energyAddedKwh) else { return false }
        // Without telemetry, the counter last read in the session from `start` stands for it.
        let read = status.chargeEnergyAddedKwh ?? (liveSession(status) == nil ? state.counterKwh : nil)
        // Where the session from `start` ends, if its record shows (only the last point of a session
        // a gap split): a process beginning after that, and too late to be that session's own, is a
        // later charge.
        let ended = records.first { $0.id == identity.session }?.end.flatMap { $0 > start ? $0 : nil }
        return records.allSatisfy { record in
            guard !identity.others.contains(record.id) else { return true }
            // This charge's record can't total much more than the car's counter for it.
            let counted = counts(status.chargeEnergyAddedKwh, toward: record.energyAddedKwh)
            // The car's counter runs on through a gap, so it covers every session of this charge; one
            // that ended before this session began was recorded before the counter was read.
            if record.id == identity.session || identity.earlierSessions.contains(record.id) {
                // An earlier session that drew DC isn't continued by one on AC.
                if identity.earlierSessions.contains(record.id), record.fastCharger,
                   (chargerKind(status) ?? state.fastCharger) == false { return false }
                return record.end.map { $0 <= start } ?? false
                    ? reaches(read, record.energyAddedKwh) : counted
            }
            guard record.id > 0 else { return true }
            // This charge's process ending before the session began means the charge ended; ending
            // since, it closed with the charge the session resumed.
            if isThisCharge(record, identity) { return counted && !(record.end.map { $0 <= start } ?? false) }
            // Another process: one started before this charge's own is older; a later one, open or
            // closed, means history has moved on, unless it began after the session ended.
            if let ended, record.start >= ended, !sameCharge(teslaMateStart: record.start, sessionStart: start) { return true }
            if identity.teslaMate != nil, let known = identity.teslaMateStart { return record.start <= known }
            guard let own else { return true }
            return record.start.timeIntervalSince(own) < teslaMateStartLag.lowerBound
        }
    }

    /// When the tracked session began, if the activity took it on part-way: a session the charge
    /// resumed into, or one that joined the activity's TeslaMate process late.
    static func adoptedAt(_ identity: ChargeIdentity) -> Date? {
        if identity.sessionResumed { return identity.resumedAt }
        return !identity.sessionStartObserved && identity.teslaMate != nil && !identity.processLearned
            ? identity.sessionStart : nil
    }

    /// Remembers a process as another charge's.
    static func forget(_ process: Int, in identity: inout ChargeIdentity) {
        identity.others.insert(process)
        identity.teslaMate = nil; identity.teslaMateStart = nil; identity.processLearned = false
    }

    /// The fastest the car adds energy on DC and on AC: a process can't have outrun the car's
    /// counter by more.
    static let maxChargeRateKw = 300.0
    static let maxACChargeRateKw = 20.0

    /// When telemetry sampled the status's charge counter, if it said: the server reads the DC
    /// counter for a session that drew DC and the AC one otherwise.
    static func counterAt(_ status: VehicleStatus) -> Date? {
        guard status.chargeEnergyAddedKwh != nil else { return nil }
        return status.telemetryFreshness?.recordedAt[status.fastCharger == true ? "DCChargingEnergyIn" : "ACChargingEnergyIn"]
    }

    /// Whether a recorded total is more than the car's counter, sampled at `at`, could have reached
    /// by `now`: well below it, and beyond what charging could have added since. Without the
    /// sample's time a retained counter can't be told from a current one, so it can't tell.
    static func outruns(_ total: Double?, counter: Double?, at: Date?, onAC: Bool, now: Date) -> Bool {
        guard let total, let counter, let at, !counts(counter, toward: total) else { return false }
        let hours = (max(0, now.timeIntervalSince(at)) + 60) / 3600  // a minute for clocks and the fetch
        return total > counter + (onAC ? maxACChargeRateKw : maxChargeRateKw) * hours + counterSlack
    }

    /// Whether history leaves a process learned for the activity's session this charge's: it didn't
    /// end before the session began, and its total doesn't outrun the session's counter.
    static func fits(learned identity: ChargeIdentity, records: [ChargeSummary], counter: Double?, at: Date?,
                     onAC: Bool, now: Date) -> Bool {
        guard identity.processLearned, let process = identity.teslaMate,
              let record = records.first(where: { $0.id == process }) else { return true }
        if let end = record.end, let start = identity.sessionStart, end <= start { return false }
        return !outruns(record.energyAddedKwh, counter: counter, at: at, onAC: onAC, now: now)
    }

    /// Whether a history record is this activity's charge: one of its ids, or, while its TeslaMate
    /// process is unknown, a process starting with the charge.
    static func isThisCharge(_ record: ChargeSummary, _ identity: ChargeIdentity) -> Bool {
        if record.id == identity.session || record.id == identity.teslaMate
            || identity.earlierSessions.contains(record.id) { return true }
        guard record.id > 0, identity.teslaMate == nil, !identity.others.contains(record.id),
              let own = [identity.sessionStart, identity.teslaMateStart].compactMap({ $0 }).min() else { return false }
        return sameCharge(teslaMateStart: record.start, sessionStart: own)
    }

    /// Remembers each open TeslaMate process on the history page that started before a session
    /// which began mid-charge as another charge when its total outruns the session's counter or it
    /// drew DC while the session charges on AC, so a later fallback to that process
    /// doesn't adopt it.
    static func rejectEarlierProcesses(_ identity: inout ChargeIdentity, status: VehicleStatus,
                                       records: [ChargeSummary], now: Date) {
        guard !identity.sessionStartObserved, identity.teslaMate == nil, let start = identity.sessionStart else { return }
        let onAC = chargerKind(status) == false
        for open in records where open.end == nil && open.id > 0 && open.start < start && !identity.others.contains(open.id)
            && (outruns(open.energyAddedKwh, counter: status.chargeEnergyAddedKwh, at: counterAt(status), onAC: onAC, now: now)
                || onAC && open.fastCharger) {
            identity.others.insert(open.id)
        }
    }

    /// Whether the car's counter fits a record of the same charge, fetched just after the status:
    /// such a record may run slightly ahead, while a new charge restarts the counter well below
    /// the old total. True when either is unknown.
    static func counts(_ counter: Double?, toward total: Double?) -> Bool {
        guard let counter, let total else { return true }
        return counter >= total / 2 || reaches(counter, total)
    }

    /// Whether the live session charges on DC (true) or AC (false), when the status shows it: DC
    /// once it has drawn DC power, AC while AC power flows without that.
    static func chargerKind(_ status: VehicleStatus) -> Bool? {
        guard liveSession(status) != nil, let fast = status.fastCharger else { return nil }
        return fast || (status.chargerPowerKw ?? 0) > 0 ? fast : nil
    }

    /// Whether the car's counter reaches a total recorded before it was read. True when either is unknown.
    static func reaches(_ counter: Double?, _ total: Double?) -> Bool {
        guard let counter, let total else { return true }
        return counter >= total - counterSlack
    }

    /// Whether a session that began mid-charge must wait for its counter before it can continue a
    /// charge with a known total, shown or recorded: only the counter tells a resumed charge from
    /// a new one.
    static func awaitsCounter(_ status: VehicleStatus, identity: ChargeIdentity, shown: Double?,
                              records: [ChargeSummary]) -> Bool {
        let recorded = records.filter { isThisCharge($0, identity) }.compactMap(\.energyAddedKwh).max()
        return status.chargeEnergyAddedKwh == nil && (shown ?? recorded) != nil
    }

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
            // A session that began mid-charge joins TeslaMate's process already under way.
            // A process that drew DC isn't the charge while AC power flows.
            return charge.id == session || charge.id > 0 && !(charge.fastCharger && chargerKind(status) == false)
                && (sameCharge(teslaMateStart: charge.start, sessionStart: start)
                    || status.chargeStartObserved == false && charge.start < start && countsAtLeast(status, charge))
        }
        if let process = namedProcess(status) { return charge.id == process }
        return true
    }

    /// Whether the status's counter fits the record as this charge's; false without a counter.
    static func countsAtLeast(_ status: VehicleStatus, _ charge: ChargeSummary) -> Bool {
        status.chargeEnergyAddedKwh != nil && counts(status.chargeEnergyAddedKwh, toward: charge.energyAddedKwh)
    }

    /// Final content: no power or countdown, the end time, and the last known totals.
    static func finalChargingState(status: VehicleStatus, observation: ChargingObservation,
                                   attributes: ChargingActivityAttributes, identity: ChargeIdentity,
                                   records: [ChargeSummary],
                                   previous: ChargingActivityAttributes.ContentState) -> ChargingActivityAttributes.ContentState {
        let closed = records.filter { $0.end != nil }
        let ownSession = closed.first { $0.id == identity.session }
        // A session that began mid-charge measured only its part of the charge: its end counts,
        // its energy doesn't.
        let partial = identity.partial
        let bySession = partial ? nil : ownSession
        // The tracked session's own final counter outranks a TeslaMate record.
        let counter = identity.session != nil && identity.session == liveSession(status) ? status.chargeEnergyAddedKwh : nil
        // Only a TeslaMate process: a session the activity started with may since have proved to be
        // an earlier part of the charge, or another charge.
        let byTeslaMate = closed.first {
            $0.id > 0 && ($0.id == identity.teslaMate || $0.id == attributes.chargeId) && !identity.others.contains($0.id)
        }
        // A session just shown not to continue the charge left readings of another charge; only the
        // charge's own records count. Its first session measured all of it up to a single gap.
        let disowned = previous.statusSessionId != nil && identity.session == nil
        let earlier = disowned ? closed.filter { identity.earlierSessions.contains($0.id) } : []
        let firstPart = identity.sessionStartObserved && identity.earlierSessions.count == 1 ? earlier.first : nil
        let summary = bySession ?? byTeslaMate ?? ownSession ?? firstPart
        // So did its phase, range and charge limit, which can't tell whether this charge reached its limit.
        return .init(batteryLevel: summary?.endBatteryLevel ?? status.batteryLevel,
                     chargeLimit: disowned ? nil : status.chargeLimit ?? previous.chargeLimit,
                     chargerPowerKw: nil,
                     fullAt: nil,
                     energyAddedKwh: bySession?.energyAddedKwh ?? counter ?? byTeslaMate?.energyAddedKwh
                        ?? (disowned ? firstPart?.energyAddedKwh : previous.energyAddedKwh),
                     counterKwh: counter ?? (disowned ? nil : previous.counterKwh),
                     fastCharger: previous.fastCharger,
                     rangeKm: disowned ? nil : status.estRangeKm ?? status.ratedRangeKm ?? previous.rangeKm,
                     phase: !disowned && observation == .completed ? .completed : .stopped,
                     updatedAt: status.updatedAt,
                     endedAt: summary?.end ?? earlier.compactMap(\.end).max() ?? status.updatedAt,
                     statusSessionId: identity.session,
                     sessionStartedAt: identity.sessionStart,
                     teslaMateChargeId: identity.teslaMate,
                     teslaMateStartedAt: identity.teslaMateStart,
                     teslaMateLearned: identity.processLearned && identity.teslaMate != nil ? true : nil,
                     sessionStartObserved: identity.sessionStartObserved ? nil : false,
                     sessionResumed: identity.sessionResumed ? true : nil,
                     sessionResumedAt: identity.resumedAt,
                     earlierSessionIds: identity.earlierSessions.isEmpty ? nil : identity.earlierSessions.sorted(),
                     otherChargeIds: identity.others.isEmpty ? nil : identity.others.sorted())
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
