import Foundation

/// Deterministic demo trips for previews, the simulator demo and tests.
/// Coordinates follow a synthetic curve between public town centres; they are
/// not a recorded route.
enum TripFixtures {
    /// Demo drive shown densely sampled (every 3 s).
    static let denseDriveID = 1
    /// Demo drive reproducing the cached-collector pattern: 1,335 rows that hold
    /// only 5 distinct timestamps about 14 minutes apart, plus one conflicting row.
    static let sparseDriveID = 2
    /// Demo drive with dense GPS and power but long gaps in single signals:
    /// speed only in the first and last 5 minutes, elevation only at the two ends.
    static let signalGapDriveID = 3
    /// Demo drive with dense GPS and battery, speed and elevation recorded only
    /// every 120 s (missing on the samples between), and a single power reading.
    static let intermittentDriveID = 4
    /// Demo drive with dense GPS and battery whose speed, power and elevation
    /// are recorded only on the first two of every eight samples (12.5% of the
    /// trip covered), so most of the route must stay uncolored.
    static let alternatingDriveID = 5
    /// Demo drive with every signal dense except power, which is missing for
    /// the last 15% of the trip: regen is a partial estimate.
    static let partialPowerDriveID = 6

    static let sparseRawCount = 1335

    /// Adjusts the generated demo summary for the fixture drives so the list
    /// row and the detail agree.
    static func summary(_ base: DriveSummary) -> DriveSummary {
        switch base.id {
        case denseDriveID: dense(base).summary
        case sparseDriveID: sparse(base).summary
        case signalGapDriveID: signalGaps(base).summary
        case intermittentDriveID: intermittent(base).summary
        case alternatingDriveID: alternating(base).summary
        case partialPowerDriveID: partialPower(base).summary
        default: base
        }
    }

    static func detail(_ base: DriveSummary) -> DriveDetail? {
        switch base.id {
        case denseDriveID: dense(base)
        case sparseDriveID: sparse(base)
        case signalGapDriveID: signalGaps(base)
        case intermittentDriveID: intermittent(base)
        case alternatingDriveID: alternating(base)
        case partialPowerDriveID: partialPower(base)
        default: nil
        }
    }

    // MARK: Dense

