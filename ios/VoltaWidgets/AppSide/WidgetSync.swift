import ActivityKit
import SwiftUI
import WidgetKit

// APP TARGET ONLY. Keeps the App Group widget snapshot and the Live
// Activities in step with the app's data.
//
// - `AppModel` sets the context whenever pairing, demo mode or the selected
//   vehicle changes. Only `.vehicle` (a real, paired vehicle) ever writes.
// - Screens call `publish` after each successful status refresh (Dashboard
//   load/pull-to-refresh/foreground, Controls refresh).
//
// Demo mode: demo data never reaches the App Group or Live Activities.
// Entering demo (or unpairing) clears the snapshot and ends every activity,
// so widgets show "Open Volta" instead of synthetic or stale private data. A
// `-demo-mode YES` launch override also clears surfaces (`.inactive`), while
// leaving saved pairing credentials and preferences unchanged.
//
// Ordering: every ActivityKit change goes through one FIFO "mutation lane".
// Syncs fetch session history outside the lane, then enqueue their changes
// and re-check that they are still current inside it. Cleanup (unpair, demo,
// vehicle switch, driving toggled off) enqueues straight into the lane, so it
// never waits for network work, and later syncs never interleave with it. A
// context change also cancels queued and in-flight syncs. Cleanup ends the
// activities that existed when it was requested (by id), never ones a later
// sync starts.

/// Which data the widget surfaces may show.
enum VehicleSurfaceContext: Hashable, Sendable {
    /// Unpaired or demo mode: no snapshot, no activities.
    case inactive
    /// Locked Keychain: write nothing, clear nothing.
    case suspended
    /// Paired, but the vehicle list has not loaded yet.
    case pending
    case vehicle(id: Int, name: String)
}

/// One successful status refresh. `today` / `timeline` are nil when this
/// refresh did not load them; the snapshot keeps the previous values then.
///
/// Refreshes from different screens can finish out of order; `WidgetSync`
/// orders them by `issued`, the token taken just before the `/status` request.
struct VehicleRefresh: Sendable {
    var status: VehicleStatus
    var issued: StatusRequestToken
    var vehicleName: String? = nil
    var today: TodaySummary? = nil
    var timeline: [TimelineSegment]? = nil
}

/// Issue order of a `/status` request: take one from
/// `VehicleSurfaces.nextStatusToken()` immediately BEFORE issuing the request.
/// Telemetry time is not an ordering key: the backend's `updatedAt` can go
/// down when a session closes and can stay equal across different states.
struct StatusRequestToken: Comparable, Hashable, Sendable {
    let value: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// `/summary?range=today` with the instant its request started, so the totals
/// can be attributed to the reporting day the backend computed them for.
struct TodaySummary: Sendable {
    var summary: ActivitySummary
    var requestedAt: Date
    /// Device zone when the request started (the `tz` it sent).
    var requestedZone: String = TimeZone.current.identifier

    /// The reporting day these totals cover (see `ReportingDay`). Shared by the
    /// dashboard and the widget snapshot so both roll over together.
    var day: ReportingDay.Day {
        ReportingDay.day(periodStart: summary.periodStart, timeZone: summary.timeZone,
                         requestedAt: requestedAt, requestedZone: requestedZone)
    }
}

@MainActor
protocol VehicleSurfaces: AnyObject {
    func setContext(_ context: VehicleSurfaceContext)
    /// A unique, increasing token for a `/status` request about to be issued.
    func nextStatusToken() -> StatusRequestToken
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource)
    /// The "Live Activity while driving" setting changed (read it from settings).
    func drivingActivityPreferenceChanged()
}

extension EnvironmentValues {
    /// Where screens report fresh vehicle data. nil in previews and tests.
    @Entry var vehicleSurfaces: (any VehicleSurfaces)? = nil
}

/// Live Activity content that records when its vehicle data was captured.
protocol TimestampedContent { var updatedAt: Date { get } }
extension ChargingActivityAttributes.ContentState: TimestampedContent {}
extension DrivingActivityAttributes.ContentState: TimestampedContent {}

// MARK: - Seams (ActivityKit and the App Group file; faked in tests)

@MainActor
protocol LiveActivityDriver: AnyObject {
    var canStart: Bool { get }
    func chargingActivities() -> [LiveActivityPlanner.ChargingRunning]
    func drivingActivities() -> [LiveActivityPlanner.DrivingRunning]
    func apply(_ action: ExistingActivityAction<ChargingActivityAttributes.ContentState>, toCharging id: String) async
    func apply(_ action: ExistingActivityAction<DrivingActivityAttributes.ContentState>, toDriving id: String) async
    /// Removes lingering final cards of this type before a new session starts.
    func dismissEndedCharging() async
    func dismissEndedDriving() async
    func request(_ attributes: ChargingActivityAttributes, _ state: ChargingActivityAttributes.ContentState)
    func request(_ attributes: DrivingActivityAttributes, _ state: DrivingActivityAttributes.ContentState)
    /// Every Volta activity on screen, including ended ones still lingering,
    /// optionally excluding one vehicle's.
    func presentActivities(exceptVehicle: Int?) -> LiveActivityIDs
    /// Ends exactly these activities immediately (whatever their state).
    func end(_ ids: LiveActivityIDs) async
}

