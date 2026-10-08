import XCTest
import Synchronization
@testable import Volta

// Widget snapshot mapping, Live Activity planning (identity, final state,
// unknowns) and the app-side wiring that feeds them.

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func status(vehicle: Int = 1, state: VehicleState = .charging, charging: ChargingState? = .charging,
                    battery: Int = 60, limit: Int? = 80, power: Double? = 7.4, minutesToFull: Int? = 90,
                    range: Double? = 280, updatedAt: Date = t0) -> VehicleStatus {
    VehicleStatus(vehicleId: vehicle, state: state, updatedAt: updatedAt, batteryLevel: battery,
                  usableBatteryLevel: nil, ratedRangeKm: nil, estRangeKm: range, chargeLimit: limit,
                  chargingState: charging, chargerPowerKw: power, minutesToFull: minutesToFull,
                  insideTempC: nil, outsideTempC: nil, climateOn: nil, driverTempSettingC: nil, locked: nil,
                  sentryMode: nil, odometerKm: nil, location: nil, firmware: nil)
}

private func charge(id: Int, start: Date = t0.addingTimeInterval(-3600), end: Date? = nil,
                    added: Double? = 12.5, endBattery: Int? = nil) -> ChargeSummary {
    ChargeSummary(id: id, start: start, end: end, address: nil, placeName: "Home", energyAddedKwh: added,
                  energyUsedKwh: nil, startBatteryLevel: 40, endBatteryLevel: endBattery, durationMin: 60,
                  maxPowerKw: nil, fastCharger: false, cost: nil, currency: nil, outsideTempAvgC: nil)
}

private func drive(id: Int, end: Date? = nil, distance: Double = 12) -> DriveSummary {
    DriveSummary(id: id, start: t0.addingTimeInterval(-900), end: end, startAddress: "Home", endAddress: nil,
                 distanceKm: distance, durationMin: 15, startBatteryLevel: 70, endBatteryLevel: end == nil ? nil : 66,
                 energyUsedKwh: 2.1, efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil,
                 outsideTempAvgC: nil)
}

private func chargingAttributes(vehicle: Int = 1, chargeId: Int? = 10) -> ChargingActivityAttributes {
    ChargingActivityAttributes(vehicleId: vehicle, chargeId: chargeId, vehicleName: "Friday", placeName: nil,
                               startedAt: nil, startBatteryLevel: nil, fastCharger: nil, usesMiles: false)
}

private func chargingState(energy: Double? = 5, limit: Int? = 80) -> ChargingActivityAttributes.ContentState {
    .init(batteryLevel: 55, chargeLimit: limit, chargerPowerKw: 7, fullAt: t0.addingTimeInterval(3600),
          energyAddedKwh: energy, rangeKm: 250, updatedAt: t0.addingTimeInterval(-300))
}

private func running(_ id: String, vehicle: Int = 1, chargeId: Int? = 10) -> LiveActivityPlanner.ChargingRunning {
    .init(id: id, attributes: chargingAttributes(vehicle: vehicle, chargeId: chargeId), state: chargingState())
}

private func drivingRunning(_ id: String, vehicle: Int = 1, driveId: Int? = 20) -> LiveActivityPlanner.DrivingRunning {
    .init(id: id,
          attributes: DrivingActivityAttributes(vehicleId: vehicle, driveId: driveId, vehicleName: "Friday",
                                                startedAt: t0.addingTimeInterval(-900), startAddress: nil,
                                                startBatteryLevel: 70, usesMiles: false),
          state: .init(batteryLevel: 68, rangeKm: 290, distanceKm: 8, energyUsedKwh: 1.4,
                       updatedAt: t0.addingTimeInterval(-60)))
}

private func planCharging(_ existing: [LiveActivityPlanner.ChargingRunning], _ s: VehicleStatus,
                          latest: ChargeSummary? = nil, canStart: Bool = true,
                          now: Date = t0.addingTimeInterval(60)) -> LiveActivityPlanner.ChargingPlan {
    LiveActivityPlanner.planCharging(existing: existing, status: s, vehicleName: "Friday", latestCharge: latest,
                                     usesMiles: false, canStart: canStart, now: now)
}

private func planDriving(_ existing: [LiveActivityPlanner.DrivingRunning], _ s: VehicleStatus,
                         latest: DriveSummary? = nil, enabled: Bool = true,
                         now: Date = t0.addingTimeInterval(60)) -> LiveActivityPlanner.DrivingPlan {
    LiveActivityPlanner.planDriving(existing: existing, status: s, vehicleName: "Friday", latestDrive: latest,
                                    usesMiles: false, enabled: enabled, canStart: true, now: now)
}

// MARK: - Snapshot mapping

@MainActor final class WidgetSnapshotMappingTests: XCTestCase {
    func testUnknownValuesStayUnknown() {
        let s = status(limit: nil, power: nil, minutesToFull: nil, range: nil)
        let snapshot = WidgetSnapshot(status: s, vehicleName: "Friday", summary: nil, timeline: nil, now: t0)
        XCTAssertNil(snapshot.chargeLimit)
        XCTAssertNil(snapshot.chargerPowerKw)
        XCTAssertNil(snapshot.minutesToFull)
        XCTAssertNil(snapshot.estRangeKm)
        XCTAssertNil(snapshot.today)
        XCTAssertTrue(snapshot.timeline.isEmpty)
        XCTAssertEqual(snapshot.chargingState, .charging)
        XCTAssertEqual(snapshot.updatedAt, t0)
    }

    func testKeepsPreviousTodayAndTimelineOnlyForSameVehicle() {
        let summary = ActivitySummary(range: .today, distanceKm: 30, driveCount: 2, chargeCount: 1, energyUsedKwh: 5,
                                      efficiencyWhPerKm: 160, energyAddedKwh: 9, chargeCost: nil, currency: nil)
        let segments = [TimelineSegment(kind: .drive, start: t0.addingTimeInterval(-7200), end: t0.addingTimeInterval(-3600)),
                        TimelineSegment(kind: .idle, start: t0.addingTimeInterval(-60 * 3600), end: t0.addingTimeInterval(-50 * 3600))]
        let full = WidgetSnapshot(status: status(), vehicleName: "Friday", summary: summary, timeline: segments, now: t0)
        XCTAssertEqual(full.today?.distanceKm, 30)
        XCTAssertEqual(full.timeline.count, 1, "segments older than 48 h are dropped")

        // A status-only refresh (Controls) keeps the rest from the previous snapshot.
        let statusOnly = WidgetSnapshot(status: status(battery: 61), vehicleName: "Friday", summary: nil,
                                        timeline: nil, now: t0.addingTimeInterval(60), previous: full)
        XCTAssertEqual(statusOnly.batteryLevel, 61)
        XCTAssertEqual(statusOnly.today, full.today)
        XCTAssertEqual(statusOnly.timeline, full.timeline)

        // ...but never another vehicle's.
        let other = WidgetSnapshot(status: status(vehicle: 2), vehicleName: "Other", summary: nil, timeline: nil,
                                   now: t0.addingTimeInterval(60), previous: full)
        XCTAssertNil(other.today)
        XCTAssertTrue(other.timeline.isEmpty)
    }

    func testTodayTotalsFollowTheBackendUTCReportingDay() throws {
        // New York, EDT (UTC-4): the backend's "today" ends at 20:00 local, not local midnight.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func ny(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        let fetched = try ny(6, 19, 55)
        let beforeRollover = try ny(6, 19, 59)
        let rollover = try ny(6, 20, 0)
        let afterRollover = try ny(6, 20, 5)
        XCTAssertEqual(rollover, Date(timeIntervalSince1970: 1_791_331_200), "2026-10-07T00:00:00Z")

        let summary = ActivitySummary(range: .today, distanceKm: 30, driveCount: 2, chargeCount: 1, energyUsedKwh: 5,
                                      efficiencyWhPerKm: 160, energyAddedKwh: 9, chargeCost: nil, currency: nil)
        let full = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: summary,
                                  timeline: nil, now: fetched)
        XCTAssertEqual(full.todayDay, rollover.addingTimeInterval(-86_400), "stamped with the UTC day start")
        XCTAssertNotNil(full.todayTotals(at: beforeRollover))
        XCTAssertNil(full.todayTotals(at: rollover), "the backend has started a new day")
        XCTAssertNil(full.todayTotals(at: afterRollover))

