import Foundation

/// A drive's recorded path after normalization, plus an honest account of how
/// well it was sampled.
///
/// The collector can return the same position row many times (for example a
/// cached vehicle-data response logged on every poll), rows that share a
/// timestamp but disagree, and long stretches with no rows at all. Charts,
/// the route and every integrated metric read this type instead of the raw
/// path so that:
/// - identical rows collapse to one sample (counted, not hidden);
/// - rows that share a timestamp but differ resolve to one canonical row,
///   independent of input order, and the conflict is counted for disclosure;
/// - intervals longer than `gapThreshold` split the path into segments. No
///   line, area or integral crosses a gap.
struct TripTimeline: Equatable, Sendable {
    /// Intervals longer than this are gaps: nothing is drawn or integrated across them.
    static let gapThreshold: TimeInterval = 120

    enum Quality: String, Equatable, Sendable {
        /// ≥ 90% of the trip lies inside sampled intervals.
        case dense
        /// 50–90%.
        case partial
        /// Under 50%, or fewer than two distinct samples.
        case sparse
        /// No samples.
        case none
    }

    /// Reference time for elapsed minutes (the drive start when known).
    let origin: Date
    /// Distinct samples, sorted by time.
    let points: [DrivePoint]
    /// Index ranges into `points`; consecutive samples within a segment are at most `gapThreshold` apart.
    let segments: [Range<Int>]
    let rawCount: Int
    /// Rows that exactly repeated another row.
    let duplicatesRemoved: Int
    /// Timestamps with more than one distinct row; one was kept deterministically.
    let conflictingTimestamps: Int
    /// Rows discarded because another row at the same timestamp was preferred.
    let conflictingRowsDropped: Int
    /// Seconds covered by intervals no longer than `gapThreshold`.
    let coveredSeconds: TimeInterval
    /// Trip length used as the coverage denominator.
    let spanSeconds: TimeInterval
    let longestGap: TimeInterval
    let medianInterval: TimeInterval?

    var gapCount: Int { max(0, segments.count - 1) }
    var coverage: Double { spanSeconds > 0 ? min(1, coveredSeconds / spanSeconds) : 0 }
    var totalMinutes: Double { spanSeconds / 60 }

    var quality: Quality {
        if points.isEmpty { return .none }
        if points.count < 2 { return .sparse }
        if coverage >= 0.9 { return .dense }
        if coverage >= 0.5 { return .partial }
        return .sparse
    }

    init(path: [DrivePoint], start: Date? = nil, end: Date? = nil) {
        rawCount = path.count
        // Group rows by exact timestamp. Grouping (rather than relying on
        // input order) makes the result independent of how rows arrive.
        var groups: [Date: [DrivePoint]] = [:]
        for p in path { groups[p.t, default: []].append(p) }
        var kept: [DrivePoint] = []
        kept.reserveCapacity(groups.count)
        var duplicates = 0, conflicts = 0, dropped = 0
        for (_, rows) in groups {
            let distinct = Array(Set(rows))
            duplicates += rows.count - distinct.count
            if distinct.count > 1 {
                conflicts += 1
                dropped += distinct.count - 1
            }
            kept.append(distinct.min(by: TripTimeline.preferred)!)
        }
        kept.sort { $0.t < $1.t }
        points = kept
        duplicatesRemoved = duplicates
        conflictingTimestamps = conflicts
        conflictingRowsDropped = dropped

        var segs: [Range<Int>] = []
        var covered: TimeInterval = 0, longest: TimeInterval = 0
        var intervals: [TimeInterval] = []
        var segStart = 0
        for i in kept.indices.dropFirst() {
            let dt = kept[i].t.timeIntervalSince(kept[i - 1].t)
            intervals.append(dt)
            if dt > Self.gapThreshold || kept[i].routeBreakBefore == true {
                segs.append(segStart..<i)
                segStart = i
                longest = max(longest, dt)
            } else {
                covered += dt
            }
        }
        if !kept.isEmpty { segs.append(segStart..<kept.count) }
        segments = segs
        coveredSeconds = covered
        intervals.sort()
        medianInterval = intervals.isEmpty ? nil : intervals[intervals.count / 2]

        let first = kept.first?.t, last = kept.last?.t
        let origin = start ?? first ?? Date(timeIntervalSince1970: 0)
        self.origin = origin
        let finish = [end, last].compactMap { $0 }.max() ?? origin
        spanSeconds = max(0, finish.timeIntervalSince(origin))
        // Lead-in and tail outside the samples count as gaps too.
        var edges: [TimeInterval] = []
        if let first { edges.append(first.timeIntervalSince(origin)) }
        if let last { edges.append(finish.timeIntervalSince(last)) }
        longestGap = max(longest, edges.filter { $0 > Self.gapThreshold }.max() ?? 0)
    }

