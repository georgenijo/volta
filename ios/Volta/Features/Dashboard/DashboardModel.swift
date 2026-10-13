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
    var lastLoadedAt: Date?
    /// Pending history must not look like a successfully loaded empty section.
    private(set) var loadingSections: Set<Section> = []

    private enum SectionResponse: Sendable {
        case timeline(Result<[TimelineSegment], any Error>)
        case summary(SummaryRange, Result<ActivitySummary, any Error>)
    }

    private var generation = 0

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

    /// - Parameter surfaces: receives each successful refresh (widget snapshot,
    ///   Live Activities). nil in previews and tests.
    func load(dataSource: any VoltaDataSource, vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        generation += 1
        let token = generation
        if status == nil { phase = .loading }
        loadingSections = [.timeline, .summary(.today), .summary(.sevenDays), .summary(.thirtyDays)]
        defer { if token == generation { loadingSections = [] } }

        let todayRequestedAt = Date.now
        let todayRequestedZone = TimeZone.current.identifier

        await withTaskGroup(of: SectionResponse.self) { group in
            async let vehiclesReq = Self.result { try await dataSource.vehicles() }
            let issued = surfaces?.nextStatusToken()  // before /status: orders widget publishes
            async let statusReq = Self.result { try await dataSource.status(vehicleID: vehicleID) }
            group.addTask { .timeline(await Self.result { try await dataSource.timeline(vehicleID: vehicleID, hours: 48) }) }
            for range in SummaryRange.allCases {
                group.addTask { .summary(range, await Self.result { try await dataSource.summary(vehicleID: vehicleID, range: range) }) }
            }

            let statusResult = await statusReq
            let vehiclesResult = await vehiclesReq
            guard token == generation, !Task.isCancelled,
                  !Self.isCancellation(statusResult.map { _ in }),
                  !Self.isCancellation(vehiclesResult.map { _ in }) else { group.cancelAll(); return }

            if case .success(let vehicles) = vehiclesResult {
                self.vehicles = vehicles
                vehicle = vehicles.first { $0.id == vehicleID }
            }
            guard case .success(let newStatus) = statusResult else {
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
            // Publish these as soon as status arrives, then fill sections in
            // completion order so one slow summary cannot hold up the others.
            withAnimation(.smooth) {
                status = newStatus
                refreshError = nil
                lastLoadedAt = .now
                phase = .loaded
            }
            var freshTimeline: [TimelineSegment]?
            var freshToday: TodaySummary?
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
                            freshToday = today
                        } else { summaries[range] = summary }
                        failedSections.remove(.summary(range))
                    case .failure: failedSections.insert(.summary(range))
                    }
                }
            }
            // One ordered publication per status request, preserving the
            // existing widget / Live Activity ordering and reporting-day rules.
            guard token == generation, !Task.isCancelled, !cancelledSection else { return }
            if let surfaces, let issued {
                surfaces.publish(VehicleRefresh(status: newStatus, issued: issued,
                    vehicleName: vehicle?.name, today: freshToday, timeline: freshTimeline), dataSource: dataSource)
            }
        }
    }

    private static func result<T: Sendable>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
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