struct LiveActivityIDs: Hashable, Sendable {
    var charging: [String] = []
    var driving: [String] = []
    var isEmpty: Bool { charging.isEmpty && driving.isEmpty }
}

@MainActor
protocol WidgetSnapshotStoring: AnyObject {
    func read() -> WidgetSnapshot?
    func write(_ snapshot: WidgetSnapshot) throws
    /// Deletes the snapshot and reloads widgets so they show the empty state.
    func reset()
}

@MainActor
final class AppGroupSnapshotStore: WidgetSnapshotStoring {
    func read() -> WidgetSnapshot? { WidgetSnapshotStore.read() }
    func write(_ snapshot: WidgetSnapshot) throws {
        try WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
    func reset() { WidgetSnapshotStore.reset() }
}

// MARK: - Synchronizer

@MainActor
final class WidgetSync: VehicleSurfaces {
    private let settings: UserSettings
    private let activities: any LiveActivityDriver
    private let store: any WidgetSnapshotStoring
    private(set) var context: VehicleSurfaceContext?
    /// Bumped on every context change that invalidates queued work. A sync
    /// only touches ActivityKit while its epoch is still current.
    private var epoch = 0
    /// Serializes syncs so two refreshes never both start an activity.
    private var tail: Task<Void, Never>?
    /// Cancelled syncs still winding down (only awaited by `drain`).
    private var retired: Task<Void, Never>?
    /// Last token handed out. Never reset, so tokens stay unique for the app's life.
    private var lastIssued: UInt64 = 0
    /// Only tokens above this may publish. Raised to each accepted token (a slow,
    /// earlier-issued refresh finishing late is dropped, and newer-issued ones
    /// always win, so the surfaces cannot freeze) and fenced to `lastIssued` on
    /// unpair, demo and a vehicle switch, so requests issued before the change
    /// can never publish after it.
    private var acceptAfter: UInt64 = 0
    /// The last vehicle the context showed; nil after unpair/demo. Entering a
    /// vehicle from `.pending` at launch is not a switch: Dashboard may already
    /// have issued its first request then, and that refresh must count.
    private var lastVehicle: Int?
    /// The mutation lane: every ActivityKit change, in order. Never contains
    /// network work, so cleanup enqueued here runs as soon as the change in
    /// progress (if any) returns.
    private var lane: Task<Void, Never>?

    init(settings: UserSettings, activities: (any LiveActivityDriver)? = nil,
         store: (any WidgetSnapshotStoring)? = nil) {
        self.settings = settings
        self.activities = activities ?? SystemLiveActivityDriver()
        self.store = store ?? AppGroupSnapshotStore()
    }

    func setContext(_ new: VehicleSurfaceContext) {
        let old = context
        guard old != new else { return }
        context = new
        switch new {
        case .inactive:
            invalidateQueuedWork()
            acceptAfter = lastIssued
            lastVehicle = nil
            store.reset()
            endNow(activities.presentActivities(exceptVehicle: nil))
        case .suspended, .pending:
            // Queued syncs see the context is no longer a vehicle and stop.
            break
        case .vehicle(let id, _):
            if case .vehicle(let oldID, _) = old, oldID == id { return }  // renamed only
            invalidateQueuedWork()
            if let lastVehicle, lastVehicle != id { acceptAfter = lastIssued }
            lastVehicle = id
            // Anything still showing another vehicle goes away immediately.
            if let stored = store.read(), stored.vehicleId != id { store.reset() }
            endNow(activities.presentActivities(exceptVehicle: id))
        }
    }

    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) {
        guard case .vehicle(let id, let contextName) = context, refresh.status.vehicleId == id else { return }
        // A refresh issued earlier but finished later, or issued before a context
        // change, must not publish. Tokens are unique, so strictly greater.
        guard refresh.issued.value > acceptAfter else { return }
        acceptAfter = refresh.issued.value
        let name = refresh.vehicleName ?? contextName
        let units = settings.units
        let snapshot = WidgetSnapshot(status: refresh.status, vehicleName: name, summary: refresh.today?.summary,
                                      summaryRequestedAt: refresh.today?.requestedAt,
                                      summaryRequestedZone: refresh.today?.requestedZone,
                                      timeline: refresh.timeline, units: units, previous: store.read())
        // On failure widgets keep the previous snapshot; nothing user-facing to do.
        try? store.write(snapshot)
        let status = refresh.status
        let epoch = epoch
        enqueue { [weak self] in
            await self?.syncActivities(epoch: epoch, status: status, vehicleName: name, units: units,
                                       dataSource: dataSource)
        }
    }

