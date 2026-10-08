import SwiftUI

/// Loads everything the dashboard shows. Keeps the last good data on refresh
/// failure so the screen degrades to a banner instead of an error page.
///
/// Loads may overlap (initial `.task` + pull-to-refresh). Each load takes a
/// generation number and only the newest one may publish results or errors;
/// cancelled loads publish nothing.
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

        async let vehiclesReq = Self.result { try await dataSource.vehicles() }
        let issued = surfaces?.nextStatusToken()  // before the /status request: orders publishes
        async let statusReq = Self.result { try await dataSource.status(vehicleID: vehicleID) }
        async let timelineReq = Self.result { try await dataSource.timeline(vehicleID: vehicleID, hours: 48) }
        let todayRequestedAt = Date.now  // attributes the totals to a reporting day
        let todayRequestedZone = TimeZone.current.identifier  // the `tz` the request sends
        async let todayReq = Self.result { try await dataSource.summary(vehicleID: vehicleID, range: .today) }
        async let weekReq = Self.result { try await dataSource.summary(vehicleID: vehicleID, range: .sevenDays) }
        async let monthReq = Self.result { try await dataSource.summary(vehicleID: vehicleID, range: .thirtyDays) }

        let statusResult = await statusReq
        let vehiclesResult = await vehiclesReq
        let timelineResult = await timelineReq
        let summaryResults: [(SummaryRange, Result<ActivitySummary, any Error>)] =
            [(.today, await todayReq), (.sevenDays, await weekReq), (.thirtyDays, await monthReq)]

        // Only the newest, uncancelled load may publish anything.
        let all: [Result<Void, any Error>] = [statusResult.map { _ in }, vehiclesResult.map { _ in },
                                              timelineResult.map { _ in }] + summaryResults.map { $0.1.map { _ in } }
        guard token == generation, !Task.isCancelled,
              !all.contains(where: { Self.isCancellation($0) }) else { return }

        if case .success(let vehicles) = vehiclesResult {
            self.vehicles = vehicles
            vehicle = vehicles.first { $0.id == vehicleID }
        }
        switch statusResult {
        case .failure(let error):
            let message = Self.message(for: error)
            if status != nil { refreshError = message }
            else if case .server(code: "data_unavailable", _) = error as? VoltaError { phase = .noData }
            else { phase = .failed(message) }
        case .success(let newStatus):
            withAnimation(.smooth) {
                status = newStatus
                var failed: Set<Section> = []
                switch timelineResult {
                case .success(let segments): timeline = segments
                case .failure: failed.insert(.timeline)
                }
                for (range, result) in summaryResults {
                    switch result {
                    case .success(let summary) where range == .today:
                        // Totals whose day ended before publishing are not "Today".
                        let day = TodaySummary(summary: summary, requestedAt: todayRequestedAt,
                                               requestedZone: todayRequestedZone).day
                        deviceZone = TimeZone.current.identifier
                        let current = day.isCurrent(at: .now, deviceZone: deviceZone)
                        summaries[.today] = current ? summary : nil
                        todayDay = current ? day : nil
                    case .success(let summary): summaries[range] = summary
                    case .failure: failed.insert(.summary(range))
                    }
                }
                failedSections = failed
                refreshError = nil
                lastLoadedAt = .now
                phase = .loaded
            }
            let todayResult = summaryResults.first { $0.0 == .today }?.1
            if let surfaces, let issued { surfaces.publish(VehicleRefresh(
                status: newStatus,
                issued: issued,
                vehicleName: (try? vehiclesResult.get())?.first { $0.id == vehicleID }?.name,
                today: (try? todayResult?.get()).map { TodaySummary(summary: $0, requestedAt: todayRequestedAt,
                                                                    requestedZone: todayRequestedZone) },
                timeline: try? timelineResult.get()), dataSource: dataSource) }
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
