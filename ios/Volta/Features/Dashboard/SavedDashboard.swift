import CryptoKit
import Foundation
import Synchronization
import os

/// The last dashboard loaded from a server, kept on this device so a relaunch
/// can show it, labelled as saved, while fresh data loads.
///
/// It is written only after a fresh `/status` from a paired server, and is
/// tied to the backend it came from (server and device token) and one vehicle.
/// Unpairing, demo mode and a revoked token remove it. It never reaches
/// widgets or Live Activities, which publish fresh data only.
struct SavedDashboard: Codable, Equatable, Sendable {
    /// Bump when the shape changes; older files are ignored.
    static let currentVersion = 1

    var version = SavedDashboard.currentVersion
    /// `backendKey(_:)` of the backend it came from.
    var backend: String
    var vehicleID: Int
    var savedAt: Date
    var vehicles: [Vehicle]
    var status: VehicleStatus
    var timeline: [TimelineSegment]
    var summaries: [ActivitySummary]
    /// When and in which zone `summaries`' today total was requested, so its
    /// reporting day can be recomputed. nil when no today total was saved.
    var todayRequestedAt: Date?
    var todayRequestedZone: String?

    /// The saved today total, attributed to its reporting day.
    var today: TodaySummary? {
        guard let summary = summaries.first(where: { $0.range == .today }),
              let requestedAt = todayRequestedAt, let zone = todayRequestedZone else { return nil }
        return TodaySummary(summary: summary, requestedAt: requestedAt, requestedZone: zone)
    }

    /// A stable, non-reversible key for a backend's `commandBackendID` (server
    /// address plus a digest of the device token).
    static func backendKey(_ backendID: String) -> String {
        SHA256.hash(data: Data(backendID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `status`, marked so screens label it as saved rather than live. It keeps
    /// no location observation time, so HomeLink can never act on it.
    var labelledStatus: VehicleStatus {
        var status = status
        status.locationUpdatedAt = nil
        var freshness = status.telemetryFreshness ?? TelemetryFreshness(connected: false, lastSeenAt: nil, recordedAt: [:])
        freshness.savedAt = savedAt
        status.telemetryFreshness = freshness
        return status
    }
}

/// Reads and writes `SavedDashboard`. Main-actor so the launch read finishes
/// before the first frame; the file is a few kilobytes.
@MainActor
protocol SavedDashboardStoring: AnyObject {
    /// The backend whose dashboards may be written; nil accepts none. Set
    /// when pairing changes, so a load that outlives its pairing saves nothing.
    var acceptedBackend: String? { get set }
    func read(backend: String) -> SavedDashboard?
    /// Ignored unless `dashboard.backend` is `acceptedBackend`.
    func write(_ dashboard: SavedDashboard)
    func remove()
}

/// One JSON file in Application Support, excluded from backups and readable
/// only while the device is unlocked.
@MainActor
final class SavedDashboardFile: SavedDashboardStoring {
    var acceptedBackend: String?
    private let url: URL
    /// Writes run in order, off the main thread.
    private var lastWrite: Task<Void, Never>?
    /// Bumped by `remove()`. A write lands only while the epoch it was queued
    /// in is current, checked under the same lock as the file operation, so
    /// no queued write can recreate the file after `remove()` returns.
    private let epoch = Fence()
    private let beforeWrite: (@Sendable () async -> Void)?
    nonisolated private static let logger = Logger(subsystem: "com.georgenijo.volta", category: "saved-dashboard")

    /// - Parameter beforeWrite: runs before each queued write takes the lock (tests).
    init(url: URL? = nil, beforeWrite: (@Sendable () async -> Void)? = nil) {
        self.url = url ?? URL.applicationSupportDirectory
            .appending(path: "Volta", directoryHint: .isDirectory)
            .appending(path: "saved-dashboard.json")
        self.beforeWrite = beforeWrite
    }

    func read(backend: String) -> SavedDashboard? {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedDashboard.self, from: data),
              saved.version == SavedDashboard.currentVersion, saved.backend == backend else { return nil }
        return saved
    }

    func write(_ dashboard: SavedDashboard) {
        guard dashboard.backend == acceptedBackend else { return }
        let url = url, previous = lastWrite, epoch = epoch, beforeWrite = beforeWrite
        let queuedIn = epoch.current
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(dashboard) else { return }
            await beforeWrite?()
            epoch.ifCurrent(queuedIn) {
                Self.prepareDirectory(url.deletingLastPathComponent())
                // A failed write only costs the next launch its instant dashboard.
                do { try data.write(to: url, options: Self.writeOptions) }
                catch { Self.logger.error("saved dashboard write failed: \(Self.describe(error), privacy: .public)") }
            }
        }
    }

    /// Readable only while the device is unlocked.
    nonisolated static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    /// Deletes the file before returning; writes queued earlier are dropped.
    func remove() {
        let url = url
        epoch.advance {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile {}
            catch { Self.logger.error("saved dashboard removal failed: \(Self.describe(error), privacy: .public)") }
        }
    }

    /// Waits for queued writes (tests).
    func drain() async { await lastWrite?.value }

    nonisolated private static func prepareDirectory(_ directory: URL) {
        var directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            logger.error("saved dashboard backup exclusion failed: \(describe(error), privacy: .public)")
        }
    }

