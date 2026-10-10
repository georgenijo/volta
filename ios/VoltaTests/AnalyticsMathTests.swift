import XCTest
@testable import Volta

final class AnalyticsMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func drive(_ km: Double, _ kwh: Double?) -> DriveSummary {
        DriveSummary(id: Int.random(in: 1...1_000_000), start: t0, end: nil, startAddress: nil, endAddress: nil,
                     distanceKm: km, durationMin: 10, startBatteryLevel: nil, endBatteryLevel: nil,
                     energyUsedKwh: kwh, efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
    }

    private func charge(added: Double?, cost: Double?, currency: String?) -> ChargeSummary {
        ChargeSummary(id: Int.random(in: 1...1_000_000), start: t0, end: nil, address: nil, placeName: nil,
                      energyAddedKwh: added, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                      durationMin: 30, maxPowerKw: nil, fastCharger: false, cost: cost, currency: currency, outsideTempAvgC: nil)
    }

    // 1. Unknown energy/cost stays unknown; efficiency uses only measured drives.
    func testTotalsKeepUnknownsUnknown() {
        let totals = AnalyticsMath.totals(drives: [drive(100, 15), drive(50, nil)],
                                          charges: [charge(added: nil, cost: nil, currency: nil)], fallbackCurrency: "USD")
        XCTAssertEqual(totals.distanceKm, 150)
        XCTAssertEqual(totals.energyUsedKwh, 15)
        XCTAssertEqual(try XCTUnwrap(totals.efficiencyWhPerKm), 150, accuracy: 0.0001) // 15 kWh / 100 km, not / 150 km
        XCTAssertNil(totals.energyAddedKwh)
        XCTAssertTrue(totals.costs.isEmpty)
        XCTAssertNil(totals.singleCost)

        let none = AnalyticsMath.totals(drives: [drive(10, nil)], charges: [], fallbackCurrency: "USD")
        XCTAssertNil(none.energyUsedKwh)
        XCTAssertNil(none.efficiencyWhPerKm)
    }

    // 7. Costs are grouped by currency, never summed across currencies.
    func testCostsGroupedByCurrency() {
        let charges = [charge(added: 10, cost: 5, currency: "USD"), charge(added: 10, cost: 2, currency: nil),
                       charge(added: 10, cost: 4, currency: "EUR"), charge(added: 10, cost: nil, currency: "EUR")]
        let totals = AnalyticsMath.totals(drives: [], charges: charges, fallbackCurrency: "USD")
        XCTAssertEqual(totals.costs, [.init(currency: "USD", amount: 7), .init(currency: "EUR", amount: 4)])
        XCTAssertNil(totals.singleCost)
        XCTAssertEqual(totals.energyAddedKwh, 40)

        let single = AnalyticsMath.totals(drives: [], charges: [charge(added: 1, cost: 3, currency: "EUR")], fallbackCurrency: "USD")
        XCTAssertEqual(single.singleCost, .init(currency: "EUR", amount: 3))
    }

    // 2. Selection finds the bucket whose interval contains the date, regardless of local midnight.
    func testMileageBucketContainment() {
        let utc = AnalyticsMath.utcCalendar
        let day1 = utc.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let day2 = utc.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let day5 = utc.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let buckets = [MileageBucket(start: day5, distanceKm: 3, driveCount: 1, energyUsedKwh: nil),
                       MileageBucket(start: day1, distanceKm: 1, driveCount: 1, energyUsedKwh: nil),
                       MileageBucket(start: day2, distanceKm: 2, driveCount: 1, energyUsedKwh: nil)]
        XCTAssertEqual(AnalyticsMath.bucket(containing: day1.addingTimeInterval(13 * 3600), in: buckets, size: .day)?.start, day1)
        XCTAssertEqual(AnalyticsMath.bucket(containing: day2, in: buckets, size: .day)?.start, day2)
        XCTAssertEqual(AnalyticsMath.bucket(containing: day5.addingTimeInterval(86_399), in: buckets, size: .day)?.start, day5)
        XCTAssertNil(AnalyticsMath.bucket(containing: day2.addingTimeInterval(2 * 86_400), in: buckets, size: .day)) // gap day
        XCTAssertNil(AnalyticsMath.bucket(containing: day1.addingTimeInterval(-1), in: buckets, size: .day))
        XCTAssertNil(AnalyticsMath.bucket(containing: day5.addingTimeInterval(86_400), in: buckets, size: .day))
    }

