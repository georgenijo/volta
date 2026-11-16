import Foundation

/// Consumption for colouring a single drive's route, averaged over a rolling
/// distance window (`windowKm(forTripKm:)`) so the line reads as stretches of road rather than
/// per-sample noise. Only the line colour uses it: every number shown stays
/// the raw recorded value.
///
/// A window lives inside one recorded run: consecutive intervals in the same
/// position segment where speed and power were recorded at both ends. It never
/// spans a position gap or a stretch where the metric wasn't recorded, so
/// callers window each run on its own.
enum EfficiencyWindow {
    /// The window scales with the trip: a twelfth of its recorded length,
    /// at least 400 m and at most 2 km, so the line reads as stretches of road
    /// at the scale the whole trip is shown. Chosen once per trip, not per zoom.
    static let minimumKm = 0.4
    static let maximumKm = 2.0

    static func windowKm(forTripKm km: Double) -> Double {
        guard km.isFinite, km > 0 else { return minimumKm }
        return min(maximumKm, max(minimumKm, km / 12))
    }

    /// One recorded interval between two samples.
    struct Interval: Equatable, Sendable {
        var distanceKm: Double
        var energyKwh: Double
    }

    /// The interval from `a` to `b`, by the trapezoid rule over time: mean
    /// speed and mean power times the elapsed time. Nil when either end lacks
    /// a finite speed or power.
    static func interval(_ a: DrivePoint, _ b: DrivePoint) -> Interval? {
        guard let s0 = a.speedKph, let s1 = b.speedKph, let p0 = a.powerKw, let p1 = b.powerKw,
              s0.isFinite, s1.isFinite, p0.isFinite, p1.isFinite else { return nil }
        let hours: Double = max(0, b.t.timeIntervalSince(a.t)) / 3600
        let distance: Double = (s0 + s1) / 2 * hours
        let energy: Double = (p0 + p1) / 2 * hours
        return Interval(distanceKm: max(0, distance), energyKwh: energy)
    }

    /// Wh/km for each interval of one recorded run, over a window of
    /// `windowKm` centred on the interval's midpoint. Near either end the
    /// window shrinks symmetrically so it stays centred; a run shorter than
    /// the window uses the whole run. Negative values are regeneration.
    /// Nil only where the run covers no distance.
    static func smoothed(_ run: [Interval], windowKm: Double = minimumKm) -> [Double?] {
        guard !run.isEmpty else { return [] }
        // Cumulative distance and energy at each interval boundary.
        var distance: [Double] = [0]
        var energy: [Double] = [0]
        distance.reserveCapacity(run.count + 1)
        energy.reserveCapacity(run.count + 1)
        for interval in run {
            distance.append(distance[distance.count - 1] + interval.distanceKm)
            energy.append(energy[energy.count - 1] + interval.energyKwh)
        }
        let total: Double = distance[distance.count - 1]
        guard total > 0 else { return run.map { _ in nil } }
        if total <= windowKm {
            let whole: Double = energy[energy.count - 1] * 1000 / total
            return run.map { _ in whole }
        }

        let half: Double = windowKm / 2
        return run.indices.map { i -> Double? in
            let centre: Double = (distance[i] + distance[i + 1]) / 2
            let reach: Double = min(half, centre, total - centre)
            var lo: Double = centre - reach, hi: Double = centre + reach
            if hi - lo < 1e-9 {
                // Zero-length window at the very end: the interval itself.
                lo = distance[i]; hi = distance[i + 1]
            }
            guard hi - lo > 1e-9 else { return nil }
            let used: Double = energyAt(hi, distance, energy) - energyAt(lo, distance, energy)
            return used * 1000 / (hi - lo)
        }
    }

    /// Cumulative energy at distance `x` along the run, linear within an interval.
    private static func energyAt(_ x: Double, _ distance: [Double], _ energy: [Double]) -> Double {
        if x <= 0 { return 0 }
        let last: Int = distance.count - 1
        if x >= distance[last] { return energy[last] }
        // First boundary at or beyond x.
        var lo = 0, hi = last
        while lo < hi {
            let mid = (lo + hi) / 2
            if distance[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        let a: Int = max(0, lo - 1)
        let span: Double = distance[lo] - distance[a]
        guard span > 0 else { return energy[lo] }
        let f: Double = (x - distance[a]) / span
        return energy[a] + (energy[lo] - energy[a]) * f
    }
}
