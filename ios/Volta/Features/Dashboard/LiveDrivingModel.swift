import Foundation

// MARK: - What to show

/// What the Dashboard's driving card shows, from one status and when this
/// device fetched it. Pure, so every honesty rule is testable:
///
/// - Unknown is unknown: no value becomes zero.
/// - A value is live only when the server said it holds now (`current`) and
///   the status is recent here (`liveWindow`); otherwise it carries its age.
/// - A status saved by an earlier launch never shows a live value.
struct LiveDriveDisplay: Equatable {
    enum Speed: Equatable {
        case live(kph: Double)
        /// The car has not moved since `since` (from the stream's silence).
        case stopped(since: Date)
        case stale(kph: Double, at: Date)
        case unknown
    }

    enum Power: Equatable {
        /// Battery power now: positive drives, negative is regen.
        case live(kw: Double)
        case stale(kw: Double, at: Date)
        /// Stopped, and the stream reports power only while the car moves.
        case awaitingMovement
        case unknown
    }

    enum Freshness: Equatable {
        case live
        /// Nothing holds now; the newest reading is from `at`.
        case lastReading(at: Date)
        /// This device has not heard from the server since `at`.
        case notRefreshed(since: Date)
        case saved(at: Date)
        case unknown
    }

    var gear: LiveDrive.Gear?
    var gearIsLive: Bool
    var speed: Speed
    var power: Power
    var freshness: Freshness

    /// How long a status fetched here stays live: three missed refreshes.
    static let liveWindow: TimeInterval = 15
    /// Below this, power is shown as zero rather than as drive or regen.
    static let idlePowerKw = 0.5

    /// Whether the car is on the road. A live gear decides (Park ends a drive
    /// before TeslaMate closes it; Drive starts one before TeslaMate opens it);
    /// otherwise the server's state does.
    static func isDriving(_ status: VehicleStatus) -> Bool {
        if status.telemetryFreshness?.savedAt == nil, let gear = status.liveDrive?.gear, gear.current {
            return gear.value != .p
        }
        return status.state == .driving
    }

    /// - Parameter fetchedAt: when this device received `status`; nil when
    ///   it has not (a saved status, or a placeholder).
    static func make(_ status: VehicleStatus, fetchedAt: Date?, now: Date = .now) -> LiveDriveDisplay {
        if let savedAt = status.telemetryFreshness?.savedAt {
            return LiveDriveDisplay(gear: nil, gearIsLive: false, speed: .unknown, power: .unknown,
                                    freshness: .saved(at: savedAt))
        }
        let drive = status.liveDrive
        let recent = fetchedAt.map { now.timeIntervalSince($0) <= liveWindow } ?? false
        func live<T>(_ reading: LiveDrive.Reading<T>?) -> Bool { recent && reading?.current == true }

        let speed: Speed
        if let reading = drive?.speedKph, live(reading) {
            speed = .live(kph: max(0, reading.value))
        } else if recent, let since = drive?.stoppedSince {
            speed = .stopped(since: since)
        } else if let reading = drive?.speedKph {
            speed = .stale(kph: max(0, reading.value), at: reading.observedAt)
        } else {
            speed = .unknown
        }

        let power: Power
        if let reading = drive?.powerKw, live(reading) {
            power = .live(kw: reading.value)
        } else if case .stopped = speed {
            power = .awaitingMovement
        } else if let reading = drive?.powerKw {
            power = .stale(kw: reading.value, at: reading.observedAt)
        } else {
            power = .unknown
        }

        let anyLive = live(drive?.gear) || live(drive?.speedKph) || live(drive?.powerKw)
            || { if case .stopped = speed { return true } else { return false } }()
        let freshness: Freshness
        if anyLive {
            freshness = .live
        } else if let fetchedAt, !recent {
            freshness = .notRefreshed(since: fetchedAt)
        } else if let newest = [drive?.gear?.observedAt, drive?.speedKph?.observedAt, drive?.powerKw?.observedAt]
            .compactMap({ $0 }).max() {
            freshness = .lastReading(at: min(newest, now))
        } else {
            freshness = .unknown
        }
        return LiveDriveDisplay(gear: drive?.gear?.value, gearIsLive: live(drive?.gear), speed: speed, power: power,
                                freshness: freshness)
    }
}

// MARK: - Text

/// Words and numbers for the driving card, in the app's units.
enum LiveDriveText {
    static func speedUnit(_ units: UnitPreferences) -> String { units.distance == .miles ? "mph" : "km/h" }

    static func speed(kph: Double, units: UnitPreferences) -> String {
        VoltaFormat.number(units.distanceValue(km: kph), digits: 0)
    }

    /// "42" for drive, "18" for regen: the sign is the label's job.
    static func power(kw: Double) -> String {
        let magnitude = abs(kw)
        return magnitude < LiveDriveDisplay.idlePowerKw ? "0" : VoltaFormat.number(magnitude, digits: 0)
    }

    enum PowerKind: Equatable { case drive, regen, idle }

    static func kind(kw: Double) -> PowerKind {
        kw >= LiveDriveDisplay.idlePowerKw ? .drive : kw <= -LiveDriveDisplay.idlePowerKw ? .regen : .idle
    }