    // 4. Warranty: unknown unless both limits are known; any exceeded known limit is expired.
    func testCoverageStatus() {
        let now = t0
        let recent = now.addingTimeInterval(-365 * 86_400)
        let old = now.addingTimeInterval(-5 * 365.25 * 86_400)
        func status(_ purchase: Date?, _ km: Double?) -> AnalyticsMath.CoverageStatus {
            AnalyticsMath.coverageStatus(purchaseDate: purchase, odometerKm: km, years: 4, limitKm: 80_000, now: now)
        }
        XCTAssertEqual(status(recent, 10_000), .active)
        XCTAssertEqual(status(nil, 10_000), .unknown)
        XCTAssertEqual(status(recent, nil), .unknown)
        XCTAssertEqual(status(nil, nil), .unknown)
        XCTAssertEqual(status(nil, 90_000), .expired)
        XCTAssertEqual(status(old, nil), .expired)
        XCTAssertEqual(status(old, 10_000), .expired)
    }

    // 6. Paging continues until nextCursor is nil; the cap reports incompleteness.
    func testFetchAllPagesFollowsCursorAndFlagsCap() async throws {
        let full: PagedResult<Int> = try await fetchAllPages { cursor in
            let n = Int(cursor ?? "0") ?? 0
            return Page(items: [n], nextCursor: n < 79 ? String(n + 1) : nil)
        }
        XCTAssertTrue(full.isComplete)
        XCTAssertEqual(full.items, Array(0..<80))

        let capped: PagedResult<Int> = try await fetchAllPages(maxPages: 3) { cursor in
            let n = Int(cursor ?? "0") ?? 0
            return Page(items: [n], nextCursor: String(n + 1))
        }
        XCTAssertFalse(capped.isComplete)
        XCTAssertEqual(capped.items, [0, 1, 2])

        let looping: PagedResult<Int> = try await fetchAllPages { _ in Page(items: [1], nextCursor: "same") }
        XCTAssertFalse(looping.isComplete)
        XCTAssertEqual(looping.items.count, 2)
    }

    // Review 2/P2: partially measured totals carry coverage; ratios use only complete inputs.
    func testPartialTotalsReportCoverage() {
        let partial = AnalyticsMath.totals(drives: [drive(100, 15), drive(50, nil)],
                                           charges: [charge(added: 20, cost: 5, currency: "USD"), charge(added: nil, cost: nil, currency: nil)],
                                           fallbackCurrency: "USD")
        XCTAssertEqual(partial.energyAddedKwh, 20)
        XCTAssertEqual(partial.energyAddedCoverage, .init(measured: 1, total: 2))
        XCTAssertTrue(partial.energyAddedCoverage.isPartial)
        XCTAssertEqual(partial.energyAddedCoverage.qualifier, "Partial — 1 of 2 measured")
        XCTAssertEqual(partial.costCoverage.qualifier, "Partial — 1 of 2 measured")
        XCTAssertEqual(partial.energyUsedCoverage.qualifier, "Partial — 1 of 2 measured")
        XCTAssertEqual(partial.singleCost, .init(currency: "USD", amount: 5))
        XCTAssertNil(partial.costPerKm, "cost per distance needs every charge's cost")
        XCTAssertEqual(try XCTUnwrap(partial.efficiencyWhPerKm), 150, accuracy: 0.0001)

        let complete = AnalyticsMath.totals(drives: [drive(100, 15), drive(100, 10)],
                                            charges: [charge(added: 20, cost: 5, currency: "USD"), charge(added: 10, cost: 3, currency: "USD")],
                                            fallbackCurrency: "USD")
        XCTAssertNil(complete.energyAddedCoverage.qualifier)
        XCTAssertNil(complete.costCoverage.qualifier)
        XCTAssertNil(complete.energyUsedCoverage.qualifier)
        XCTAssertEqual(complete.costPerKm?.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(complete.costPerKm?.amount), 0.04, accuracy: 0.0001)

        let noneMeasured = AnalyticsMath.totals(drives: [drive(10, nil)], charges: [charge(added: nil, cost: nil, currency: nil)], fallbackCurrency: "USD")
        XCTAssertNil(noneMeasured.energyAddedCoverage.qualifier) // shown as "—", not a partial number
        XCTAssertNil(noneMeasured.costPerKm)

        let mixed = AnalyticsMath.totals(drives: [drive(100, 15)],
                                         charges: [charge(added: 1, cost: 5, currency: "USD"), charge(added: 1, cost: 4, currency: "EUR")],
                                         fallbackCurrency: "USD")
        XCTAssertNil(mixed.costPerKm)
    }

