import CryptoKit
import Foundation

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

    /// `status`, marked so screens label it as saved rather than live.
    var labelledStatus: VehicleStatus {
        var status = status
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
    /// Writes and removals run in order, off the main thread.
    private var lastWrite: Task<Void, Never>?

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory
            .appending(path: "Volta", directoryHint: .isDirectory)
            .appending(path: "saved-dashboard.json")
    }

    func read(backend: String) -> SavedDashboard? {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedDashboard.self, from: data),
              saved.version == SavedDashboard.currentVersion, saved.backend == backend else { return nil }
        return saved
    }

    func write(_ dashboard: SavedDashboard) {
        guard dashboard.backend == acceptedBackend else { return }
        let url = url, previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(dashboard) else { return }
            Self.prepareDirectory(url.deletingLastPathComponent())
            // A failed write only costs the next launch its instant dashboard.
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    func remove() {
        let url = url, previous = lastWrite
        // Remove now too: a launch right after unpairing must not find it.
        try? FileManager.default.removeItem(at: url)
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Waits for queued writes (tests).
    func drain() async { await lastWrite?.value }

    nonisolated private static func prepareDirectory(_ directory: URL) {
        var directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
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

    init(vehicles: (@MainActor @Sendable () async -> [Vehicle]?)? = nil, saved: SavedDashboard? = nil,
         store: (any SavedDashboardStoring)? = nil, backend: String? = nil) {
        self.vehicles = vehicles; self.saved = saved; self.store = store; self.backend = backend
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