        // Status-only refresh within the same UTC day keeps the totals and their day.
        let sameDay = WidgetSnapshot(status: status(updatedAt: beforeRollover), vehicleName: "Friday", summary: nil,
                                     timeline: nil, now: beforeRollover, previous: full)
        XCTAssertEqual(sameDay.today, full.today)
        XCTAssertEqual(sameDay.todayDay, full.todayDay)

        // After the rollover a status-only refresh (or failed summary) makes them unknown,
        // even though it is still the same local day.
        let nextDay = WidgetSnapshot(status: status(updatedAt: afterRollover), vehicleName: "Friday", summary: nil,
                                     timeline: nil, now: afterRollover, previous: sameDay)
        XCTAssertNil(nextDay.today)
        XCTAssertNil(nextDay.todayDay)

        // A fresh summary after the rollover belongs to the new UTC day and lasts until its end.
        let fresh = WidgetSnapshot(status: status(updatedAt: afterRollover), vehicleName: "Friday", summary: summary,
                                   timeline: nil, now: afterRollover, previous: sameDay)
        XCTAssertEqual(fresh.todayDay, rollover)
        XCTAssertNotNil(fresh.todayTotals(at: try ny(6, 23, 59)), "local midnight is not a boundary")
        XCTAssertNil(fresh.todayTotals(at: try ny(7, 20, 0)))