    // Review 2/P2: weeks start Monday (ISO), matching Postgres date_trunc('week').
    func testWeeklyBucketsStartMonday() {
        let utc = AnalyticsMath.utcCalendar
        let monday = utc.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        XCTAssertEqual(utc.component(.weekday, from: monday), 2)
        let sundayNight = utc.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23, minute: 59))!
        XCTAssertEqual(utc.dateInterval(of: .weekOfYear, for: sundayNight)?.start, monday)

        let previous = utc.date(byAdding: .day, value: -7, to: monday)!
        let buckets = [MileageBucket(start: monday, distanceKm: 5, driveCount: 1, energyUsedKwh: nil),
                       MileageBucket(start: previous, distanceKm: 4, driveCount: 1, energyUsedKwh: nil)]
        XCTAssertEqual(AnalyticsMath.bucket(containing: sundayNight, in: buckets, size: .week)?.start, monday)
        XCTAssertEqual(AnalyticsMath.bucket(containing: monday.addingTimeInterval(-1), in: buckets, size: .week)?.start, previous)
        XCTAssertNil(AnalyticsMath.bucket(containing: monday.addingTimeInterval(7 * 86_400), in: buckets, size: .week))

        let intervals = AnalyticsMath.intervals(buckets, size: .week)
        XCTAssertEqual(intervals.map(\.bucket.start), [previous, monday])
        XCTAssertEqual(intervals.last?.interval, DateInterval(start: monday, duration: 7 * 86_400))
    }

    // Review 2/P2: demo mileage buckets on UTC boundaries, like the server, in any local time zone.
    func testDemoMileageBucketsAreUTC() async throws {
        let utc = AnalyticsMath.utcCalendar
        for size in MileageBucketSize.allCases {
            let buckets = try await MockDataSource().mileage(vehicleID: MockDataSource.vehicleID, bucket: size)
            XCTAssertFalse(buckets.isEmpty)
            for b in buckets {
                XCTAssertEqual(utc.dateInterval(of: AnalyticsMath.component(for: size), for: b.start)?.start, b.start, "\(size) \(b.start)")
                let parts = utc.dateComponents([.hour, .minute, .second, .weekday, .day], from: b.start)
                XCTAssertEqual([parts.hour, parts.minute, parts.second], [0, 0, 0])
                if size == .week { XCTAssertEqual(parts.weekday, 2) }
                if size == .month { XCTAssertEqual(parts.day, 1) }
            }
        }
    }

    // Review 2/P2: warranty storage is scoped by full origin, not hostname alone.
    func testPurchaseDateKeyScopesByOrigin() {
        func key(_ url: String, vehicle: Int = 1) -> String? {
            SpecsWarrantyView.purchaseDateKey(serverURL: url, isDemo: false, isLaunchDemo: false, vehicleID: vehicle)
        }
        XCTAssertNotEqual(key("http://nas.local:4000"), key("http://nas.local:4001"))
        XCTAssertNotEqual(key("http://nas.local:4000"), key("https://nas.local:4000"))
        XCTAssertNotEqual(key("https://nas.local/a"), key("https://nas.local/b"))
        XCTAssertNotEqual(key("https://nas.local", vehicle: 1), key("https://nas.local", vehicle: 2))
        XCTAssertEqual(key("https://NAS.local/"), key("https://nas.local:443"))
        XCTAssertEqual(key("http://nas.local"), key("http://nas.local:80"))
        XCTAssertEqual(AnalyticsMath.serverScope("http://nas.local:4000/"), "http://nas.local:4000")
        XCTAssertNil(SpecsWarrantyView.purchaseDateKey(serverURL: "x", isDemo: true, isLaunchDemo: true, vehicleID: 1))
        XCTAssertEqual(SpecsWarrantyView.purchaseDateKey(serverURL: "http://a:1", isDemo: true, isLaunchDemo: false, vehicleID: 1),
                       "volta.warranty.purchaseDate.demo.1")
    }

    // Review 2/P1: a sweep (leave / unpair) invalidates in-flight exports, so they can't recreate the file.
    func testExportSweepBlocksStaleWrite() throws {
        let data = Data("{}".utf8)
        let token = ExportFiles.currentGeneration()
        let url = try ExportFiles.write(data, named: "test-export.json", token: token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path()))

        let stale = ExportFiles.currentGeneration()
        ExportFiles.removeAll() // e.g. unpair while requests are pending
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path()))
        XCTAssertFalse(ExportFiles.isCurrent(stale))
        XCTAssertThrowsError(try ExportFiles.write(data, named: "test-export.json", token: stale)) {
            XCTAssertTrue($0 is ExportFiles.StaleExportError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportFiles.directory.path()))

        let fresh = ExportFiles.currentGeneration()
        XCTAssertTrue(ExportFiles.isCurrent(fresh))
        _ = try ExportFiles.write(data, named: "test-export.json", token: fresh)
        ExportFiles.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportFiles.directory.path()))
    }

    // Review 3/P2: hidden tab or backgrounding sweeps exports; an active share sheet is left alone.
    func testExportCleanupTriggers() {
        XCTAssertTrue(ExportCleanup.shouldSweep(isActiveTab: false, scenePhase: .active, isSharing: false))
        XCTAssertTrue(ExportCleanup.shouldSweep(isActiveTab: false, scenePhase: .active, isSharing: true))
        XCTAssertTrue(ExportCleanup.shouldSweep(isActiveTab: false, scenePhase: .background, isSharing: false))
        XCTAssertTrue(ExportCleanup.shouldSweep(isActiveTab: true, scenePhase: .background, isSharing: false))
        XCTAssertFalse(ExportCleanup.shouldSweep(isActiveTab: true, scenePhase: .background, isSharing: true))
        XCTAssertFalse(ExportCleanup.shouldSweep(isActiveTab: true, scenePhase: .active, isSharing: false))
        XCTAssertFalse(ExportCleanup.shouldSweep(isActiveTab: true, scenePhase: .inactive, isSharing: true))
        XCTAssertFalse(ExportCleanup.shouldSweep(isActiveTab: true, scenePhase: .inactive, isSharing: false))
    }

    // The energy line is split at buckets with nothing measured, so it never
    // draws interpolated values across a gap; lone values become point runs.
    @MainActor func testEnergyUsedRunsSplitAtMissingBuckets() {
        let used: [Double?] = [nil, 4, 6, nil, nil, 3, nil, 2, 5, 1]
        let buckets = used.enumerated().map { index, kwh in
            StatsView.Bucket(start: t0.addingTimeInterval(Double(index) * 86_400), energyUsedKwh: kwh)
        }
        let runs = StatsView.energyUsedRuns(buckets)
        XCTAssertEqual(runs.map { $0.map(\.energyUsedKwh) }, [[4, 6], [3], [2, 5, 1]])
        XCTAssertEqual(runs.flatMap { $0 }.count, used.compactMap { $0 }.count, "Every measured bucket is drawn, no missing one is")
        XCTAssertTrue(StatsView.energyUsedRuns(buckets.map { var b = $0; b.energyUsedKwh = nil; return b }).isEmpty)
        // A measured zero is a real value and stays in its run.
        XCTAssertEqual(StatsView.energyUsedRuns([StatsView.Bucket(start: t0, energyUsedKwh: 0),
                                                 StatsView.Bucket(start: t0.addingTimeInterval(86_400), energyUsedKwh: 2)]).map(\.count), [2])
    }
}