    /// 49 min, ~33 km: town streets, a highway stretch, town streets. Speed
    /// follows target speeds with bounded acceleration; power comes from a simple
    /// road-load model; battery and elevation are integrated from those.
    static func dense(_ base: DriveSummary) -> DriveDetail {
        let dt = 3.0, duration = 49.0 * 60
        let steps = Int(duration / dt)
        let mass = 1900.0, packKwh = 75.0
        var v = 0.0, distance = 0.0, energyKwh = 0.0, regenKwh = 0.0, elevation = 38.0, gain = 0.0
        var rows: [(t: Double, v: Double, p: Double, e: Double, d: Double, used: Double)] = []
        for i in 0...steps {
            let t = Double(i) * dt
            let f = t / duration
            var target: Double
            switch f {
            case ..<0.32: target = 36 + 8 * sin(t / 40)
            case ..<0.50: target = 100 + 12 * sin(t / 90)
            default: target = 34 + 6 * sin(t / 35)
            }
            // Traffic lights / stop signs.
            for stop in [0.05, 0.10, 0.17, 0.24, 0.60, 0.68, 0.76, 0.83, 0.90] where abs(f - stop) < 0.012 { target = 0 }
            if i == steps || t < 6 { target = 0 }
            let targetMs = target / 3.6
            // One firm stop on the highway exit ramp, the rest gentle.
            let brake = abs(f - 0.505) < 0.004 ? 3.3 : 2.2
            let accel = max(-brake, min(1.8, (targetMs - v) / dt))
            let next = max(0, v + accel * dt)
            let mean = (v + next) / 2
            let slope = 0.012 * cos(t / 210)
            let inertia: Double = mass * accel * mean
            let drag: Double = 0.5 * 1.2 * 0.23 * 2.2 * pow(mean, 3)
            let rolling: Double = 0.009 * mass * 9.81 * mean
            let climb: Double = mass * 9.81 * slope * mean
            let road = inertia + drag + rolling + climb
            var powerKw = road / 1000 / 0.9 + (mean > 0.1 ? 0.6 : 0.35)
            if powerKw < 0 { powerKw = max(-60, powerKw * 0.75 * 0.9 * 0.9) }
            let rise = slope * mean * dt
            elevation += rise
            if rise > 0 { gain += rise }
            distance += mean * dt
            energyKwh += powerKw * dt / 3600
            if powerKw < 0 { regenKwh += -powerKw * dt / 3600 }
            rows.append((t, next * 3.6, powerKw, elevation, distance, energyKwh))
            v = next
        }
        let totalKm = distance / 1000
        let startLevel = 64.0
        let path = rows.map { r -> DrivePoint in
            let c = coordinate(fraction: r.d / distance)
            let power: Double = (r.p * 10).rounded() / 10
            let elevation: Double = (r.e * 10).rounded() / 10
            let level: Double = startLevel - r.used / packKwh * 100
            return DrivePoint(t: base.start.addingTimeInterval(r.t), latitude: c.lat, longitude: c.lon,
                              speedKph: r.v.rounded(), powerKw: power, elevationM: elevation,
                              batteryLevel: Int(level.rounded(.down)))
        }
        var summary = base
        summary.end = base.start.addingTimeInterval(duration)
        summary.durationMin = duration / 60
        summary.distanceKm = totalKm
        summary.startBatteryLevel = Int(startLevel)
        summary.endBatteryLevel = path.last?.batteryLevel
        summary.energyUsedKwh = energyKwh
        summary.efficiencyWhPerKm = energyKwh * 1000 / totalKm
        summary.maxSpeedKph = path.compactMap(\.speedKph).max()
        summary.avgSpeedKph = totalKm / (duration / 3600)
        summary.startAddress = "Palo Alto, CA"
        summary.endAddress = "Union City, CA"
        let telemetrySamples = path.enumerated().map { index, p in
            let slow = index.isMultiple(of: 20)
            let longitudinal = index > 0 ? path[index - 1].speedKph.flatMap { previous in
                p.speedKph.map { ($0 - previous) / 3.6 / dt }
            } : nil
            let lateral = index > 0 ? sin(Double(index) / 18) * 0.35 : nil
            return FleetTelemetrySample(
                t: p.t, latitude: p.latitude, longitude: p.longitude, speedKph: p.speedKph, powerKw: p.powerKw,
                elevationM: p.elevationM, batteryLevel: p.batteryLevel.map(Double.init),
                energyRemainingKwh: slow ? p.batteryLevel.map { Double($0) * packKwh / 100 } : nil,
                batteryTempMinC: slow ? 24 + 2 * Double(index) / Double(path.count) : nil,
                batteryTempMaxC: slow ? 30 + 3 * Double(index) / Double(path.count) : nil,
                insideTempC: slow ? 20.5 : nil, outsideTempC: slow ? 14.0 : nil,
                voltage: p.powerKw.map { _ in 390 }, currentA: p.powerKw.map { $0 * 1000 / 390 },
                ratedRangeKm: slow ? p.batteryLevel.map { Double($0) * 4.8 } : nil,
                longitudinalAccelerationMps2: longitudinal, lateralAccelerationMps2: lateral,
                routeBreakBefore: false
            )
        }
        let telemetry = FleetTelemetrySeries(source: "fleet_telemetry", samples: telemetrySamples, gaps: [], truncated: false)
        return DriveDetail(summary: summary, path: path, elevationGainM: gain, telemetry: telemetry)
    }

    // MARK: Sparse

    /// 56 minutes recorded as 5 distinct states, each repeated 267 times (1,335
    /// rows), with one extra row that conflicts with the third state's timestamp.
    static func sparse(_ base: DriveSummary) -> DriveDetail {
        let minutes = [0.0, 14, 28, 42, 56]
        let speeds: [Double?] = [0, 48, 64, 40, 0]
        let powers: [Double?] = [2.1, 14.0, 22.5, -8.0, 0.4]
        let elevations: [Double?] = [41, 55, 23, nil, 12]
        let battery: [Int?] = [64, 63, 61, 59, 58]
        let states = minutes.indices.map { i in
            let c = coordinate(fraction: 1 - minutes[i] / 56)
            return DrivePoint(t: base.start.addingTimeInterval(minutes[i] * 60), latitude: c.lat, longitude: c.lon,
                              speedKph: speeds[i], powerKw: powers[i], elevationM: elevations[i], batteryLevel: battery[i])
        }
        var rows: [DrivePoint] = []
        let repeats = (sparseRawCount - 1) / states.count + 1
        for state in states { rows.append(contentsOf: repeatElement(state, count: repeats)) }
        rows.removeLast(rows.count - (sparseRawCount - 1))
        var conflict = states[2]
        conflict.speedKph = 61
        rows.insert(conflict, at: rows.count / 2)

        var summary = base
        summary.end = base.start.addingTimeInterval(56 * 60)
        summary.durationMin = 56
        summary.distanceKm = 33.2
        summary.startBatteryLevel = 64
        summary.endBatteryLevel = 58
        // Samples are sparse, but the summary still carries the rated-range
        // estimate: 6% of a 75 kWh pack.
        summary.energyUsedKwh = 4.5
        summary.efficiencyWhPerKm = 4.5 * 1000 / 33.2
        summary.maxSpeedKph = 64
        summary.avgSpeedKph = 33.2 / (56.0 / 60)
        summary.startAddress = "Union City, CA"
        summary.endAddress = "Palo Alto, CA"
        return DriveDetail(summary: summary, path: rows, elevationGainM: 82)
    }