    func nextStatusToken() -> StatusRequestToken {
        lastIssued += 1
        return StatusRequestToken(value: lastIssued)
    }

    func drivingActivityPreferenceChanged() {
        // Queued syncs re-read the preference inside the lane before planning and starting.
        guard !settings.drivingLiveActivity else { return }
        endNow(LiveActivityIDs(driving: activities.presentActivities(exceptVehicle: nil).driving))
    }

    /// Waits for all queued, cancelled and lane work (tests, debugging).
    func drain() async {
        await tail?.value
        await retired?.value
        await lane?.value
    }

    /// Waits for ActivityKit changes queued so far; syncs may still be
    /// blocked on the network (their changes are not queued yet).
    func drainCleanup() async { await lane?.value }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Appends ActivityKit work to the mutation lane.
    @discardableResult
    private func mutate(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lane
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        lane = task
        return task
    }

    /// Ends the given activities (captured now, by id) ahead of any later sync.
    private func endNow(_ ids: LiveActivityIDs) {
        guard !ids.isEmpty else { return }
        let activities = activities
        mutate { await activities.end(ids) }
    }

    private func invalidateQueuedWork() {
        epoch += 1
        guard let old = tail else { return }
        old.cancel()
        tail = nil
        let previous = retired
        retired = Task { @MainActor in
            await previous?.value
            await old.value
        }
    }

    /// Lane tasks are never cancelled; the epoch covers them.
    private func isLive(_ syncEpoch: Int, vehicle vehicleID: Int) -> Bool {
        guard syncEpoch == epoch, !Task.isCancelled, case .vehicle(let id, _) = context else { return false }
        return id == vehicleID
    }

    // MARK: Live Activities

    private func syncActivities(epoch syncEpoch: Int, status: VehicleStatus, vehicleName: String,
                                units: UnitPreferences, dataSource: any VoltaDataSource) async {
        let vehicleID = status.vehicleId
        guard isLive(syncEpoch, vehicle: vehicleID) else { return }
        let chargingObservation = LiveActivityPlanner.chargingObservation(status)
        let drivingObservation = LiveActivityPlanner.drivingObservation(status)
        let hadCharging = !activities.chargingActivities().isEmpty
        let hadDriving = !activities.drivingActivities().isEmpty
        let wantsDriving = settings.drivingLiveActivity
        let since = DateRange(from: Date.now.addingTimeInterval(-7 * 86_400), to: nil)

        // Session details only matter while a session runs or an activity needs its final content.
        let needCharge = chargingObservation == .charging || (hadCharging && chargingObservation != .unknown)
        let needDrive = (wantsDriving && drivingObservation == .driving)
            || (hadDriving && drivingObservation != .unknown)
        async let chargePage = needCharge ? try? dataSource.charges(vehicleID: vehicleID, range: since, cursor: nil) : nil
        async let drivePage = needDrive ? try? dataSource.drives(vehicleID: vehicleID, range: since, cursor: nil) : nil
        let latestCharge = await chargePage?.items.max { $0.start < $1.start }
        let latestDrive = await drivePage?.items.max { $0.start < $1.start }

        // Unpair, demo or a vehicle switch while fetching makes this sync obsolete.
        guard isLive(syncEpoch, vehicle: vehicleID) else { return }
        // Apply in the lane, after any cleanup queued before it; re-check there.
        await mutate { [weak self] in
            await self?.applyActivities(epoch: syncEpoch, status: status, vehicleName: vehicleName, units: units,
                                        latestCharge: latestCharge, latestDrive: latestDrive)
        }.value
    }