        // The widget timeline reloads exactly when the reporting day ends.
        XCTAssertTrue(WidgetSnapshot.timelineDates(now: fetched, snapshot: full).contains(rollover))
        XCTAssertEqual(ReportingDay.utcDay(containing: fetched), DateInterval(start: full.todayDay!, end: rollover))
        XCTAssertEqual(full.todayDayEnd, rollover, "old-server day bounds are stored too")
    }

    func testSummaryRequestedBeforeRolloverIsDroppedWhenPublishedAfter() {
        let rollover = Date(timeIntervalSince1970: 1_791_331_200)  // 2026-10-07T00:00:00Z
        let requested = rollover.addingTimeInterval(-1)            // 23:59:59 UTC
        let published = rollover.addingTimeInterval(30)
        let summary = ActivitySummary(range: .today, distanceKm: 30, driveCount: 2, chargeCount: 1, energyUsedKwh: 5,
                                      efficiencyWhPerKm: 160, energyAddedKwh: 9, chargeCost: nil, currency: nil)
        // Totals from earlier the same (old) day are on the widget.
        let earlier = WidgetSnapshot(status: status(updatedAt: requested), vehicleName: "Friday", summary: summary,
                                     summaryRequestedAt: requested.addingTimeInterval(-600), timeline: nil,
                                     now: requested)
        XCTAssertNotNil(earlier.today)

        let crossed = WidgetSnapshot(status: status(updatedAt: published), vehicleName: "Friday", summary: summary,
                                     summaryRequestedAt: requested, timeline: nil, now: published, previous: earlier)
        XCTAssertNil(crossed.today, "computed for either day: unknown, not stamped with the new day")
        XCTAssertNil(crossed.todayDay)
        XCTAssertNil(crossed.todayTotals(at: published))

        // Same day: stamped with the request's day, not the publish time's.
        let sameDay = WidgetSnapshot(status: status(updatedAt: requested), vehicleName: "Friday", summary: summary,
                                     summaryRequestedAt: requested.addingTimeInterval(-5), timeline: nil,
                                     now: requested)
        XCTAssertEqual(sameDay.todayDay, rollover.addingTimeInterval(-86_400))
        XCTAssertNotNil(sameDay.todayTotals(at: requested))
    }

    // MARK: Server-reported local day (`/summary?tz=`)

    private static let iso = ISO8601DateFormatter()
    private func instant(_ text: String) throws -> Date { try XCTUnwrap(Self.iso.date(from: text)) }
    private func zonedSummary(periodStart: Date?, periodEnd: Date? = nil, timeZone: String?) -> ActivitySummary {
        ActivitySummary(range: .today, distanceKm: 30, driveCount: 2, chargeCount: 1, energyUsedKwh: 5,
                        efficiencyWhPerKm: 160, energyAddedKwh: 9, chargeCost: nil, currency: nil,
                        periodStart: periodStart, periodEnd: periodEnd, timeZone: timeZone)
    }

    func testNewYorkTotalsLastUntilLocalMidnight() throws {
        // 2026-10-06 19:55 EDT = 23:55Z. The zoned server day is local, not UTC.
        let localMidnight = try instant("2026-10-06T04:00:00Z")
        let nextMidnight = try instant("2026-10-07T04:00:00Z")
        let fetched = try instant("2026-10-06T23:55:00Z")
        let summary = zonedSummary(periodStart: localMidnight, periodEnd: fetched, timeZone: "America/New_York")
        let full = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: summary,
                                  summaryRequestedAt: fetched, timeline: nil, now: fetched)
        XCTAssertEqual(full.todayDay, localMidnight)
        XCTAssertEqual(full.todayDayEnd, nextMidnight)
        XCTAssertNotNil(full.todayTotals(at: try instant("2026-10-07T00:00:00Z")), "20:00 local is no longer a boundary")
        XCTAssertNotNil(full.todayTotals(at: nextMidnight.addingTimeInterval(-1)))
        XCTAssertNil(full.todayTotals(at: nextMidnight), "local midnight ends the day")

        // A status-only refresh after 20:00 local keeps the totals and their stored day.
        let later = try instant("2026-10-07T00:05:00Z")
        let kept = WidgetSnapshot(status: status(updatedAt: later), vehicleName: "Friday", summary: nil,
                                  timeline: nil, now: later, previous: full)
        XCTAssertEqual(kept.today, full.today)
        XCTAssertEqual(kept.todayReportingDay?.interval, DateInterval(start: localMidnight, end: nextMidnight))

        // ...but not after local midnight.
        let tomorrow = nextMidnight.addingTimeInterval(60)
        let expired = WidgetSnapshot(status: status(updatedAt: tomorrow), vehicleName: "Friday", summary: nil,
                                     timeline: nil, now: tomorrow, previous: kept)
        XCTAssertNil(expired.today)
        XCTAssertNil(expired.todayDay)
        XCTAssertNil(expired.todayDayEnd)

        // The widget timeline gets an entry exactly at local midnight.
        let nearMidnight = nextMidnight.addingTimeInterval(-15 * 60)
        XCTAssertTrue(WidgetSnapshot.timelineDates(now: nearMidnight, snapshot: kept).contains(nextMidnight))
        // (5-minute charging steps from 23:47Z never land on 00:00Z by themselves.)
        XCTAssertFalse(WidgetSnapshot.timelineDates(now: try instant("2026-10-06T23:47:00Z"), snapshot: kept)
            .contains(try instant("2026-10-07T00:00:00Z")), "no reload at the UTC boundary")
    }

    func testDSTDaysAre25And23Hours() throws {
        // Fall back: 2026-11-01 in New York lasts 25 h.
        let fallStart = try instant("2026-11-01T04:00:00Z")
        let fall = ReportingDay.interval(periodStart: fallStart, timeZone: "America/New_York", requestedAt: fallStart)
        XCTAssertEqual(fall, DateInterval(start: fallStart, end: try instant("2026-11-02T05:00:00Z")))
        XCTAssertEqual(fall.duration, 25 * 3600)

        // Spring forward: 2026-03-08 lasts 23 h.
        let springStart = try instant("2026-03-08T05:00:00Z")
        let spring = ReportingDay.interval(periodStart: springStart, timeZone: "America/New_York", requestedAt: springStart)
        XCTAssertEqual(spring, DateInterval(start: springStart, end: try instant("2026-03-09T04:00:00Z")))
        XCTAssertEqual(spring.duration, 23 * 3600)

        // Havana skips midnight on 2026-03-08: the next day starts at 01:00 local.
        let havanaStart = try instant("2026-03-07T05:00:00Z")
        XCTAssertEqual(ReportingDay.interval(periodStart: havanaStart, timeZone: "America/Havana", requestedAt: havanaStart).end,
                       try instant("2026-03-08T05:00:00Z"))

        // The snapshot keeps fall-back totals through the 25th hour.
        let fetched = try instant("2026-11-02T03:00:00Z")  // 22:00 EST
        let snapshot = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday",
                                      summary: zonedSummary(periodStart: fallStart, timeZone: "America/New_York"),
                                      summaryRequestedAt: fetched, timeline: nil, now: fetched)
        XCTAssertNotNil(snapshot.todayTotals(at: try instant("2026-11-02T04:30:00Z")), "23:30 EST, 24.5 h in")
        XCTAssertNil(snapshot.todayTotals(at: try instant("2026-11-02T05:00:00Z")))
    }

    func testOldServerWithoutPeriodKeepsTheUTCRule() throws {
        let fetched = try instant("2026-10-06T23:55:00Z")
        let utcMidnight = try instant("2026-10-07T00:00:00Z")
        for summary in [zonedSummary(periodStart: nil, timeZone: nil),
                        zonedSummary(periodStart: nil, timeZone: "America/New_York"),
                        zonedSummary(periodStart: try instant("2026-10-06T04:00:00Z"), timeZone: nil)] {
            let snapshot = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: summary,
                                          summaryRequestedAt: fetched, timeline: nil, now: fetched)
            XCTAssertEqual(snapshot.todayReportingDay?.interval, DateInterval(start: try instant("2026-10-06T00:00:00Z"), end: utcMidnight))
            XCTAssertNil(snapshot.todayZone, "UTC-rule days don't depend on the device zone")
            XCTAssertNotNil(snapshot.todayTotals(at: fetched, deviceZone: "Asia/Tokyo"))
            XCTAssertNil(snapshot.todayTotals(at: utcMidnight))
        }
    }

    func testRolloverDiscardUsesTheServerDay() throws {
        let requested = try instant("2026-10-07T03:59:59Z")  // 23:59:59 EDT
        let published = try instant("2026-10-07T04:00:30Z")  // 00:00:30 EDT
        // Computed before local midnight, published after it: yesterday's totals.
        let yesterday = zonedSummary(periodStart: try instant("2026-10-06T04:00:00Z"), periodEnd: requested,
                                     timeZone: "America/New_York")
        let crossed = WidgetSnapshot(status: status(updatedAt: published), vehicleName: "Friday", summary: yesterday,
                                     summaryRequestedAt: requested, timeline: nil, now: published)
        XCTAssertNil(crossed.today)
        XCTAssertNil(crossed.todayDay)
        XCTAssertNil(crossed.todayDayEnd)

        // Requested before midnight but computed after it: unambiguous, kept for the new day.
        let newDay = try instant("2026-10-07T04:00:00Z")
        let fresh = zonedSummary(periodStart: newDay, periodEnd: try instant("2026-10-07T04:00:01Z"),
                                 timeZone: "America/New_York")
        let kept = WidgetSnapshot(status: status(updatedAt: published), vehicleName: "Friday", summary: fresh,
                                  summaryRequestedAt: requested, timeline: nil, now: published)
        XCTAssertNotNil(kept.today)
        XCTAssertEqual(kept.todayReportingDay?.interval, DateInterval(start: newDay, end: try instant("2026-10-08T04:00:00Z")))
    }

    func testZoneChangeMakesLocalTotalsUnknown() throws {
        let la = "America/Los_Angeles", ny = "America/New_York"
        // Oct 6 in Los Angeles: 07:00Z to 07:00Z, fetched at 13:00 PDT.
        let fetched = try instant("2026-10-06T20:00:00Z")
        let laDay = DateInterval(start: try instant("2026-10-06T07:00:00Z"), end: try instant("2026-10-07T07:00:00Z"))
        let laSummary = zonedSummary(periodStart: laDay.start, periodEnd: fetched, timeZone: la)
        let full = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: laSummary,
                                  summaryRequestedAt: fetched, summaryRequestedZone: la, timeline: nil,
                                  now: fetched, deviceZone: la)
        XCTAssertEqual(full.todayReportingDay, ReportingDay.Day(interval: laDay, zone: la))
        XCTAssertEqual(full.todayZone, la)

        // After flying to New York, 00:30 EDT is still inside the LA day but is not "Today" there.
        let landed = try instant("2026-10-07T04:30:00Z")
        XCTAssertNotNil(full.todayTotals(at: landed, deviceZone: la))
        XCTAssertNil(full.todayTotals(at: landed, deviceZone: ny), "widget read path checks the device zone")

        // A status-only refresh in the new zone does not revive them.
        let statusOnly = WidgetSnapshot(status: status(updatedAt: landed), vehicleName: "Friday", summary: nil,
                                        timeline: nil, now: landed, deviceZone: ny, previous: full)
        XCTAssertNil(statusOnly.today)
        XCTAssertNil(statusOnly.todayDay)
        XCTAssertNil(statusOnly.todayZone)
        XCTAssertNil(WidgetSnapshot(status: status(updatedAt: landed), vehicleName: "Friday", summary: nil, timeline: nil,
                                    now: landed.addingTimeInterval(60), deviceZone: la, previous: statusOnly).today,
                     "and they stay gone")

        // A response requested in LA but published after the zone change is dropped too.
        let inFlight = WidgetSnapshot(status: status(updatedAt: landed), vehicleName: "Friday", summary: laSummary,
                                      summaryRequestedAt: landed.addingTimeInterval(-5), summaryRequestedZone: la,
                                      timeline: nil, now: landed, deviceZone: ny, previous: full)
        XCTAssertNil(inFlight.today)

        // A fresh refresh in New York gets the New York day.
        let nyStart = try instant("2026-10-07T04:00:00Z")
        let fresh = WidgetSnapshot(status: status(updatedAt: landed), vehicleName: "Friday",
                                   summary: zonedSummary(periodStart: nyStart, periodEnd: landed, timeZone: ny),
                                   summaryRequestedAt: landed, summaryRequestedZone: ny, timeline: nil,
                                   now: landed, deviceZone: ny, previous: statusOnly)
        XCTAssertEqual(fresh.todayReportingDay, ReportingDay.Day(
            interval: DateInterval(start: nyStart, end: try instant("2026-10-08T04:00:00Z")), zone: ny))
        XCTAssertNotNil(fresh.todayTotals(at: landed, deviceZone: ny))

        // Old-server (UTC) totals are unaffected by the zone change.
        let utc = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday",
                                 summary: zonedSummary(periodStart: nil, timeZone: nil), summaryRequestedAt: fetched,
                                 summaryRequestedZone: la, timeline: nil, now: fetched, deviceZone: la)
        let utcAfterTravel = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: nil,
                                            timeline: nil, now: fetched.addingTimeInterval(600), deviceZone: ny,
                                            previous: utc)
        XCTAssertNotNil(utcAfterTravel.today)
        XCTAssertNotNil(utcAfterTravel.todayTotals(at: fetched.addingTimeInterval(600), deviceZone: ny))
    }

    func testSnapshotsWithoutDayEndDecodeWithTheUTCRule() throws {
        let fetched = try instant("2026-10-06T23:55:00Z")
        let zoned = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday",
                                   summary: zonedSummary(periodStart: try instant("2026-10-06T04:00:00Z"), timeZone: "America/New_York"),
                                   summaryRequestedAt: fetched, timeline: nil, now: fetched)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(zoned)
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: data), zoned, "new fields round-trip")

        // A snapshot written by the previous build: same keys minus `todayDayEnd`,
        // with `todayDay` stamped as the UTC day start.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "todayDayEnd")
        object.removeValue(forKey: "todayZone")
        object["todayDay"] = "2026-10-06T00:00:00Z"
        let legacy = try decoder.decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.todayZone)
        XCTAssertNotNil(legacy.todayTotals(at: fetched, deviceZone: "Asia/Tokyo"), "legacy days have no zone check")
        XCTAssertEqual(legacy.version, WidgetSnapshot.currentVersion, "no version bump: old snapshots stay readable")
        XCTAssertNil(legacy.todayDayEnd)
        let utcMidnight = try instant("2026-10-07T00:00:00Z")
        XCTAssertEqual(legacy.todayReportingDay?.interval, DateInterval(start: try instant("2026-10-06T00:00:00Z"), end: utcMidnight))
        XCTAssertNotNil(legacy.todayTotals(at: utcMidnight.addingTimeInterval(-1)))
        XCTAssertNil(legacy.todayTotals(at: utcMidnight))
        XCTAssertTrue(WidgetSnapshot.timelineDates(now: fetched, snapshot: legacy).contains(utcMidnight))

        // Kept across a status-only refresh, the legacy day is written out with explicit bounds.
        let kept = WidgetSnapshot(status: status(updatedAt: fetched), vehicleName: "Friday", summary: nil,
                                  timeline: nil, now: fetched, previous: legacy)
        XCTAssertEqual(kept.todayDayEnd, utcMidnight)
    }

    func testStaleBoundaryAndTimelineIncludesStaleMoment() {
        let snapshot = WidgetSnapshot(status: status(charging: .disconnected), vehicleName: "Friday",
                                      summary: nil, timeline: nil, now: t0)
        XCTAssertFalse(snapshot.isStale(at: t0.addingTimeInterval(3599)))
        XCTAssertTrue(snapshot.isStale(at: t0.addingTimeInterval(3600)))

        let now = t0.addingTimeInterval(50 * 60)  // stale in 10 min; entries every 10 min (not charging)
        let dates = WidgetSnapshot.timelineDates(now: now, snapshot: snapshot)
        XCTAssertEqual(dates.first, now)
        XCTAssertTrue(dates.contains(snapshot.staleAt))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(WidgetSnapshot.timelineDates(now: now, snapshot: nil).count, 4)
    }
}