    // MARK: Signal gaps

    /// The dense drive with speed recorded only for its first and last 5 minutes
    /// and elevation only at the first and last sample. Position, power and
    /// battery stay dense, so only the per-signal views show gaps.
    static func signalGaps(_ base: DriveSummary) -> DriveDetail {
        let full = dense(base)
        let start = full.summary.start, end = full.path.last?.t ?? start
        let path = full.path.enumerated().map { i, p -> DrivePoint in
            var p = p
            let fromStart = p.t.timeIntervalSince(start), toEnd = end.timeIntervalSince(p.t)
            if fromStart > 5 * 60, toEnd > 5 * 60 { p.speedKph = nil }
            if i != 0, i != full.path.count - 1 { p.elevationM = nil }
            return p
        }
        var summary = full.summary
        summary.maxSpeedKph = nil
        return DriveDetail(summary: summary, path: path, elevationGainM: nil)
    }

    // MARK: Intermittent signals

    /// The dense drive with speed and elevation kept only on samples a whole
    /// 120 s from the start (nil on every sample between) and power kept only
    /// on the first sample. Each kept reading is isolated by explicit missing
    /// observations, so no chart line, descent, regen or exact max may form.
    static func intermittent(_ base: DriveSummary) -> DriveDetail {
        let full = dense(base)
        let start = full.summary.start
        let path = full.path.enumerated().map { i, p -> DrivePoint in
            var p = p
            let seconds = p.t.timeIntervalSince(start).rounded()
            if seconds.truncatingRemainder(dividingBy: 120) != 0 {
                p.speedKph = nil
                p.elevationM = nil
            }
            if i != 0 { p.powerKw = nil }
            return p
        }
        var summary = full.summary
        summary.maxSpeedKph = nil
        return DriveDetail(summary: summary, path: path, elevationGainM: nil)
    }

    // MARK: Alternating support

    /// The dense drive with speed, power and elevation kept only on the first
    /// two samples of each block of eight (nil on the other six). One interval
    /// in eight is supported, so 12.5% of the route may be colored.
    static func alternating(_ base: DriveSummary) -> DriveDetail {
        let full = dense(base)
        let path = full.path.enumerated().map { i, p -> DrivePoint in
            var p = p
            if i % 8 >= 2 {
                p.speedKph = nil
                p.powerKw = nil
                p.elevationM = nil
            }
            return p
        }
        var summary = full.summary
        summary.maxSpeedKph = nil
        return DriveDetail(summary: summary, path: path, elevationGainM: nil)
    }

    // MARK: Partial power

    /// The dense drive with power missing from 85% of the way through to the
    /// end. Regen is estimated from the recorded 85% and labelled partial.
    static func partialPower(_ base: DriveSummary) -> DriveDetail {
        let full = dense(base)
        let start = full.summary.start, cutoff = full.summary.durationMin * 60 * 0.85
        let path = full.path.map { p -> DrivePoint in
            var p = p
            if p.t.timeIntervalSince(start) > cutoff { p.powerKw = nil }
            return p
        }
        return DriveDetail(summary: full.summary, path: path, elevationGainM: full.elevationGainM)
    }

    // MARK: Route shape

    /// Smooth synthetic curve from Palo Alto centre towards Union City centre.
    private static func coordinate(fraction f: Double) -> (lat: Double, lon: Double) {
        let lat = 37.4419 + (37.6028 - 37.4419) * f + 0.012 * sin(f * .pi * 3)
        let lon = -122.1430 + (-122.0040 + 122.1430) * f + 0.018 * sin(f * .pi * 2) * (1 - f)
        return (lat, lon)
    }
}
