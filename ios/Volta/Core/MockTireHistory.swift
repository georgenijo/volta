import Foundation

/// Synthetic tyre pressure history for demo mode and previews: about thirteen
/// months of daily buckets, a seasonal swing (lower in winter), a top-up four
/// months ago, a five-day stretch with no readings, and a slow leak in the rear
/// left over the last six weeks that ends at the demo's current 2.3 bar.
/// Generated, not recorded.
extension MockDataSource {
    /// Screenshot aid (DEBUG): `-demoTireMissingWheel YES` gives the rear right
    /// sensor no readings, as when a sensor has failed or was never paired.
    static var tireMissingWheel: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demoTireMissingWheel")
        #else
        false
        #endif
    }

    /// Screenshot aid (DEBUG): `-demoTireHistoryEmpty YES` returns no readings,
    /// as a server whose TeslaMate never recorded tire pressures would.
    static var tireHistoryEmpty: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demoTireHistoryEmpty")
        #else
        false
        #endif
    }

    static let tireHistoryDays = 390

    func tireHistory(vehicleID: Int, range: DateRange) async throws -> TirePressureHistory {
        guard vehicleID == Self.vehicleID else { throw VoltaError.notFound }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let end = range.to ?? now
        var wheels = TirePressureHistory.Wheels(fl: [], fr: [], rl: [], rr: [])
        if !empty, !Self.tireHistoryEmpty {
            for daysAgo in stride(from: Self.tireHistoryDays, through: 0, by: -1) {
                // Parked away with the car asleep: no readings at all.
                if (61...65).contains(daysAgo) { continue }
                guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today), day < end,
                      range.from.map({ calendar.date(byAdding: .day, value: 1, to: day)! > $0 }) ?? true else { continue }
                // The leak: from the axle's pressure down to 2.3 bar today.
                let leak = daysAgo < 42 ? -0.6 * Double(42 - daysAgo) / 42 : 0
                var day4: [TireWheel: TirePressureHistory.Point] = [
                    .fl: Self.tirePoint(day: day, daysAgo: daysAgo, base: 2.95, seed: 1, calendar: calendar),
                    .fr: Self.tirePoint(day: day, daysAgo: daysAgo, base: 2.95, seed: 2, calendar: calendar),
                    .rl: Self.tirePoint(day: day, daysAgo: daysAgo, base: 2.9 + leak, seed: 3, calendar: calendar),
                ]
                if !Self.tireMissingWheel {
                    day4[.rr] = Self.tirePoint(day: day, daysAgo: daysAgo, base: 2.85, seed: 4, calendar: calendar)
                }
                // Same-moment comparison, as the server computes it: each
                // wheel's mean against the others' over the shared readings.
                for (wheel, point) in day4 {
                    let others = day4.filter { $0.key != wheel }.map(\.value)
                    guard others.count >= 2 else { continue }
                    let othersBar = others.map(\.avgBar).reduce(0, +) / Double(others.count)
                    var p = point
                    p.peerReadings = ([point] + others).map(\.readings).min()
                    p.peerBar = othersBar
                    p.peerDeltaBar = point.avgBar - othersBar
                    p.peerWheels = others.count
                    wheels[wheel].append(p)
                }
            }
        }
        let all = [wheels.fl, wheels.fr, wheels.rl, wheels.rr].flatMap { $0 }
        let span = end.timeIntervalSince(range.from ?? all.map(\.firstAt).min() ?? end)
        return TirePressureHistory(bucket: span > 400 * 86_400 ? .week : .day, timeZone: calendar.timeZone.identifier,
                                   from: range.from, to: end, firstReadingAt: all.map(\.firstAt).min(),
                                   lastReadingAt: all.map(\.lastAt).max(), wheels: wheels)
    }

    /// One day's readings: the cold morning low, warmer after driving. Lows and
    /// highs are rounded to TeslaMate's 0.1 bar; the mean is not.
    private static func tirePoint(day: Date, daysAgo: Int, base: Double, seed: Double, calendar: Calendar) -> TirePressureHistory.Point {
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: day) ?? 1)
        // Warmest in late July, coldest in late January.
        let seasonal = 0.14 * cos(2 * .pi * (dayOfYear - 205) / 365)
        // Topped up 120 days ago; pressure had crept down before it.
        let topUp = daysAgo > 120 ? -0.12 * Double(min(daysAgo - 120, 90)) / 90 : 0
        let noise = 0.025 * sin(Double(daysAgo) * 0.21 + seed * 1.3)
        let cold = base + seasonal + topUp + noise
        let low = (cold * 10).rounded() / 10, high = ((cold + 0.22) * 10).rounded() / 10
        let readings = 140 + Int(abs(sin(Double(daysAgo) * 0.9 + seed)) * 260)
        return TirePressureHistory.Point(start: day, minBar: low, avgBar: cold + 0.09, maxBar: max(high, low), readings: readings,
                                         firstAt: day.addingTimeInterval(7 * 3600), lastAt: day.addingTimeInterval(19 * 3600))
    }
}