// MARK: - Charging Live Activity planning

final class ChargingActivityPlannerTests: XCTestCase {
    func testStartsWithIdentityAndUnknownsKept() throws {
        let plan = planCharging([], status(limit: nil, power: nil, minutesToFull: nil, range: nil),
                                latest: charge(id: 10, added: nil))
        let start = try XCTUnwrap(plan.start)
        XCTAssertEqual(start.attributes.vehicleId, 1)
        XCTAssertEqual(start.attributes.chargeId, 10)
        XCTAssertEqual(start.attributes.fastCharger, false)
        XCTAssertNil(start.state.chargeLimit, "unknown limit is not replaced with 100")
        XCTAssertNil(start.state.fractionOfLimit)
        XCTAssertNil(start.state.chargerPowerKw)
        XCTAssertNil(start.state.fullAt)
        XCTAssertNil(start.state.energyAddedKwh)
        XCTAssertNil(start.state.rangeKm)
        XCTAssertEqual(start.state.phase, .charging)
    }

    func testStartWithoutOpenSessionLeavesSessionDetailsUnknown() throws {
        let start = try XCTUnwrap(planCharging([], status(), latest: charge(id: 9, end: t0.addingTimeInterval(-7200))).start)
        XCTAssertNil(start.attributes.chargeId)
        XCTAssertNil(start.attributes.startedAt)
        XCTAssertNil(start.attributes.fastCharger)
        XCTAssertEqual(start.state.fullAt, t0.addingTimeInterval(90 * 60))
    }

    func testNoStartWhenNotChargingDisabledOrDataAlreadyStale() {
        XCTAssertNil(planCharging([], status(state: .online, charging: .disconnected)).start)
        XCTAssertNil(planCharging([], status(), canStart: false).start)
        XCTAssertNil(planCharging([], status(), now: t0.addingTimeInterval(VoltaLiveActivityTiming.chargingStaleAfter)).start)
    }

    func testUpdatesSameSessionWithoutStartingAnother() {
        let plan = planCharging([running("a")], status(battery: 62), latest: charge(id: 10, added: nil))
        guard case .update(let state) = plan.existing["a"] else { return XCTFail("expected update") }
        XCTAssertEqual(state.batteryLevel, 62)
        XCTAssertEqual(state.energyAddedKwh, 5, "unknown energy keeps the last known value, not 0")
        XCTAssertNil(plan.start)
    }

    func testOtherVehicleIsDismissedAndReplaced() {
        let plan = planCharging([running("a", vehicle: 2)], status(), latest: charge(id: 10))
        XCTAssertEqual(plan.existing["a"], .dismiss)
        XCTAssertEqual(plan.start?.attributes.vehicleId, 1)
    }

    func testNewSessionIsDismissedAndReplaced() {
        let plan = planCharging([running("a", chargeId: 10)], status(), latest: charge(id: 11))
        XCTAssertEqual(plan.existing["a"], .dismiss)
        XCTAssertEqual(plan.start?.attributes.chargeId, 11)
    }

    func testSessionIdentityRules() {
        XCTAssertTrue(LiveActivityPlanner.sameSession(10, nil), "fetch failed: nothing says the session changed")
        XCTAssertTrue(LiveActivityPlanner.sameSession(nil, nil))
        XCTAssertTrue(LiveActivityPlanner.sameSession(10, 10))
        XCTAssertFalse(LiveActivityPlanner.sameSession(10, 11))
        XCTAssertFalse(LiveActivityPlanner.sameSession(nil, 11), "unknown identity does not match a known session")
    }

    func testUnknownIdentityIsReplacedOnceKnown() throws {
        // Started while the history fetch failed: no charge id, no start details.
        let plan = planCharging([running("a", chargeId: nil)], status(), latest: charge(id: 11))
        XCTAssertEqual(plan.existing["a"], .dismiss)
        let start = try XCTUnwrap(plan.start)
        XCTAssertEqual(start.attributes.chargeId, 11)
        XCTAssertEqual(start.attributes.startedAt, t0.addingTimeInterval(-3600))
        XCTAssertEqual(start.state.energyAddedKwh, 12.5)
    }

    func testKnownIdentityKeptWhenFetchFails() {
        let plan = planCharging([running("a", chargeId: 10)], status(), latest: nil)
        guard case .update = plan.existing["a"] else { return XCTFail("expected update") }
        XCTAssertNil(plan.start)
    }

    func testDuplicatesAreDismissed() {
        let plan = planCharging([running("a"), running("b")], status(), latest: charge(id: 10))
        guard case .update = plan.existing["a"] else { return XCTFail("expected update") }
        XCTAssertEqual(plan.existing["b"], .dismiss)
        XCTAssertNil(plan.start)
    }