    /// Strict ordering used to pick one row among conflicting rows at the same
    /// timestamp: the row with more recorded fields wins, then the
    /// lexicographically smallest value tuple. Total and input-order independent.
    static func preferred(_ a: DrivePoint, _ b: DrivePoint) -> Bool {
        let fa = a.recordedFieldCount, fb = b.recordedFieldCount
        if fa != fb { return fa > fb }
        return a.sortKey.lexicographicallyPrecedes(b.sortKey)
    }

    func elapsedMinutes(_ p: DrivePoint) -> Double { p.t.timeIntervalSince(origin) / 60 }

    /// Index of the sample nearest `minute`, or nil when `minute` falls inside a gap
    /// (more than half the gap threshold from any sample).
    func sampleIndex(atMinute minute: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        let target = origin.addingTimeInterval(minute * 60)
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < target { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { points.indices.contains($0) }
        guard let best = candidates.min(by: { abs(points[$0].t.timeIntervalSince(target)) < abs(points[$1].t.timeIntervalSince(target)) })
        else { return nil }
        return abs(points[best].t.timeIntervalSince(target)) <= Self.gapThreshold / 2 ? best : nil
    }

    /// Consecutive sample pairs that lie inside a segment (never across a gap).
    var sampledPairs: [(DrivePoint, DrivePoint)] {
        segments.flatMap { seg in zip(points[seg], points[seg].dropFirst()).map { ($0, $1) } }
    }

    /// Elapsed-minute ranges with no samples (between segments, plus lead-in/tail).
    var gapRanges: [ClosedRange<Double>] {
        guard let first = points.first, let last = points.last else { return spanSeconds > 0 ? [0...totalMinutes] : [] }
        var result: [ClosedRange<Double>] = []
        if first.t.timeIntervalSince(origin) > Self.gapThreshold { result.append(0...elapsedMinutes(first)) }
        for (a, b) in zip(segments, segments.dropFirst()) {
            result.append(elapsedMinutes(points[a.upperBound - 1])...elapsedMinutes(points[b.lowerBound]))
        }
        let tail = spanSeconds - last.t.timeIntervalSince(origin)
        if tail > Self.gapThreshold { result.append(elapsedMinutes(last)...totalMinutes) }
        return result
    }
}

/// One recorded metric (speed, power, elevation or battery) along the timeline.
///
/// Dense GPS says nothing about the other signals: a drive can have a position
/// every 3 s and an elevation only at the start and end. Each signal therefore
/// has its own segments, coverage and gaps. A segment is a run of *consecutive*
/// timeline samples that all have a valid (finite) value, inside one position
/// segment. A sample whose value is nil or non-finite is an explicit missing
/// observation: it ends the run even when the valid values around it are close
/// in time, so a signal recorded every 120 s on a 3 s GPS track is a string of
/// lone samples, not a line. Only intervals between two consecutive valid
/// samples count as covered. Nothing is drawn, integrated, compared or
/// interpolated between segments, and every derived trip metric (descent,
/// regen, max-speed bounds, smoothness, route colour) uses these intervals.
struct TripSignal: Equatable, Sendable {
    /// Per timeline sample: the finite value, or nil when not recorded.
    let values: [Double?]
    /// Runs of timeline indices that have a value.
    let segments: [[Int]]
    /// Seconds spanned by `intervals`.
    let coveredSeconds: TimeInterval
    /// Same denominator as the timeline: the whole trip.
    let spanSeconds: TimeInterval
    /// Elapsed-minute ranges without this signal (between segments, lead-in, tail).
    let gapRanges: [ClosedRange<Double>]

