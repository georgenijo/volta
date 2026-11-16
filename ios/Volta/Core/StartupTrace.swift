import Foundation
import QuartzCore
import os

/// Startup milestones, each logged once per process with the milliseconds
/// since the process started. `scripts/startup-fixture.py` benchmarks read
/// them from the simulator log (subsystem `com.georgenijo.volta`, category
/// `startup`); Instruments shows them as signpost events. Only milestone names
/// and durations are logged, never vehicle data.
///
/// Except `appModel`, each milestone is logged at the first display refresh
/// after it was reached: by then the frame built in that main-thread pass,
/// which shows it, has been committed. A state change alone is not a pixel.
enum StartupTrace {
    enum Milestone: String, Sendable {
        /// `AppModel` began initializing. Logged at once; the reference point.
        case appModel
        /// The root view's first frame was committed.
        case firstFrame
        /// A frame with the signed-in tab shell was committed.
        case shell
        /// `AppModel` has a vehicle list from the server.
        case vehicles
        /// A frame with the last saved status was committed.
        case cachedStatus
        /// A frame with status fetched in this process was committed.
        case status
        /// Every dashboard history section finished its first load and was committed.
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

    /// Marks `.firstFrame`. Call when the root view appears.
    @MainActor static func markFirstFrameAtNextRefresh() { mark(.firstFrame) }

    /// Logs `milestone` the first time this process reaches it, at the next
    /// display refresh (`appModel`: now).
    @MainActor static func mark(_ milestone: Milestone) {
        guard reached.insert(milestone).inserted else { return }
        if milestone == .appModel { log(milestone) } else { NextRefresh.shared.add(milestone) }
    }

    @MainActor fileprivate static func log(_ milestone: Milestone) {
        let elapsed = processStart.map { Int((Date.now.timeIntervalSince($0) * 1_000).rounded()) } ?? -1
        signposter.emitEvent("milestone", "\(milestone.rawValue, privacy: .public)")
        logger.notice("startup milestone=\(milestone.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)")
    }
}

/// A display link that runs only while milestones wait: its callback comes
/// after the frame built in the current main-thread pass has been committed.
@MainActor
private final class NextRefresh: NSObject {
    static let shared = NextRefresh()
    private var link: CADisplayLink?
    private var waiting: [StartupTrace.Milestone] = []

    func add(_ milestone: StartupTrace.Milestone) {
        waiting.append(milestone)
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refresh))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func refresh() {
        link?.invalidate(); link = nil
        let milestones = waiting
        waiting = []
        milestones.forEach(StartupTrace.log)
    }
}