    func testCompletedFinalState() {
        let ended = t0.addingTimeInterval(-120)
        let plan = planCharging([running("a")], status(state: .online, charging: .complete, battery: 80),
                                latest: charge(id: 10, end: ended, added: 21, endBattery: 80))
        guard case .finish(let state) = plan.existing["a"] else { return XCTFail("expected finish") }
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.endedAt, ended)
        XCTAssertNil(state.chargerPowerKw)
        XCTAssertNil(state.fullAt, "no countdown after the session ended")
        XCTAssertEqual(state.energyAddedKwh, 21)
        XCTAssertEqual(state.batteryLevel, 80)
        XCTAssertNil(plan.start)
    }

    func testStoppedFinalStateWithoutClosedSessionUsesStatusTime() {
        let plan = planCharging([running("a")], status(state: .online, charging: .disconnected, battery: 70, limit: nil),
                                latest: charge(id: 99, end: t0))
        guard case .finish(let state) = plan.existing["a"] else { return XCTFail("expected finish") }
        XCTAssertEqual(state.phase, .stopped)
        XCTAssertEqual(state.endedAt, t0)
        XCTAssertEqual(state.chargeLimit, 80, "unknown limit falls back to the last known one")
        XCTAssertEqual(state.energyAddedKwh, 5, "another session's totals are not used")
    }

    func testUnknownObservationKeepsActivity() {
        let s = status(state: .offline, charging: nil)
        XCTAssertEqual(LiveActivityPlanner.chargingObservation(s), .unknown)
        let plan = planCharging([running("a")], s)
        XCTAssertEqual(plan.existing["a"], .keep)
        XCTAssertNil(plan.start)
    }
}

// MARK: - Driving Live Activity planning

final class DrivingActivityPlannerTests: XCTestCase {
    private let driving = status(state: .driving, charging: nil, power: nil, minutesToFull: nil)

    func testDisabledStartsNothingAndDismissesRunning() {
        let plan = planDriving([drivingRunning("d")], driving, latest: drive(id: 20), enabled: false)
        XCTAssertEqual(plan.existing["d"], .dismiss)
        XCTAssertNil(plan.start)
    }

    func testStartWithoutOpenDriveHasUnknownDistance() throws {
        let start = try XCTUnwrap(planDriving([], driving).start)
        XCTAssertNil(start.attributes.driveId)
        XCTAssertNil(start.attributes.startedAt)
        XCTAssertNil(start.state.distanceKm, "unknown distance is not 0")
        XCTAssertNil(start.state.energyUsedKwh)
    }

    func testStartWithOpenDrive() throws {
        let start = try XCTUnwrap(planDriving([], driving, latest: drive(id: 21, distance: 3.5)).start)
        XCTAssertEqual(start.attributes.driveId, 21)
        XCTAssertEqual(start.state.distanceKm, 3.5)
    }

    func testNewDriveReplacesOldOne() {
        let plan = planDriving([drivingRunning("d", driveId: 20)], driving, latest: drive(id: 21))
        XCTAssertEqual(plan.existing["d"], .dismiss)
        XCTAssertEqual(plan.start?.attributes.driveId, 21)
    }

    func testEndedDriveGetsFinalState() {
        let ended = t0.addingTimeInterval(-30)
        let parked = status(state: .online, charging: .disconnected)
        let plan = planDriving([drivingRunning("d")], parked, latest: drive(id: 20, end: ended, distance: 14))
        guard case .finish(let state) = plan.existing["d"] else { return XCTFail("expected finish") }
        XCTAssertEqual(state.phase, .ended)
        XCTAssertEqual(state.endedAt, ended)
        XCTAssertEqual(state.distanceKm, 14)
        XCTAssertEqual(state.batteryLevel, 66)
        XCTAssertNil(plan.start)
    }

    func testUnknownDriveIdentityIsReplacedOnceKnown() {
        let plan = planDriving([drivingRunning("d", driveId: nil)], driving, latest: drive(id: 21))
        XCTAssertEqual(plan.existing["d"], .dismiss)
        XCTAssertEqual(plan.start?.attributes.driveId, 21)
        XCTAssertNotNil(plan.start?.attributes.startedAt)
    }

    func testOfflineMidDriveKeepsActivity() {
        let plan = planDriving([drivingRunning("d")], status(state: .offline, charging: nil))
        XCTAssertEqual(plan.existing["d"], .keep)
    }
}

// MARK: - App wiring

@MainActor private final class RecordingSurfaces: VehicleSurfaces {
    var contexts: [VehicleSurfaceContext] = []
    var published: [VehicleRefresh] = []
    var drivingPreferenceChanges = 0
    func setContext(_ context: VehicleSurfaceContext) { contexts.append(context) }
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) { published.append(refresh) }
    func drivingActivityPreferenceChanged() { drivingPreferenceChanges += 1 }
    var issuedTokens = 0
    func nextStatusToken() -> StatusRequestToken { issuedTokens += 1; return StatusRequestToken(value: UInt64(issuedTokens)) }
}

private final class WidgetTestTokenStore: TokenStoring, Sendable {
    private let token = Mutex<String?>(nil)
    func load() throws -> String? { token.withLock { $0 } }
    func save(_ value: String) throws { token.withLock { $0 = value } }
    func delete() throws { token.withLock { $0 = nil } }
}

@MainActor final class WidgetWiringTests: XCTestCase {
    private func settings() -> UserSettings {
        let name = "VoltaWidgetTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserSettings(defaults: defaults)
    }

    func testUnpairedAndDemoAreInactive() {
        let surfaces = RecordingSurfaces()
        let model = AppModel(settings: settings(), tokenStore: WidgetTestTokenStore(), launchArguments: ["Volta"],
                             surfaces: surfaces)
        XCTAssertEqual(surfaces.contexts.last, .inactive)
        model.tryDemoMode()
        XCTAssertNil(model.refreshSurfaces)
        XCTAssertEqual(model.surfaceContext, .inactive, "demo data never reaches widgets or Live Activities")
        XCTAssertEqual(surfaces.contexts.last, .inactive)
    }

    func testLaunchDemoClearsSurfacesAndNeverInjectsPublisher() async {
        let surfaces = RecordingSurfaces()
        let model = AppModel(settings: settings(), tokenStore: WidgetTestTokenStore(),
                             launchArguments: ["Volta", "-demo-mode", "YES"], surfaces: surfaces)
        XCTAssertEqual(surfaces.contexts, [.inactive])
        XCTAssertNil(model.refreshSurfaces)
        await model.loadVehicles()
        await DashboardModel().load(dataSource: model.dataSource, vehicleID: model.selectedVehicleID,
                                    surfaces: model.refreshSurfaces)
        XCTAssertTrue(surfaces.published.isEmpty)
        XCTAssertEqual(surfaces.issuedTokens, 0)
        model.unpair(); model.tryDemoMode()
        XCTAssertNil(model.refreshSurfaces)
        XCTAssertTrue(surfaces.contexts.allSatisfy { $0 == .inactive })
    }

    func testPairedVehicleSwitchAndUnpair() async throws {
        let vehicles = try JSONSerialization.data(withJSONObject: [["id": 42, "name": "Friday"], ["id": 7, "name": "Echo"]])
        StubProtocol.handler.withLock { $0 = { _ in (200, vehicles) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let settings = settings(); settings.serverURL = "https://volta.example"
        let store = WidgetTestTokenStore(); try store.save("synthetic-token")
        let surfaces = RecordingSurfaces()
        let model = AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config),
                             launchArguments: ["Volta"], surfaces: surfaces)
        XCTAssertEqual(model.surfaceContext, .pending)
        XCTAssertNil(model.refreshSurfaces)

        await model.loadVehicles()
        XCTAssertEqual(surfaces.contexts.last, .vehicle(id: 42, name: "Friday"))
        XCTAssertNotNil(model.refreshSurfaces)

        model.selectedVehicleID = 7
        XCTAssertEqual(surfaces.contexts.last, .vehicle(id: 7, name: "Echo"))

        model.unpair()
        XCTAssertEqual(surfaces.contexts.last, .inactive, "unpair clears the snapshot and ends Live Activities")
    }