    var observationCount: Int { segments.reduce(0) { $0 + $1.count } }
    var coverage: Double { spanSeconds > 0 ? min(1, coveredSeconds / spanSeconds) : 0 }
    /// Same bar as `TripTimeline.Quality.dense`.
    var isDense: Bool { observationCount >= 2 && coverage >= 0.9 }

    init(_ timeline: TripTimeline, value: (DrivePoint) -> Double?) {
        let points = timeline.points
        let values = points.map { value($0).flatMap { $0.isFinite ? $0 : nil } }
        var segs: [[Int]] = []
        var covered: TimeInterval = 0
        for seg in timeline.segments {
            var run: [Int] = []
            for i in seg {
                // An explicit missing observation ends the run; it is never skipped over.
                guard values[i] != nil else {
                    if !run.isEmpty { segs.append(run); run = [] }
                    continue
                }
                // Consecutive samples of a position segment are ≤ gapThreshold apart.
                if let last = run.last { covered += points[i].t.timeIntervalSince(points[last].t) }
                run.append(i)
            }
            if !run.isEmpty { segs.append(run) }
        }
        self.values = values
        segments = segs
        coveredSeconds = covered
        spanSeconds = timeline.spanSeconds

        var gaps: [ClosedRange<Double>] = []
        if let first = segs.first?.first, let last = segs.last?.last {
            let firstMinute = timeline.elapsedMinutes(points[first]), lastMinute = timeline.elapsedMinutes(points[last])
            // Lead-in/tail: unrecorded when earlier/later samples lack this
            // signal, or when they lie beyond the timeline's own gap threshold.
            if firstMinute > 0, first > 0 || firstMinute * 60 > TripTimeline.gapThreshold { gaps.append(0...firstMinute) }
            for (a, b) in zip(segs, segs.dropFirst()) {
                gaps.append(timeline.elapsedMinutes(points[a.last!])...timeline.elapsedMinutes(points[b.first!]))
            }
            let tail = timeline.totalMinutes - lastMinute
            if tail > 0, last < points.count - 1 || tail * 60 > TripTimeline.gapThreshold { gaps.append(lastMinute...timeline.totalMinutes) }
        } else if timeline.totalMinutes > 0 {
            gaps.append(0...timeline.totalMinutes)
        }
        gapRanges = gaps
    }

    /// Consecutive valid sample pairs (timeline indices) inside this signal's
    /// segments: the only intervals any metric may integrate or difference.
    var intervals: [(Int, Int)] {
        segments.flatMap { run in zip(run, run.dropFirst()).map { ($0, $1) } }
    }

    func value(at index: Int?) -> Double? {
        guard let index, values.indices.contains(index) else { return nil }
        return values[index]
    }
}

extension DrivePoint {
    fileprivate var recordedFieldCount: Int {
        [speedKph, powerKw, elevationM, batteryLevel.map(Double.init)].count { $0 != nil }
            + (routeBreakBefore == true ? 1 : 0)
    }

    /// Nil sorts first; values compare numerically.
    fileprivate var sortKey: [Double] {
        [latitude, longitude, speedKph ?? -.infinity, powerKw ?? -.infinity,
         elevationM ?? -.infinity, batteryLevel.map(Double.init) ?? -.infinity,
         routeBreakBefore == true ? 1 : 0]
    }
}
