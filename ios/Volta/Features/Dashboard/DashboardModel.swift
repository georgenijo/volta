import SwiftUI

/// Loads everything the dashboard shows. Keeps the last good data on refresh
/// failure so the screen degrades to a banner instead of an error page.
///
/// Loads may overlap (initial `.task` + pull-to-refresh). Each load takes a
/// generation number and only the newest one may publish results or errors;
/// cancelled loads publish no further results. Already-visible data stays on screen.
@MainActor
@Observable
final class DashboardModel {
    /// `noData`: the server is reachable but has no battery reading for this
    /// vehicle yet (status 409 `data_unavailable`).
    enum Phase: Equatable { case loading, loaded, noData, failed(String) }

    /// A dashboard section that loads independently of the vehicle status.
    enum Section: Hashable, CustomStringConvertible {
        case timeline
        case summary(SummaryRange)

        var description: String {
            switch self {
            case .timeline: "48h timeline"
            case .summary(let range): "\(range.voltaLabel) activity"
            }
        }
    }

    var phase: Phase = .loading
    /// The dashboard's vehicle; never another car's details.
    var vehicle: Vehicle?
    /// The account's vehicles as of the latest load, for switching.
    var vehicles: [Vehicle] = []
    var status: VehicleStatus?
    var timeline: [TimelineSegment] = []
    var summaries: [SummaryRange: ActivitySummary] = [:]
    /// Reporting day of `summaries[.today]` (`TodaySummary.day`, same rule as
    /// the widgets). Kept totals stop showing as "Today" once it ends or the
    /// device changes zone.
    private(set) var todayDay: ReportingDay.Day?
    /// Device zone for the "Today" check; see `deviceZoneChanged`.
    private(set) var deviceZone = TimeZone.current.identifier
    /// Set when a refresh failed but older data is still on screen.
    var refreshError: String?
    /// Sections whose latest load failed. Their previous data (if any) is kept;
    /// a section here with no data means "failed", not "empty".
    var failedSections: Set<Section> = []
    /// When this process last loaded fresh status; nil while only saved data
    /// is shown (the saved time is in the status's freshness label).
    var lastLoadedAt: Date?
    /// Pending history must not look like a successfully loaded empty section.
    private(set) var loadingSections: Set<Section> = []

    private enum SectionResponse: Sendable {
        case timeline(Result<[TimelineSegment], any Error>)
        case summary(SummaryRange, Result<ActivitySummary, any Error>)
    }

    private var generation = 0
    /// When and in which zone the shown today total was requested.
    private var todayRequest: (at: Date, zone: String)?
    /// Where loads are saved for the next launch; from the first load's start.
    private var savedStore: (any SavedDashboardStoring)?
    private var savedBackend: String?
    /// The shown status came from the saved dashboard, not this process.
    private(set) var showsSavedStatus = false

    /// Whether returning to the foreground should reload: fresh data is over
    /// 30 s old and no load is still filling the screen. Saved data alone
    /// never counts, so a launch with saved data sends one set of requests.
    func foregroundRefreshDue(now: Date = .now) -> Bool {
        guard loadingSections.isEmpty, let lastLoadedAt else { return false }
        return now.timeIntervalSince(lastLoadedAt) > 30
    }

    /// Short message for the partial-failure banner, if any section failed.
    var partialFailureMessage: String? {
        guard !failedSections.isEmpty else { return nil }
        let order: [Section] = [.timeline, .summary(.today), .summary(.sevenDays), .summary(.thirtyDays)]
        let names = order.filter(failedSections.contains).map(\.description)
        return "Couldn't load \(names.joined(separator: ", "))."
    }

    var timelineFailed: Bool { failedSections.contains(.timeline) }

    func summaryFailed(_ range: SummaryRange) -> Bool { failedSections.contains(.summary(range)) }

    /// `summaries` as shown at `now`: today's totals only while their day is current.
    func visibleSummaries(at now: Date) -> [SummaryRange: ActivitySummary] {
        var visible = summaries
        if todayDay?.isCurrent(at: now, deviceZone: deviceZone) != true { visible[.today] = nil }
        return visible
    }

