import Foundation
import os

/// Startup milestones, each logged once per process with the milliseconds
/// since the process started. `scripts/startup-fixture.py` benchmarks read
/// them from the simulator log (subsystem `com.georgenijo.volta`, category
/// `startup`); Instruments shows them as signpost events. Only milestone names
/// and durations are logged, never vehicle data.
enum StartupTrace {
    enum Milestone: String, Sendable {
        /// `AppModel` began initializing.
        case appModel
        /// The first frame of the root view was committed.
        case firstFrame
        /// The signed-in tab shell appeared.
        case shell
        /// `AppModel` has a vehicle list from the server.
        case vehicles
        /// The dashboard shows the last saved status while fresh data loads.
        case cachedStatus
        /// The dashboard shows status fetched in this process.
        case status
        /// Every dashboard history section finished its first load.
        case sections
    }

    static let logger = Logger(subsystem: "com.georgenijo.volta", category: "startup")
    private static let signposter = OSSignposter(logger: logger)
    /// Wall-clock start of this process, from the kernel.
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
    @MainActor private static var reached: Set<Milestone> = []

    /// Logs `milestone` the first time this process reaches it.
    @MainActor static func mark(_ milestone: Milestone) {
        guard reached.insert(milestone).inserted else { return }
        let elapsed = processStart.map { Int((Date.now.timeIntervalSince($0) * 1_000).rounded()) } ?? -1
        signposter.emitEvent("milestone", "\(milestone.rawValue, privacy: .public)")
        logger.notice("startup milestone=\(milestone.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)")
    }
}