    /// Error domain and code only: no paths or contents.
    nonisolated private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    private final class Fence: Sendable {
        private let value = Mutex<UInt64>(0)
        var current: UInt64 { value.withLock { $0 } }
        func ifCurrent(_ expected: UInt64, _ body: () -> Void) {
            value.withLock { if $0 == expected { body() } }
        }
        func advance(_ body: () -> Void) {
            value.withLock { $0 += 1; body() }
        }
    }
}

/// What a newly mounted dashboard starts from. See
/// `AppModel.takeInitialDashboardVehicles(vehicleID:)`.
struct DashboardStart {
    /// The app's startup vehicle list, offered to the first dashboard only.
    /// It may still be loading: the closure waits for it, and returns nil when
    /// that load failed or was superseded.
    var vehicles: (@MainActor @Sendable () async -> [Vehicle]?)?
    /// The last dashboard saved for this backend and vehicle, if any.
    var saved: SavedDashboard?
    /// Where fresh loads are saved. nil in demo mode, previews and tests.
    var store: (any SavedDashboardStoring)?
    /// `store`'s key for the current backend.
    var backend: String?
    /// The first dashboard's `/status`, already sent while the first frame was built.
    var prefetch: DashboardPrefetch?

    init(vehicles: (@MainActor @Sendable () async -> [Vehicle]?)? = nil, saved: SavedDashboard? = nil,
         store: (any SavedDashboardStoring)? = nil, backend: String? = nil, prefetch: DashboardPrefetch? = nil) {
        self.vehicles = vehicles; self.saved = saved; self.store = store; self.backend = backend
        self.prefetch = prefetch
    }

    /// A list that is already loaded.
    init(vehicles: [Vehicle]) {
        self.init(vehicles: { vehicles })
    }
}

/// An in-memory store for tests and test token stores.
@MainActor
final class MemorySavedDashboards: SavedDashboardStoring {
    var acceptedBackend: String?
    private(set) var dashboard: SavedDashboard?
    init(_ dashboard: SavedDashboard? = nil) { self.dashboard = dashboard }
    func read(backend: String) -> SavedDashboard? { dashboard?.backend == backend ? dashboard : nil }
    func write(_ dashboard: SavedDashboard) {
        guard dashboard.backend == acceptedBackend else { return }
        self.dashboard = dashboard
    }
    func remove() { dashboard = nil }
}

/// The first dashboard's `/status`, sent by `AppModel` at launch when the
/// saved dashboard means the shell will mount at once. The first dashboard
/// for the same vehicle awaits it instead of sending its own; whoever
/// discards it cancels it. Only status is sent early: history requests sent
/// alongside it would compete for new connections and delay it.
@MainActor
final class DashboardPrefetch {
    let vehicleID: Int
    /// The widget-ordering token, taken just before `/status` was sent.
    let issued: StatusRequestToken?
    let status: Task<VehicleStatus, any Error>
    /// When `/status` was sent. The clock keeps counting while the app is suspended.
    let sentAt: ContinuousClock.Instant
    /// How old a prefetch the first dashboard still adopts. Older ones were
    /// sent before a suspension (or a prewarm), and their answer is not fresh.
    static let maximumAge: Duration = .seconds(5)

    init(dataSource: any VoltaDataSource, vehicleID: Int, surfaces: (any VehicleSurfaces)?,
         sentAt: ContinuousClock.Instant = .now) {
        self.vehicleID = vehicleID
        self.sentAt = sentAt
        issued = surfaces?.nextStatusToken()
        // Detached: a main-actor task would not start until the first frame is built.
        status = Task.detached(priority: .userInitiated) { try await dataSource.status(vehicleID: vehicleID) }
    }

    func cancel() { status.cancel() }

    func isUsable(for vehicleID: Int, now: ContinuousClock.Instant = .now) -> Bool {
        vehicleID == self.vehicleID && now - sentAt <= Self.maximumAge
    }

    /// `task`'s result; cancelling the waiter cancels the request.
    nonisolated static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