    /// Call when the system time zone changes (then reload): hides "Today"
    /// totals computed for the previous zone.
    func deviceZoneChanged(to zone: String = TimeZone.current.identifier) {
        deviceZone = zone
    }

    /// A first load from an already-loaded vehicle list.
    func load(dataSource: any VoltaDataSource, vehicleID: Int, initialVehicles: [Vehicle]?,
              surfaces: (any VehicleSurfaces)? = nil) async {
        await load(dataSource: dataSource, vehicleID: vehicleID,
                   initialVehicles: initialVehicles.map(DashboardStart.init(vehicles:)), surfaces: surfaces)
    }

    /// - Parameters:
    ///   - initialVehicles: what a new model starts from (the parameter keeps
    ///     its name from when it carried only the app's vehicle list). On a
    ///     model's first load, the saved dashboard for `vehicleID` is shown at
    ///     once, labelled as saved, and the app's startup list, if it contains
    ///     `vehicleID`, replaces a `/vehicles` request. Later loads always
    ///     refresh the list, and every load with fresh status is saved.
    ///   - surfaces: receives each successful refresh (widget snapshot, Live
    ///     Activities). nil in previews and tests.
    func load(dataSource: any VoltaDataSource, vehicleID: Int, initialVehicles start: DashboardStart? = nil,
              surfaces: (any VehicleSurfaces)? = nil) async {
        generation += 1
        let token = generation
        let isNewModel = status == nil && vehicles.isEmpty
        if let store = start?.store { savedStore = store; savedBackend = start?.backend }
        if isNewModel, let saved = start?.saved, saved.vehicleID == vehicleID { show(saved) }
        if status == nil { phase = .loading }
        loadingSections = [.timeline, .summary(.today), .summary(.sevenDays), .summary(.thirtyDays)]
        defer { if token == generation { loadingSections = [] } }

        // Accept the app's startup list only for a genuinely new model and
        // only when it contains the selected vehicle; an invalid seed falls
        // back to the server request and preserves the existing missing-vehicle behavior.
        let seededVehicles = isNewModel ? start?.vehicles : nil
        // The app's launch /status for this vehicle, if this is the first dashboard.
        // One sent too long ago (the app was prewarmed or suspended) would show
        // an old status as fresh.
        let prefetch = isNewModel && start?.prefetch?.isUsable(for: vehicleID) == true ? start?.prefetch : nil
        if prefetch == nil { start?.prefetch?.cancel() }

        let todayRequestedAt = Date.now
        let todayRequestedZone = TimeZone.current.identifier

        await withTaskGroup(of: SectionResponse.self) { group in
            async let vehiclesReq = Self.vehicleResult(dataSource: dataSource, vehicleID: vehicleID,
                                                       seededVehicles: seededVehicles)
            // Taken before /status (here or by the prefetch): orders widget publishes.
            let issued = prefetch.map { $0.issued } ?? surfaces?.nextStatusToken()
            let statusTask = prefetch?.status
            async let statusReq = Self.result {
                if let statusTask {
                    do { return try await DashboardPrefetch.value(of: statusTask) } catch {
                        // A launch request can fail while the app is suspended on
                        // a good network: send one new request before showing an error.
                        guard !Task.isCancelled, Self.isTransportFailure(error) else { throw error }
                    }
                }
                return try await dataSource.status(vehicleID: vehicleID)
            }
            group.addTask { .timeline(await Self.result { try await dataSource.timeline(vehicleID: vehicleID, hours: 48) }) }
            for range in SummaryRange.allCases {
                group.addTask { .summary(range, await Self.result { try await dataSource.summary(vehicleID: vehicleID, range: range) }) }
            }

            let statusResult = await statusReq
            guard token == generation, !Task.isCancelled,
                  !Self.isCancellation(statusResult.map { _ in }) else { group.cancelAll(); return }
            guard case .success(let newStatus) = statusResult else {
                let vehiclesResult = await vehiclesReq
                guard token == generation, !Task.isCancelled,
                      !Self.isCancellation(vehiclesResult.map { _ in }) else { group.cancelAll(); return }
                apply(vehiclesResult, selectedVehicleID: vehicleID)
                if case .failure(let error) = statusResult {
                    let message = Self.message(for: error)
                    if status != nil { refreshError = message }
                    else if case .server(code: "data_unavailable", _) = error as? VoltaError { phase = .noData }
                    else { phase = .failed(message) }
                }
                group.cancelAll()
                return
            }

            // Battery, range, controls and the map do not depend on history.
            // Publish these as soon as status arrives. In particular, a normal
            // vehicle-list refresh must not hold fresh status off screen.
            withAnimation(.smooth) {
                // History shown from the saved dashboard has no label of its
                // own once fresh status replaces the saved one: hide it until
                // this load replaces it, so pending and failed sections show.
                if showsSavedStatus {
                    timeline = []; summaries = [:]; todayDay = nil; todayRequest = nil
                }
                status = newStatus
                showsSavedStatus = false
                refreshError = nil
                lastLoadedAt = .now
                phase = .loaded
            }
            let statusLoadedAt = lastLoadedAt ?? .now
            StartupTrace.mark(.status)

            let vehiclesResult = await vehiclesReq
            guard token == generation, !Task.isCancelled else { group.cancelAll(); return }
            // A request-level cancellation is only a list failure. Fresh status
            // is already visible, so continue consuming independent history.
            apply(vehiclesResult, selectedVehicleID: vehicleID)

            // Fill history sections in completion order so one slow summary
            // cannot hold up the others.
            var freshTimeline: [TimelineSegment]?
            var freshToday: TodaySummary?
            /// Sections loaded by this load; only these are saved.
            var freshSummaries: [SummaryRange: ActivitySummary] = [:]
            var cancelledSection = false
            for await response in group {
                guard token == generation, !Task.isCancelled else { group.cancelAll(); return }
                switch response {
                case .timeline(let result):
                    loadingSections.remove(.timeline)
                    if Self.isCancellation(result.map { _ in }) {
                        cancelledSection = true
                        failedSections.insert(.timeline)
                        continue
                    }
                    switch result {
                    case .success(let segments):
                        timeline = segments
                        freshTimeline = segments
                        failedSections.remove(.timeline)
                    case .failure: failedSections.insert(.timeline)
                    }
                case .summary(let range, let result):
                    loadingSections.remove(.summary(range))
                    if Self.isCancellation(result.map { _ in }) {
                        cancelledSection = true
                        failedSections.insert(.summary(range))
                        continue
                    }
                    switch result {
                    case .success(let summary):
                        if range == .today {
                            let today = TodaySummary(summary: summary, requestedAt: todayRequestedAt,
                                                     requestedZone: todayRequestedZone)
                            deviceZone = TimeZone.current.identifier
                            let current = today.day.isCurrent(at: .now, deviceZone: deviceZone)
                            summaries[.today] = current ? summary : nil
                            todayDay = current ? today.day : nil
                            todayRequest = current ? (todayRequestedAt, todayRequestedZone) : nil
                            freshToday = today
                            if current { freshSummaries[.today] = summary }
                        } else { summaries[range] = summary; freshSummaries[range] = summary }
                        failedSections.remove(.summary(range))
                    case .failure: failedSections.insert(.summary(range))
                    }
                }
            }
            guard token == generation, !Task.isCancelled else { return }
            if failedSections.isEmpty { StartupTrace.mark(.sections) }
            save(status: newStatus, vehicleID: vehicleID, at: statusLoadedAt, timeline: freshTimeline,
                 summaries: freshSummaries, todayRequestedAt: todayRequestedAt, todayRequestedZone: todayRequestedZone)
            // One ordered publication per status request, preserving the
            // existing widget / Live Activity ordering and reporting-day rules.
            guard token == generation, !Task.isCancelled, !cancelledSection else { return }
            if let surfaces, let issued {
                surfaces.publish(VehicleRefresh(status: newStatus, issued: issued,
                    vehicleName: vehicle?.name, today: freshToday, timeline: freshTimeline), dataSource: dataSource)
            }
        }
    }

