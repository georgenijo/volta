import Foundation

/// A derived trip number that is only shown when the samples support it.
enum TripMetric: Equatable, Sendable {
    /// Measured across (nearly) the whole trip.
    case value(Double)
    /// Measured across part of the trip; the true value is at least this.
    case atLeast(Double)
    /// Not shown; the reason is displayed instead.
    case unavailable(String)

    var number: Double? {
        switch self {
        case .value(let v), .atLeast(let v): v
        case .unavailable: nil
        }
    }
}

/// A number derived from samples under a stated assumption (for example
/// linear change between readings). It is an estimate, not a measurement and
/// not a bound: unsampled time could add to it or the assumption could
/// overstate it, so it is always shown as "≈" with how much of the trip the
/// samples cover.
enum TripEstimate: Equatable, Sendable {
    /// `coverage` is the fraction of the trip covered by the signal's intervals.
    case estimate(Double, coverage: Double)
    case unavailable(String)

    var number: Double? {
        if case .estimate(let v, _) = self { v } else { nil }
    }

    /// The estimate covers (nearly) the whole trip.
    var isComplete: Bool {
        if case .estimate(_, let coverage) = self { coverage >= TripAnalysis.completeCoverage } else { false }
    }
}

enum TripAnalysis {
    /// Coverage at which a sample-derived number is treated as covering the whole trip.
    static let completeCoverage = 0.99
    /// Minimum power coverage for a (partial) regen estimate.
    static let regenMinCoverage = 0.8

    /// Regen energy recovered: a sample-derived estimate, not a measurement.
    /// Over the power signal's own intervals only (both endpoints hold a finite
    /// power reading, so a reading followed by a missing one, a gap or the end
    /// of the trip contributes nothing), power is assumed to change linearly
    /// between the two readings and the negative part of that line is
    /// integrated (`regenKwh(from:to:seconds:)`). What the car did between
    /// readings is not known, so the result is neither exact nor a bound.
    /// Shown from 80% power coverage with the coverage disclosed, otherwise withheld.
    static func regen(_ timeline: TripTimeline) -> TripEstimate {
        let power = TripSignal(timeline) { $0.powerKw }
        switch power.observationCount {
        case 0: return .unavailable("Power not recorded")
        case 1: return .unavailable("Only one power sample")
        default: break
        }
        var kwh = 0.0
        for (i, j) in power.intervals {
            let dt = timeline.points[j].t.timeIntervalSince(timeline.points[i].t)
            guard let p0 = power.values[i], let p1 = power.values[j] else { continue }
            kwh += regenKwh(from: p0, to: p1, seconds: dt)
        }
        guard power.coverage >= regenMinCoverage else {
            return .unavailable("Power sampled for \(percent(power.coverage)) of the trip")
        }
        return .estimate(kwh, coverage: power.coverage)
    }

    /// Regen (kWh) over one interval whose power goes linearly from `p0` to
    /// `p1` kW in `seconds`: the area of the line's negative part. Both
    /// negative: a trapezoid. Both ≥ 0: nothing. A sign change: only the
    /// triangle on the negative side of the zero crossing, so −60 → +60 kW over
    /// 60 s is 0.25 kWh (not the 0.5 kWh of averaging clipped endpoints).
    static func regenKwh(from p0: Double, to p1: Double, seconds: TimeInterval) -> Double {
        guard seconds > 0, p0.isFinite, p1.isFinite else { return 0 }
        let r0 = -p0, r1 = -p1 // regen power, positive while regenerating
        let kwSeconds: Double
        if r0 >= 0, r1 >= 0 {
            kwSeconds = (r0 + r1) / 2 * seconds
        } else if r0 <= 0, r1 <= 0 {
            kwSeconds = 0
        } else {
            let peak = max(r0, r1)
            kwSeconds = peak * (peak / (abs(r0) + abs(r1)) * seconds) / 2
        }
        return kwSeconds / 3600
    }