    static func powerTitle(_ power: LiveDriveDisplay.Power) -> String {
        switch power {
        case .live(let kw), .stale(let kw, _):
            switch kind(kw: kw) {
            case .regen: "Regen"
            case .drive, .idle: "Power"
            }
        case .awaitingMovement, .unknown: "Power"
        }
    }

    /// "Live", "Updated 40 sec. ago", "Saved 2 hr. ago".
    static func freshness(_ freshness: LiveDriveDisplay.Freshness, now: Date = .now) -> String? {
        switch freshness {
        case .live: "Live"
        case .lastReading(let at): "Seen \(age(at, now: now))"
        case .notRefreshed(let since): "Updated \(age(since, now: now))"
        case .saved(let at): "Saved \(age(at, now: now))"
        case .unknown: nil
        }
    }

    static func age(_ date: Date, now: Date = .now) -> String {
        now.timeIntervalSince(date) < 5 ? "just now" : VoltaFormat.relativeDate(min(date, now), now: now)
    }

    /// One sentence for VoiceOver.
    static func accessibility(_ display: LiveDriveDisplay, units: UnitPreferences, now: Date = .now) -> String {
        let unitName = units.distance == .miles ? "miles per hour" : "kilometres per hour"
        let speed: String = switch display.speed {
        case .live(let kph): "\(Self.speed(kph: kph, units: units)) \(unitName)"
        case .stopped: "Stopped"
        case .stale(let kph, let at): "\(Self.speed(kph: kph, units: units)) \(unitName), \(age(at, now: now))"
        case .unknown: "Speed unknown"
        }
        let power: String = switch display.power {
        case .live(let kw): powerSentence(kw)
        case .stale(let kw, let at): "\(powerSentence(kw)), \(age(at, now: now))"
        case .awaitingMovement: "Power updates when the car moves"
        case .unknown: "Power unknown"
        }
        let gear = display.gear.map { "Gear \($0.rawValue)" } ?? "Gear unknown"
        return ["Driving", speed, power, gear, freshness(display.freshness, now: now)].compactMap { $0 }
            .joined(separator: ". ")
    }

    private static func powerSentence(_ kw: Double) -> String {
        switch kind(kw: kw) {
        case .drive: "Using \(power(kw: kw)) kilowatts"
        case .regen: "Regenerating \(power(kw: kw)) kilowatts"
        case .idle: "No power drawn"
        }
    }
}

// MARK: - Refreshing

/// Refreshes the Dashboard's status while the car drives and the driving card
/// is on screen. Runs as a `.task` keyed by `shouldRun`, so leaving the
/// screen, the app going inactive or the drive ending cancels it: no timer
/// outlives it. Only `/status` is requested; history reloads once the drive ends.
@MainActor
@Observable
final class LiveDrivingRefresher {
    enum Outcome: Equatable { case cancelled, driveEnded }

    /// Telemetry arrives every 2 s while moving; TeslaMate every few.
    static let interval: Duration = .seconds(5)
    /// How often a refresh also updates widgets and the driving Live
    /// Activity: each publish fetches the open drive and reloads widgets.
    static let surfaceInterval: TimeInterval = 30

    private(set) var isRunning = false
    /// The latest refresh got no answer; the card ages what it shows.
    private(set) var lastFailed = false
    private var lastSurfacePublish: Date?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Refresh only while the Dashboard is visible, the scene active and the car driving.
    nonisolated static func shouldRun(visible: Bool, sceneActive: Bool, status: VehicleStatus?) -> Bool {
        guard visible, sceneActive, let status, status.telemetryFreshness?.savedAt == nil else { return false }
        return LiveDriveDisplay.isDriving(status)
    }

    /// Refreshes until cancelled or the drive ends. Waits one interval first:
    /// the Dashboard has just loaded.
    func run(dashboard: DashboardModel, dataSource: any VoltaDataSource, vehicleID: Int,
             surfaces: (any VehicleSurfaces)?, now: @escaping () -> Date = { .now }) async -> Outcome {
        isRunning = true
        defer { isRunning = false }
        // The load that showed the drive has just published.
        lastSurfacePublish = now()
        while true {
            do { try await sleep(Self.interval) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
            let generation = dashboard.loadGeneration
            let issued = surfaces?.nextStatusToken()
            let status: VehicleStatus
            do { status = try await dataSource.status(vehicleID: vehicleID) } catch {
                if Task.isCancelled { return .cancelled }
                lastFailed = true
                continue
            }
            if Task.isCancelled { return .cancelled }
            lastFailed = false
            guard dashboard.showLive(status, vehicleID: vehicleID, startedGeneration: generation) else { continue }
            let at = now()
            if let surfaces, let issued,
               lastSurfacePublish.map({ at.timeIntervalSince($0) >= Self.surfaceInterval }) ?? true || !LiveDriveDisplay.isDriving(status) {
                lastSurfacePublish = at
                surfaces.publish(VehicleRefresh(status: status, issued: issued, vehicleName: dashboard.vehicle?.name),
                                 dataSource: dataSource)
            }
            if !LiveDriveDisplay.isDriving(status) { return .driveEnded }
        }
    }
}