    /// Runs inside the mutation lane. Plans against the activities present now.
    private func applyActivities(epoch syncEpoch: Int, status: VehicleStatus, vehicleName: String,
                                 units: UnitPreferences, latestCharge: ChargeSummary?,
                                 latestDrive: DriveSummary?) async {
        let vehicleID = status.vehicleId
        guard isLive(syncEpoch, vehicle: vehicleID) else { return }
        let usesMiles = units.distance == .miles
        let now = Date.now

        let chargingPlan = LiveActivityPlanner.planCharging(
            existing: activities.chargingActivities(), status: status, vehicleName: vehicleName,
            latestCharge: latestCharge, usesMiles: usesMiles, canStart: activities.canStart, now: now)
        for (id, action) in chargingPlan.existing.sorted(by: { $0.key < $1.key }) {
            guard isLive(syncEpoch, vehicle: vehicleID) else { return }
            await activities.apply(action, toCharging: id)
        }
        if let start = chargingPlan.start {
            await activities.dismissEndedCharging()
            guard isLive(syncEpoch, vehicle: vehicleID) else { return }
            activities.request(start.attributes, start.state)
        }

        // Re-read the preference: the user may have turned it off while this sync waited.
        guard isLive(syncEpoch, vehicle: vehicleID) else { return }
        let drivingPlan = LiveActivityPlanner.planDriving(
            existing: activities.drivingActivities(), status: status, vehicleName: vehicleName,
            latestDrive: latestDrive, usesMiles: usesMiles, enabled: settings.drivingLiveActivity,
            canStart: activities.canStart, now: now)
        for (id, action) in drivingPlan.existing.sorted(by: { $0.key < $1.key }) {
            guard isLive(syncEpoch, vehicle: vehicleID) else { return }
            if case .update = action, !settings.drivingLiveActivity { continue }
            await activities.apply(action, toDriving: id)
        }
        if let start = drivingPlan.start {
            await activities.dismissEndedDriving()
            guard isLive(syncEpoch, vehicle: vehicleID), settings.drivingLiveActivity else { return }
            activities.request(start.attributes, start.state)
        }
    }
}

// MARK: - ActivityKit

/// ActivityKit-backed driver. Concrete per type: generic `Activity<A>` values
/// trip Swift 6 region checks when passed to `update`/`end`, and looking each
/// activity up locally keeps the value inside the call.
@MainActor
final class SystemLiveActivityDriver: LiveActivityDriver {
    var canStart: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Active or stale activities. Ended ones linger in `activities` until dismissed.
    func chargingActivities() -> [LiveActivityPlanner.ChargingRunning] {
        Activity<ChargingActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { .init(id: $0.id, attributes: $0.attributes, state: $0.content.state) }
    }

    func drivingActivities() -> [LiveActivityPlanner.DrivingRunning] {
        Activity<DrivingActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { .init(id: $0.id, attributes: $0.attributes, state: $0.content.state) }
    }

    func apply(_ action: ExistingActivityAction<ChargingActivityAttributes.ContentState>, toCharging id: String) async {
        for activity in Activity<ChargingActivityAttributes>.activities where activity.id == id {
            switch action {
            case .keep: break
            case .update(let state):
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate(for: state, after: VoltaLiveActivityTiming.chargingStaleAfter)))
            case .finish(let state):
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: Self.finalDismissal())
            case .dismiss:
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func apply(_ action: ExistingActivityAction<DrivingActivityAttributes.ContentState>, toDriving id: String) async {
        for activity in Activity<DrivingActivityAttributes>.activities where activity.id == id {
            switch action {
            case .keep: break
            case .update(let state):
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate(for: state, after: VoltaLiveActivityTiming.drivingStaleAfter)))
            case .finish(let state):
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: Self.finalDismissal())
            case .dismiss:
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func dismissEndedCharging() async {
        for activity in Activity<ChargingActivityAttributes>.activities where activity.activityState == .ended {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func dismissEndedDriving() async {
        for activity in Activity<DrivingActivityAttributes>.activities where activity.activityState == .ended {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func request(_ attributes: ChargingActivityAttributes, _ state: ChargingActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state, after: VoltaLiveActivityTiming.chargingStaleAfter))
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func request(_ attributes: DrivingActivityAttributes, _ state: DrivingActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state, after: VoltaLiveActivityTiming.drivingStaleAfter))
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func presentActivities(exceptVehicle keep: Int?) -> LiveActivityIDs {
        LiveActivityIDs(
            charging: Activity<ChargingActivityAttributes>.activities
                .filter { $0.activityState != .dismissed && $0.attributes.vehicleId != keep }.map(\.id),
            driving: Activity<DrivingActivityAttributes>.activities
                .filter { $0.activityState != .dismissed && $0.attributes.vehicleId != keep }.map(\.id))
    }

    /// Looks each id up when its turn comes, so nothing started later is touched.
    func end(_ ids: LiveActivityIDs) async {
        for id in ids.charging {
            for activity in Activity<ChargingActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        for id in ids.driving {
            for activity in Activity<DrivingActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Final content stays briefly, then the system removes it.
    private static func finalDismissal() -> ActivityUIDismissalPolicy {
        .after(.now.addingTimeInterval(VoltaLiveActivityTiming.finalLinger))
    }

    private static func staleDate(for state: some TimestampedContent, after interval: TimeInterval) -> Date {
        state.updatedAt.addingTimeInterval(interval)
    }
}