    /// Elevation lost, from consecutive elevation samples inside the elevation
    /// signal's own segments, ignoring changes under `hysteresis` metres. The
    /// anchor resets at every elevation gap, so a drop is never inferred across
    /// unrecorded terrain. Exact at ≥ 99% elevation coverage, a lower bound from
    /// 90%, otherwise withheld (dense GPS alone is not enough).
    static func descent(_ timeline: TripTimeline, hysteresis: Double = 2) -> TripMetric {
        let signal = TripSignal(timeline) { $0.elevationM }
        switch signal.observationCount {
        case 0: return .unavailable("Elevation not recorded")
        case 1: return .unavailable("Only one elevation sample")
        default: break
        }
        guard signal.coverage >= 0.9 else {
            return .unavailable("Elevation sampled for \(percent(signal.coverage)) of the trip")
        }
        var total = 0.0
        for run in signal.segments {
            // Every member of a run has a value; the anchor starts afresh per run.
            var anchor = signal.values[run[0]]!
            for i in run.dropFirst() {
                let e = signal.values[i]!
                if e > anchor { anchor = e } else if anchor - e >= hysteresis { total += anchor - e; anchor = e }
            }
        }
        return signal.coverage >= 0.99 ? .value(total) : .atLeast(total)
    }

    /// The summary's max speed comes from the same samples, so unless speed
    /// itself is densely recorded (coverage from consecutive valid speeds, not
    /// GPS density) it is only a lower bound.
    static func maxSpeed(summary: Double?, timeline: TripTimeline) -> TripMetric {
        let speed = TripSignal(timeline) { $0.speedKph }
        let sampled = speed.values.compactMap { $0 }.max()
        guard let v = [summary.flatMap { $0.isFinite ? $0 : nil }, sampled].compactMap({ $0 }).max() else { return .unavailable("Not recorded") }
        return speed.isDense ? .value(v) : .atLeast(v)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Smoothness score

/// Volta Smoothness v1: Volta's own transparent measure of how gently a trip
/// was driven, computed from recorded speed (and power when present). It is not
/// an imitation of any other app's score and is not comparable to one.
///
/// - Observed interval: consecutive samples inside a segment, 0.5 s < Δt ≤ 6 s,
///   both speeds recorded and finite (standing still counts; a missing speed
///   does not).
/// - Eligible interval: an observed interval with mean speed > 5 km/h.
///   a = Δv / Δt (m/s²).
/// - Acceleration: share of accelerating time (a ≥ 0.5) with a ≤ 2.0 m/s².
/// - Braking: share of braking time (a ≤ −0.5) with |a| ≤ 2.5 m/s².
/// - Power: share of eligible time with |ΔP/Δt| ≤ 15 kW/s; only when power is
///   recorded for at least half of the eligible time.
/// - Score: mean of the available parts, 0–100.
/// - Hard events: runs of consecutive intervals with |a| ≥ 2.94 m/s² (0.3 g).
/// - Requires ≥ 70% of the trip covered by observed intervals and ≥ 120
///   eligible (moving) intervals.
struct SmoothnessScore: Equatable, Sendable {
    struct Part: Equatable, Sendable, Identifiable {
        var name: String
        var score: Double
        var id: String { name }
    }

    var score: Int
    var parts: [Part]
    var hardEvents: Int
    var maxG: Double
    var eligibleIntervals: Int

    static let maxInterval: TimeInterval = 6
    static let minInterval: TimeInterval = 0.5
    static let minCoverage = 0.7
    static let minIntervals = 120
    static let gentleAccel = 2.0, gentleBrake = 2.5, hardAccel = 0.3 * 9.80665, steadyPowerKwPerS = 15.0

    var label: String {
        switch score {
        case 85...: "Smooth"
        case 70..<85: "Steady"
        default: "Lively"
        }
    }

    enum Result: Equatable, Sendable {
        case score(SmoothnessScore)
        case unavailable(String)
    }

    static func evaluate(_ timeline: TripTimeline) -> Result {
        let speed = TripSignal(timeline) { $0.speedKph }
        let power = TripSignal(timeline) { $0.powerKw }
        var fineSeconds: TimeInterval = 0
        var accelTime = 0.0, gentleAccelTime = 0.0, brakeTime = 0.0, gentleBrakeTime = 0.0
        var eligibleTime = 0.0, powerTime = 0.0, steadyPowerTime = 0.0
        var eligible = 0, hard = 0, inHard = false, maxA = 0.0
        var previousEnd: Int?
        // Speed intervals: consecutive samples that both recorded a finite speed.
        for (i, j) in speed.intervals {
            if previousEnd != i { inHard = false }
            previousEnd = j
            let dt = timeline.points[j].t.timeIntervalSince(timeline.points[i].t)
            guard dt > minInterval, dt <= maxInterval, let v0 = speed.values[i], let v1 = speed.values[j] else { inHard = false; continue }
            fineSeconds += dt
            guard (v0 + v1) / 2 > 5 else { inHard = false; continue }
            eligible += 1
            eligibleTime += dt
            let acc = (v1 - v0) / 3.6 / dt
            maxA = max(maxA, abs(acc))
            if acc >= 0.5 { accelTime += dt; if acc <= gentleAccel { gentleAccelTime += dt } }
            if acc <= -0.5 { brakeTime += dt; if -acc <= gentleBrake { gentleBrakeTime += dt } }
            if abs(acc) >= hardAccel { if !inHard { hard += 1 }; inHard = true } else { inHard = false }
            if let p0 = power.values[i], let p1 = power.values[j] {
                powerTime += dt
                if abs(p1 - p0) / dt <= steadyPowerKwPerS { steadyPowerTime += dt }
            }
        }
        let coverage = timeline.spanSeconds > 0 ? fineSeconds / timeline.spanSeconds : 0
        guard coverage >= minCoverage else {
            return .unavailable("Needs speed recorded every ≤ \(Int(maxInterval)) s for ≥ \(TripAnalysis.percent(minCoverage)) of the trip; this trip has \(TripAnalysis.percent(coverage)).")
        }
        guard eligible >= minIntervals else {
            return .unavailable("Needs ≥ \(minIntervals) moving intervals of recorded speed; this trip has \(eligible).")
        }
        var parts = [
            Part(name: "Acceleration", score: accelTime > 0 ? 100 * gentleAccelTime / accelTime : 100),
            Part(name: "Braking", score: brakeTime > 0 ? 100 * gentleBrakeTime / brakeTime : 100),
        ]
        if powerTime >= eligibleTime / 2, powerTime > 0 {
            parts.append(Part(name: "Power", score: 100 * steadyPowerTime / powerTime))
        }
        let mean = parts.map(\.score).reduce(0, +) / Double(parts.count)
        return .score(SmoothnessScore(score: Int(mean.rounded()), parts: parts, hardEvents: hard,
                                      maxG: maxA / 9.80665, eligibleIntervals: eligible))
    }
}

// MARK: - Cost

/// Price per kWh used to cost a trip. Only from the user's own rate or from a
/// recorded charge cost in a recorded currency; never a default, an assumed
/// tariff or a display preference. Zero is a real price (free charging).
struct TripRate: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Set by the user on this device.
        case manual
        /// Cost ÷ energy added of the most recent priced charge before the trip.
        case previousCharge(place: String?, date: Date)
    }

