import Foundation
import Observation
import QuartzCore
import os

/// Whether this process has put its first frame on screen. Views not needed
/// to read the screen (the dashboard's MapKit backdrop) wait for it, so they
/// never hold up the first frame. True for every later mount.
@MainActor @Observable
final class LaunchFrame {
    static let shared = LaunchFrame()
    /// Xcode previews have no app root to report a frame, so they start shown.
    private(set) var isShown = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    fileprivate func markShown() { isShown = true }
}

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
        /// A frame with the last saved status was committed. Not logged when
        /// fresh status replaced it before any frame showed it.
        case cachedStatus
        /// A frame with status fetched in this process was committed.
        case status
        /// Every dashboard history section finished its first load and was committed.
        case sections
        /// A frame with the dashboard's above-fold content filled in
        /// (status, battery, Now card, dock), saved or fresh, was committed.
        case aboveFold
        /// The single-column dashboard's below-fold sections (metric cards,
        /// activity strip, summaries), which wait for the first frame, were committed.
        case belowFold
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
    @MainActor private static var logged: Set<Milestone> = []
    /// Milestones that may not be logged before another one: key waits for value.
    @MainActor private static var holds: [Milestone: Milestone] = [:]
    /// Milestones reached while held, by the milestone they wait for.
    @MainActor private static var heldBack: [Milestone: [Milestone]] = [:]

    /// Marks `.firstFrame`. Call when the root view appears.
    @MainActor static func markFirstFrameAtNextRefresh() { mark(.firstFrame) }

    /// Logs `milestone` the first time this process reaches it, at the next
    /// display refresh (`appModel`: now).
    @MainActor static func mark(_ milestone: Milestone) {
        guard reached.insert(milestone).inserted else { return }
        if milestone == .appModel { log(milestone) } else { NextRefresh.shared.add(milestone) }
    }

    /// Logs `milestone` no earlier than `prerequisite`: a frame that shows
    /// sections the screen has not mounted yet does not show them. Call
    /// before `milestone` is logged; a prerequisite already logged is no hold.
    @MainActor static func hold(_ milestone: Milestone, until prerequisite: Milestone) {
        guard !logged.contains(milestone), !logged.contains(prerequisite) else { return }
        holds[milestone] = prerequisite
    }

    /// Drops `milestone` if it is still waiting for a display refresh: a
    /// saved status replaced before any frame showed it was never visible.
    @MainActor static func supersede(_ milestone: Milestone) {
        NextRefresh.shared.drop(milestone)
    }

    @MainActor fileprivate static func log(_ milestone: Milestone) {
        if let prerequisite = holds[milestone], !logged.contains(prerequisite) {
            heldBack[prerequisite, default: []].append(milestone)
            return
        }
        logged.insert(milestone)
        let elapsed = processStart.map { Int((Date.now.timeIntervalSince($0) * 1_000).rounded()) } ?? -1
        signposter.emitEvent("milestone", "\(milestone.rawValue, privacy: .public)")
        logger.notice("startup milestone=\(milestone.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)")
        // Reached earlier, so already in the frame this milestone committed.
        heldBack.removeValue(forKey: milestone)?.forEach(log)
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

    func drop(_ milestone: StartupTrace.Milestone) {
        waiting.removeAll { $0 == milestone }
    }

    @objc private func refresh() {
        link?.invalidate(); link = nil
        let milestones = waiting
        waiting = []
        milestones.forEach(StartupTrace.log)
        if milestones.contains(.firstFrame) { LaunchFrame.shared.markShown() }
    }
}