    /// Shows the previous launch's dashboard until fresh data replaces it.
    private func show(_ saved: SavedDashboard) {
        vehicles = saved.vehicles
        vehicle = saved.vehicles.first { $0.id == saved.vehicleID }
        status = saved.labelledStatus
        showsSavedStatus = true
        timeline = saved.timeline
        for summary in saved.summaries where summary.range != .today { summaries[summary.range] = summary }
        if let today = saved.today {
            deviceZone = TimeZone.current.identifier
            if today.day.isCurrent(at: .now, deviceZone: deviceZone) {
                summaries[.today] = today.summary
                todayDay = today.day
                todayRequest = (today.requestedAt, today.requestedZone)
            }
        }
        // `lastLoadedAt` stays nil: saved data must not look like a recent load.
        phase = .loaded
        StartupTrace.mark(.cachedStatus)
    }

    /// Saves a load with fresh status for the next launch: only the sections
    /// this load fetched, so nothing older is saved under `savedAt`. A failed
    /// section is left out and shows as loading on the next launch.
    private func save(status: VehicleStatus, vehicleID: Int, at savedAt: Date, timeline: [TimelineSegment]?,
                      summaries: [SummaryRange: ActivitySummary], todayRequestedAt: Date, todayRequestedZone: String) {
        guard let savedStore, let savedBackend else { return }
        let hasToday = summaries[.today] != nil
        savedStore.write(SavedDashboard(
            backend: savedBackend, vehicleID: vehicleID, savedAt: savedAt, vehicles: vehicles, status: status,
            timeline: timeline ?? [], summaries: SummaryRange.allCases.compactMap { summaries[$0] },
            todayRequestedAt: hasToday ? todayRequestedAt : nil,
            todayRequestedZone: hasToday ? todayRequestedZone : nil))
    }