    func testDrivingToggleNotifiesSurfacesImmediately() {
        let settings = settings()
        let surfaces = RecordingSurfaces()
        let model = AppModel(settings: settings, tokenStore: WidgetTestTokenStore(), launchArguments: ["Volta"],
                             surfaces: surfaces)
        model.drivingLiveActivity = true
        model.drivingLiveActivity = false
        XCTAssertFalse(settings.drivingLiveActivity)
        XCTAssertEqual(surfaces.drivingPreferenceChanges, 2)
        model.drivingLiveActivity = false
        XCTAssertEqual(surfaces.drivingPreferenceChanges, 2, "no-op writes do not notify")
    }

    func testDashboardPublishesEachSuccessfulRefresh() async {
        let surfaces = RecordingSurfaces()
        let model = DashboardModel()
        let before = Date.now
        await model.load(dataSource: MockDataSource(empty: false), vehicleID: MockDataSource.vehicleID, surfaces: surfaces)
        let after = Date.now
        let refresh = surfaces.published.last
        XCTAssertEqual(refresh?.status.vehicleId, MockDataSource.vehicleID)
        let today = refresh?.today
        XCTAssertNotNil(today)
        XCTAssertTrue((before...after).contains(today?.requestedAt ?? .distantPast), "request start is captured")
    }
}

// MARK: - Synchronizer (cleanup and preference races)

/// Holds `charges` / `drives` until released; ignores cancellation on purpose
/// so tests prove cleanup does not depend on the network finishing.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class GatedSource: VoltaDataSource {
    let base = MockDataSource(empty: false)
    let gate: Gate
    let latestCharge: ChargeSummary?
    let latestDrive: DriveSummary?
    init(gate: Gate, charge: ChargeSummary? = nil, drive: DriveSummary? = nil) {
        self.gate = gate; latestCharge = charge; latestDrive = drive
    }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> {
        await gate.wait()
        return Page(items: latestCharge.map { [$0] } ?? [], nextCursor: nil)
    }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> {
        await gate.wait()
        return Page(items: latestDrive.map { [$0] } ?? [], nextCursor: nil)
    }
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await base.timeline(vehicleID: vehicleID, hours: hours) }
    func drive(id: Int) async throws -> DriveDetail { try await base.drive(id: id) }
    func charge(id: Int) async throws -> ChargeDetail { try await base.charge(id: id) }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { try await base.idles(vehicleID: vehicleID, range: range, cursor: cursor) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await base.mileage(vehicleID: vehicleID, bucket: bucket) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await base.firmware(vehicleID: vehicleID) }
    func places(vehicleID: Int) async throws -> [Place] { try await base.places(vehicleID: vehicleID) }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws {
        try await base.command(vehicleID: vehicleID, name: name, params: params)
    }
}

/// In-memory ActivityKit stand-in that records every mutation.
@MainActor private final class FakeActivityDriver: LiveActivityDriver {
    var charging: [LiveActivityPlanner.ChargingRunning] = []
    var driving: [LiveActivityPlanner.DrivingRunning] = []
    var canStart = true
    var log: [String] = []

    func chargingActivities() -> [LiveActivityPlanner.ChargingRunning] { charging }
    func drivingActivities() -> [LiveActivityPlanner.DrivingRunning] { driving }
    func apply(_ action: ExistingActivityAction<ChargingActivityAttributes.ContentState>, toCharging id: String) async {
        log.append("charging.\(id).\(Self.name(action))")
        if case .update(let state) = action, let i = charging.firstIndex(where: { $0.id == id }) { charging[i].state = state }
        if case .keep = action {} else if case .update = action {} else { charging.removeAll { $0.id == id } }
    }
    func apply(_ action: ExistingActivityAction<DrivingActivityAttributes.ContentState>, toDriving id: String) async {
        log.append("driving.\(id).\(Self.name(action))")
        if case .update(let state) = action, let i = driving.firstIndex(where: { $0.id == id }) { driving[i].state = state }
        if case .keep = action {} else if case .update = action {} else { driving.removeAll { $0.id == id } }
    }
    func dismissEndedCharging() async {}
    func dismissEndedDriving() async {}
    func request(_ attributes: ChargingActivityAttributes, _ state: ChargingActivityAttributes.ContentState) {
        log.append("charging.request")
        charging.append(.init(id: "c\(charging.count + 1)", attributes: attributes, state: state))
    }
    func request(_ attributes: DrivingActivityAttributes, _ state: DrivingActivityAttributes.ContentState) {
        log.append("driving.request")
        driving.append(.init(id: "d\(driving.count + 1)", attributes: attributes, state: state))
    }
    /// When set, `end` suspends after dismissing the first charging id until released.
    var dismissalGate: Gate?
    func presentActivities(exceptVehicle keep: Int?) -> LiveActivityIDs {
        LiveActivityIDs(charging: charging.filter { $0.attributes.vehicleId != keep }.map(\.id),
                        driving: driving.filter { $0.attributes.vehicleId != keep }.map(\.id))
    }
    func end(_ ids: LiveActivityIDs) async {
        log.append("end(\((ids.charging + ids.driving).joined(separator: ",")))")
        for (index, id) in ids.charging.enumerated() {
            charging.removeAll { $0.id == id }
            if index == 0, let gate = dismissalGate { await gate.wait() }
        }
        for id in ids.driving { driving.removeAll { $0.id == id } }
        log.append("ended")
    }
    private static func name<S>(_ action: ExistingActivityAction<S>) -> String {
        switch action {
        case .keep: "keep"
        case .update: "update"
        case .finish: "finish"
        case .dismiss: "dismiss"
        }
    }
}

@MainActor private final class MemorySnapshotStore: WidgetSnapshotStoring {
    var snapshot: WidgetSnapshot?
    func read() -> WidgetSnapshot? { snapshot }
    func write(_ snapshot: WidgetSnapshot) throws { self.snapshot = snapshot }
    func reset() { snapshot = nil }
}

@MainActor final class WidgetSyncRaceTests: XCTestCase {
    private func settings() -> UserSettings {
        let name = "VoltaWidgetSyncTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserSettings(defaults: defaults)
    }