    var perKwh: Double
    var currency: String
    var source: Source

    /// The most recent charge before `before` with a recorded cost (zero
    /// included) and positive energy added. Newest by start, then id.
    static func latestPriced(_ charges: [ChargeSummary], before: Date) -> ChargeSummary? {
        charges.filter { c in
            guard c.start < before, let cost = c.cost, cost.isFinite, cost >= 0,
                  let energy = c.energyAddedKwh, energy.isFinite, energy > 0 else { return false }
            return true
        }
        .max { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The rate of `charge`, or `.currencyUnknown` when its currency isn't a
    /// recorded ISO code. Never falls back to an older charge: the latest
    /// priced charge is the reference even when it was free.
    static func lookup(from charge: ChargeSummary) -> TripRateLookup {
        guard let cost = charge.cost, let energy = charge.energyAddedKwh, energy > 0 else { return .noPricedCharge }
        guard let currency = isoCurrency(charge.currency) else { return .currencyUnknown(date: charge.start) }
        return .found(TripRate(perKwh: cost / energy, currency: currency,
                               source: .previousCharge(place: charge.placeName ?? charge.address, date: charge.start)))
    }

    /// Pages through charges (newest first) until the latest priced charge
    /// before `before` is found, the history ends, or `maxPages` is reached.
    /// Stopping early (cap, error, cancellation, repeated cursor) is reported as
    /// incomplete, never as "no priced charge".
    static func lookup(before: Date, maxPages: Int = 5,
                       fetch: @Sendable (String?) async throws -> Page<ChargeSummary>) async -> TripRateLookup {
        var cursor: String?
        var seen = Set<String>()
        var checked = 0
        for _ in 0..<maxPages {
            if Task.isCancelled { return .incomplete("Lookup cancelled") }
            let page: Page<ChargeSummary>
            do { page = try await fetch(cursor) } catch {
                return .incomplete(checked == 0 ? "Couldn't load charges" : "Couldn't load charges past the latest \(checked)")
            }
            if Task.isCancelled { return .incomplete("Lookup cancelled") }
            if let charge = latestPriced(page.items, before: before) { return lookup(from: charge) }
            checked += page.items.count
            guard let next = page.nextCursor else { return .noPricedCharge }
            guard seen.insert(next).inserted else { return .incomplete("Charge history paging repeated") }
            cursor = next
        }
        return .incomplete("Checked the latest \(checked) charges")
    }

    /// Uppercased three-letter code, or nil.
    static func isoCurrency(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 3,
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return code
    }

    func cost(energyKwh: Double?) -> Double? {
        guard let energyKwh, energyKwh.isFinite, energyKwh >= 0 else { return nil }
        return energyKwh * perKwh
    }

    /// Encoded as "rate|currency" for UserDefaults.
    var stored: String { "\(perKwh)|\(currency)" }

    init(perKwh: Double, currency: String, source: Source) {
        self.perKwh = perKwh
        self.currency = currency
        self.source = source
    }

    /// Accepts any finite rate ≥ 0 (0 = free) and a three-letter currency.
    init?(stored: String) {
        let parts = stored.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let rate = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              rate.isFinite, rate >= 0, let currency = Self.isoCurrency(parts[1]) else { return nil }
        self.init(perKwh: rate == 0 ? 0 : rate, currency: currency, source: .manual)
    }

    /// UserDefaults key for the manual rate, scoped like other device-local
    /// values: per paired server (or demo) and vehicle. nil = don't persist.
    static func storageKey(serverURL: String, isDemo: Bool, isLaunchDemo: Bool, vehicleID: Int) -> String? {
        if isLaunchDemo { return nil }
        let scope = isDemo ? "demo" : AnalyticsMath.serverScope(serverURL)
        return "volta.trip.rate.\(scope).\(vehicleID)"
    }
}

/// Outcome of looking up the previous charge's price.
enum TripRateLookup: Equatable, Sendable {
    case found(TripRate)
    /// The latest priced charge before the trip has no recorded currency.
    case currencyUnknown(date: Date)
    /// The whole charge history before the trip was checked; none had a cost.
    case noPricedCharge
    /// The lookup stopped before it could tell (page cap, error, cancellation).
    case incomplete(String)

    var rate: TripRate? {
        if case .found(let rate) = self { rate } else { nil }
    }
}

/// Publishes one previous-charge lookup at a time. Every `load`/`reset` bumps
/// the generation, so an older lookup (another drive, vehicle or server, or an
/// earlier reload of the same drive) can never overwrite a newer one.
@MainActor @Observable
final class TripRateLoader {
    private(set) var result: TripRateLookup?
    private var generation = 0

    func load(before: Date, fetch: @escaping @Sendable (String?) async throws -> Page<ChargeSummary>) async {
        generation += 1
        let token = generation
        let outcome = await TripRate.lookup(before: before, fetch: fetch)
        guard token == generation, !Task.isCancelled else { return }
        result = outcome
    }

    func reset() {
        generation += 1
        result = nil
    }
}