    private func apply(_ result: Result<[Vehicle], any Error>, selectedVehicleID: Int) {
        guard case .success(let vehicles) = result else { return }
        self.vehicles = vehicles
        vehicle = vehicles.first { $0.id == selectedVehicleID }
    }

    private static func vehicleResult(dataSource: any VoltaDataSource, vehicleID: Int,
                                      seededVehicles: (@MainActor @Sendable () async -> [Vehicle]?)?) async -> Result<[Vehicle], any Error> {
        if let seededVehicles, let list = await seededVehicles(), list.contains(where: { $0.id == vehicleID }) {
            return .success(list)
        }
        return await result { try await dataSource.vehicles() }
    }

    private static func result<T: Sendable>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// No answer from the server, as opposed to an answer that was an error.
    nonisolated static func isTransportFailure(_ error: any Error) -> Bool {
        switch error as? VoltaError {
        case .transport, .unreachable: return true
        case .some: return false
        case nil: return (error as? URLError).map { $0.code != .cancelled } ?? false
        }
    }

    private static func isCancellation(_ result: Result<Void, any Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension VehicleStatus {
    /// Placeholder used for the redacted loading skeleton.
    static let skeleton = VehicleStatus(
        vehicleId: 0, state: .online, updatedAt: .now, batteryLevel: 75, usableBatteryLevel: nil,
        ratedRangeKm: 400, estRangeKm: 400, chargeLimit: 80, chargingState: nil, chargerPowerKw: nil,
        minutesToFull: nil, insideTempC: 20, outsideTempC: 15, climateOn: false, driverTempSettingC: nil,
        locked: true, sentryMode: false, odometerKm: nil, location: nil, firmware: nil
    )
}

extension VehicleState {
    var displayName: String {
        switch self {
        case .online: "Online"
        case .asleep: "Asleep"
        case .offline: "Offline"
        case .driving: "Driving"
        case .charging: "Charging"
        case .updating: "Updating"
        }
    }

    var color: Color {
        switch self {
        case .online, .charging: .voltaGreen
        case .driving, .updating: .voltaBlue
        case .asleep: .voltaTextSecondary
        case .offline: .voltaTextTertiary
        }
    }
}