    private func waitForFetch(_ gate: Gate) async {
        for _ in 0..<400 {
            if await gate.arrivals > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("sync never reached the history fetch")
    }

    private let friday = VehicleSurfaceContext.vehicle(id: 1, name: "Friday")

    func testLaunchDemoDeletesSavedSnapshotAndEndsActivities() async throws {
        let driver = FakeActivityDriver(); driver.charging = [running("saved")]
        let store = MemorySnapshotStore()
        store.snapshot = WidgetSnapshot(status: status(updatedAt: .now), vehicleName: "Saved",
                                        summary: nil, timeline: nil)
        let sync = WidgetSync(settings: settings(), activities: driver, store: store)
        let model = AppModel(tokenStore: WidgetTestTokenStore(),
                             launchArguments: ["Volta", "-demo-mode", "YES"], surfaces: sync)
        await sync.drainCleanup()
        XCTAssertNil(store.snapshot); XCTAssertTrue(driver.charging.isEmpty)
        XCTAssertEqual(driver.log, ["end(saved)", "ended"])
        await model.loadVehicles()
        await DashboardModel().load(dataSource: model.dataSource, vehicleID: model.selectedVehicleID,
                                    surfaces: model.refreshSurfaces)
        await sync.drain()
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(driver.log, ["end(saved)", "ended"], "mock refresh cannot recreate surfaces")
        // Defensive rejection also holds even if a caller ignores the environment seam.
        let mockStatus = try await model.dataSource.status(vehicleID: model.selectedVehicleID)
        sync.publish(VehicleRefresh(status: mockStatus, issued: sync.nextStatusToken()), dataSource: model.dataSource)
        await sync.drain()
        XCTAssertNil(store.snapshot); XCTAssertTrue(driver.charging.isEmpty)
    }

    func testUnpairEndsActivitiesWithoutWaitingForStalledFetch() async {
        let driver = FakeActivityDriver(); driver.charging = [running("a")]
        let store = MemorySnapshotStore(); let gate = Gate()
        let sync = WidgetSync(settings: settings(), activities: driver, store: store)
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()

        sync.publish(VehicleRefresh(status: status(updatedAt: .now), issued: sync.nextStatusToken()), dataSource: GatedSource(gate: gate, charge: charge(id: 10)))
        XCTAssertNotNil(store.snapshot)
        await waitForFetch(gate)

        sync.setContext(.inactive)
        await sync.drainCleanup()
        XCTAssertEqual(driver.log, ["end(a)", "ended"], "activities end while the fetch is still blocked")
        XCTAssertTrue(driver.charging.isEmpty)
        XCTAssertNil(store.snapshot)

        await gate.release()
        await sync.drain()
        XCTAssertEqual(driver.log, ["end(a)", "ended"], "the obsolete sync must not touch activities afterwards")
        XCTAssertTrue(driver.charging.isEmpty)
    }

    func testVehicleSwitchEndsOtherVehicleWithoutWaitingForStalledFetch() async {
        let driver = FakeActivityDriver(); driver.charging = [running("a")]
        let gate = Gate()
        let sync = WidgetSync(settings: settings(), activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()

        sync.publish(VehicleRefresh(status: status(updatedAt: .now), issued: sync.nextStatusToken()), dataSource: GatedSource(gate: gate, charge: charge(id: 10)))
        await waitForFetch(gate)
        sync.setContext(.vehicle(id: 2, name: "Echo"))
        await sync.drainCleanup()
        XCTAssertEqual(driver.log, ["end(a)", "ended"])

        await gate.release()
        await sync.drain()
        XCTAssertEqual(driver.log, ["end(a)", "ended"])
        XCTAssertTrue(driver.charging.isEmpty)
    }

    func testChargingSyncStartsWhenNothingInterferes() async {
        let driver = FakeActivityDriver(); let gate = Gate()
        let sync = WidgetSync(settings: settings(), activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()
        await gate.release()
        sync.publish(VehicleRefresh(status: status(updatedAt: .now), issued: sync.nextStatusToken()), dataSource: GatedSource(gate: gate, charge: charge(id: 10)))
        await sync.drain()
        XCTAssertEqual(driver.log, ["charging.request"])
        XCTAssertEqual(driver.charging.first?.attributes.chargeId, 10)
    }

    func testDrivingStartsWhenEnabled() async {
        let settings = settings(); settings.drivingLiveActivity = true
        let driver = FakeActivityDriver(); let gate = Gate()
        let sync = WidgetSync(settings: settings, activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()
        await gate.release()
        sync.publish(VehicleRefresh(status: status(state: .driving, charging: nil, updatedAt: .now), issued: sync.nextStatusToken()),
                     dataSource: GatedSource(gate: gate, drive: drive(id: 20)))
        await sync.drain()
        XCTAssertEqual(driver.log, ["driving.request"])
    }

    func testTurningDrivingOffEndsItAndQueuedSyncDoesNotStartOne() async {
        let settings = settings(); settings.drivingLiveActivity = true
        let driver = FakeActivityDriver(); driver.driving = [drivingRunning("d", driveId: 20)]
        let gate = Gate()
        let sync = WidgetSync(settings: settings, activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()

        // A new drive: without the toggle this sync would replace "d" with a new activity.
        sync.publish(VehicleRefresh(status: status(state: .driving, charging: nil, updatedAt: .now), issued: sync.nextStatusToken()),
                     dataSource: GatedSource(gate: gate, drive: drive(id: 21)))
        await waitForFetch(gate)

        settings.drivingLiveActivity = false
        sync.drivingActivityPreferenceChanged()
        await sync.drainCleanup()
        XCTAssertEqual(driver.log, ["end(d)", "ended"], "ends immediately, not after the fetch")

        await gate.release()
        await sync.drain()
        XCTAssertEqual(driver.log, ["end(d)", "ended"], "the queued sync re-reads the preference")
        XCTAssertTrue(driver.driving.isEmpty)
    }

    /// Select B, B's cleanup suspends mid-dismissal, select A again, A's sync
    /// starts a driving activity: B's cleanup must not dismiss it.
    func testObsoleteCleanupCannotDismissActivityStartedAfterIt() async {
        let settings = settings(); settings.drivingLiveActivity = true
        let driver = FakeActivityDriver()
        driver.charging = [running("a"), running("b")]  // vehicle 1 (A)
        let sync = WidgetSync(settings: settings, activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        await sync.drainCleanup(); driver.log.removeAll()

        let dismissal = Gate()
        driver.dismissalGate = dismissal
        sync.setContext(.vehicle(id: 2, name: "Echo"))     // B: end A's cards, suspends after the first
        await waitForFetch(dismissal)
        XCTAssertEqual(driver.log, ["end(a,b)"])

        sync.setContext(friday)                            // back to A
        let fetch = Gate(); await fetch.release()
        sync.publish(VehicleRefresh(status: status(state: .driving, charging: nil, updatedAt: .now), issued: sync.nextStatusToken()),
                     dataSource: GatedSource(gate: fetch, drive: drive(id: 21)))
        await waitForFetch(fetch)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(driver.log, ["end(a,b)"], "A's sync waits for the cleanup ahead of it")

        await dismissal.release()
        await sync.drain()
        XCTAssertEqual(driver.log, ["end(a,b)", "ended", "driving.request"])
        XCTAssertEqual(driver.driving.map(\.attributes.driveId), [21], "the new activity survives")
        XCTAssertTrue(driver.charging.isEmpty)
    }

    func testCleanupEndsOnlyActivitiesPresentWhenRequested() async {
        let driver = FakeActivityDriver(); driver.charging = [running("a")]
        let sync = WidgetSync(settings: settings(), activities: driver, store: MemorySnapshotStore())
        sync.setContext(friday)
        sync.setContext(.inactive)
        driver.charging.append(running("late"))  // appears after the cleanup was requested
        await sync.drain()
        XCTAssertEqual(driver.log, ["end(a)", "ended"])
        XCTAssertEqual(driver.charging.map(\.id), ["late"])
    }

    /// Closing a charge drops its timestamps from the backend's `updatedAt`, so a
    /// newer-issued response can carry an older time. It must still win.
    func testNewerIssuedStatusWinsEvenWithOlderUpdatedAt() async {
        let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings(), activities: FakeActivityDriver(), store: store)
        sync.setContext(friday)
        let open = Gate(); await open.release()
        let at1010 = Date.now, at1000 = at1010.addingTimeInterval(-600)
        let first = sync.nextStatusToken(), second = sync.nextStatusToken()
        sync.publish(VehicleRefresh(status: status(battery: 70, updatedAt: at1010), issued: first),
                     dataSource: GatedSource(gate: open))
        sync.publish(VehicleRefresh(status: status(state: .online, charging: .complete, battery: 80, power: nil,
                                                   minutesToFull: nil, updatedAt: at1000), issued: second),
                     dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.batteryLevel, 80)
        XCTAssertEqual(store.snapshot?.updatedAt, at1000)
    }

    /// A drive closes without a new position: Controls (issued later) reports
    /// online and ends the driving activity; Dashboard's older-issued "driving"
    /// response with the same `updatedAt` arrives afterwards.
    func testOlderIssuedResponseWithEqualTimeIsRejected() async {
        let settings = settings(); settings.drivingLiveActivity = true
        let driver = FakeActivityDriver(); driver.driving = [drivingRunning("d", driveId: 20)]
        let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings, activities: driver, store: store)
        sync.setContext(friday)
        let open = Gate(); await open.release()
        let observed = Date.now
        let closed = drive(id: 20, end: observed.addingTimeInterval(-30))
        let dashboard = sync.nextStatusToken()   // Dashboard issues /status first...
        let controls = sync.nextStatusToken()    // ...Controls issues later and returns first.

        sync.publish(VehicleRefresh(status: status(state: .online, charging: nil, battery: 66, updatedAt: observed),
                                    issued: controls), dataSource: GatedSource(gate: open, drive: closed))
        await sync.drain()
        XCTAssertTrue(driver.driving.isEmpty, "the drive ended")
        let logAfterControls = driver.log

        sync.publish(VehicleRefresh(status: status(state: .driving, charging: nil, battery: 68, updatedAt: observed),
                                    issued: dashboard), dataSource: GatedSource(gate: open, drive: drive(id: 20)))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.batteryLevel, 66, "snapshot not regressed")
        XCTAssertEqual(driver.log, logAfterControls, "no activity work for the older-issued response")
        XCTAssertFalse(driver.log.contains("driving.request"), "the ended drive is not restarted")
        XCTAssertTrue(driver.driving.isEmpty)
    }

    /// Whatever the telemetry times do, the newest-issued response is always
    /// accepted, so the surfaces never freeze; only late older-issued ones drop.
    func testRefreshStreamNeverFreezes() async {
        let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings(), activities: FakeActivityDriver(), store: store)
        sync.setContext(friday)
        let open = Gate(); await open.release()
        let base = Date.now
        let offsets: [TimeInterval] = [0, -600, -600, -1200, 300, -3000, -3000, 60]  // up, down, equal
        for (index, offset) in offsets.enumerated() {
            let late = sync.nextStatusToken()       // issued, but its response arrives after the next one
            let issued = sync.nextStatusToken()
            let battery = 40 + index
            sync.publish(VehicleRefresh(status: status(state: .online, charging: nil, battery: battery,
                                                       updatedAt: base.addingTimeInterval(offset)), issued: issued),
                         dataSource: GatedSource(gate: open))
            sync.publish(VehicleRefresh(status: status(state: .online, charging: nil, battery: 99,
                                                       updatedAt: base.addingTimeInterval(3600)), issued: late),
                         dataSource: GatedSource(gate: open))
            XCTAssertEqual(store.snapshot?.batteryLevel, battery, "refresh \(index) accepted, late one dropped")
        }
        await sync.drain()
    }

    /// Dashboard lists car B before the app's own list has it. Choosing B must
    /// still switch the surfaces: A's widget and Live Activity go, B may publish.
    func testSelectingCarMissingFromAppListClearsPreviousAndPublishesIt() async throws {
        let listed = try JSONSerialization.data(withJSONObject: [["id": 1, "name": "Friday"]])
        StubProtocol.handler.withLock { $0 = { _ in (200, listed) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let settings = settings(); settings.serverURL = "https://volta.example"
        let tokens = WidgetTestTokenStore(); try tokens.save("synthetic-token")
        let driver = FakeActivityDriver(); driver.charging = [running("a")]
        let store = MemorySnapshotStore()
        store.snapshot = WidgetSnapshot(status: online(battery: 60), vehicleName: "Friday", summary: nil, timeline: nil)
        let sync = WidgetSync(settings: settings, activities: driver, store: store)
        let model = AppModel(settings: settings, tokenStore: tokens, session: URLSession(configuration: config),
                             launchArguments: ["Volta"], surfaces: sync)
        await model.loadVehicles()
        await sync.drainCleanup()
        XCTAssertEqual(sync.context, friday)
        XCTAssertEqual(driver.charging.map(\.id), ["a"])

        model.select(Vehicle(id: 2, name: "Echo"))
        XCTAssertEqual(model.selectedVehicleID, 2)
        XCTAssertEqual(sync.context, .vehicle(id: 2, name: "Echo"), "not .pending, which keeps A's surfaces")
        await sync.drainCleanup()
        XCTAssertNil(store.snapshot, "A's widget snapshot is cleared")
        XCTAssertTrue(driver.charging.isEmpty, "A's Live Activity is ended")

        let surfaces = try XCTUnwrap(model.refreshSurfaces)
        let open = Gate(); await open.release()
        var echo = online(battery: 70); echo.vehicleId = 2
        surfaces.publish(VehicleRefresh(status: echo, issued: surfaces.nextStatusToken()), dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.vehicleId, 2)
        XCTAssertEqual(store.snapshot?.batteryLevel, 70)
    }

    private func online(battery: Int) -> VehicleStatus {
        status(state: .online, charging: nil, battery: battery, power: nil, minutesToFull: nil, updatedAt: .now)
    }

    /// A refresh for A issued before switching A -> B -> A, delivered after
    /// returning to A, must not publish; requests issued afterwards do.
    func testRequestIssuedBeforeVehicleSwitchIsRejectedAfterReturning() async {
        let driver = FakeActivityDriver(); let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings(), activities: driver, store: store)
        let open = Gate(); await open.release()
        sync.setContext(friday)
        let current = sync.nextStatusToken()
        sync.publish(VehicleRefresh(status: online(battery: 60), issued: current), dataSource: GatedSource(gate: open))
        let stale = sync.nextStatusToken()  // A's slow refresh, still in flight

        sync.setContext(.vehicle(id: 2, name: "Echo"))
        sync.setContext(friday)
        sync.publish(VehicleRefresh(status: online(battery: 40), issued: stale), dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertNil(store.snapshot, "store was reset for B; the stale A refresh does not repopulate it")
        XCTAssertTrue(driver.log.isEmpty)

        sync.publish(VehicleRefresh(status: online(battery: 70), issued: sync.nextStatusToken()),
                     dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.batteryLevel, 70)
    }

    func testRequestIssuedBeforeUnpairOrDemoIsRejected() async {
        let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings(), activities: FakeActivityDriver(), store: store)
        let open = Gate(); await open.release()
        sync.setContext(friday)
        let stale = sync.nextStatusToken()
        sync.setContext(.inactive)
        sync.setContext(.pending)
        let afterRepair = sync.nextStatusToken()  // issued while vehicles load
        sync.setContext(friday)
        sync.publish(VehicleRefresh(status: online(battery: 40), issued: stale), dataSource: GatedSource(gate: open))
        XCTAssertNil(store.snapshot)
        sync.publish(VehicleRefresh(status: online(battery: 70), issued: afterRepair), dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.batteryLevel, 70)
        XCTAssertGreaterThan(sync.nextStatusToken(), afterRepair, "tokens keep increasing")
    }

    /// Launch: Dashboard issues /status for the saved vehicle while the vehicle
    /// list is still loading (.pending); its refresh still publishes.
    func testLaunchRefreshIssuedWhilePendingPublishes() async {
        let store = MemorySnapshotStore()
        let sync = WidgetSync(settings: settings(), activities: FakeActivityDriver(), store: store)
        let open = Gate(); await open.release()
        sync.setContext(.pending)
        let issued = sync.nextStatusToken()
        sync.setContext(friday)
        sync.publish(VehicleRefresh(status: online(battery: 70), issued: issued), dataSource: GatedSource(gate: open))
        await sync.drain()
        XCTAssertEqual(store.snapshot?.batteryLevel, 70)
    }

    func testControlsAndDashboardTakeTokenBeforeRequest() async {
        let surfaces = RecordingSurfaces()
        await DashboardModel().load(dataSource: MockDataSource(empty: false), vehicleID: MockDataSource.vehicleID,
                                    surfaces: surfaces)
        XCTAssertEqual(surfaces.published.last?.issued, StatusRequestToken(value: 1))

        let controls = ControlsModel(status: nil)
        await controls.refresh(dataSource: MockDataSource(empty: false), vehicleID: MockDataSource.vehicleID,
                               surfaces: surfaces)
        XCTAssertEqual(surfaces.published.last?.issued, StatusRequestToken(value: 2))
    }
}
