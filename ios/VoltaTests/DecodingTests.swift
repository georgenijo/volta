import XCTest
@testable import Volta

final class DecodingTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: DecodingTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "shapes", withExtension: "json") ?? bundle.url(forResource: "shapes", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(root[name]))
    }
    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try APIDataSource.makeDecoder().decode(type, from: Self.fixture(name)) }
    func testEveryAPIShape() throws {
        XCTAssertTrue(try decode(HealthResponse.self, "health").teslamate.reachable)
        XCTAssertNil(try decode(Device.self, "device").lastSeenAt)
        XCTAssertEqual(try decode(PairResponse.self, "pair").device.id, 1)
        XCTAssertEqual(try decode(Vehicle.self, "vehicle").name, "Friday")
        let status = try decode(VehicleStatus.self, "status")
        XCTAssertEqual(status.state, .online); XCTAssertNil(status.estRangeKm); XCTAssertEqual(status.location?.placeName, "Home")
        XCTAssertNil(try decode(Location.self, "location").heading)
        let summary = try decode(ActivitySummary.self, "summary")
        XCTAssertEqual(summary.range, .sevenDays)
        XCTAssertNil(summary.periodStart); XCTAssertNil(summary.periodEnd); XCTAssertNil(summary.timeZone)
        XCTAssertEqual(try decode(TimelineSegment.self, "timeline").kind, .drive)
        XCTAssertEqual(try decode(DriveSummary.self, "drive").distanceKm, 24.8)
        XCTAssertNil(try decode(DrivePoint.self, "drivePoint").powerKw)
        XCTAssertEqual(try decode(ChargeSummary.self, "charge").fastCharger, true)
        XCTAssertEqual(try decode(ChargeSample.self, "chargeSample").batteryLevel, 80)
        XCTAssertNil(try decode(IdleSummary.self, "idle").startBatteryLevel)
        XCTAssertNil(try decode(BatteryHealthPoint.self, "batteryPoint").capacityKwh)
        XCTAssertEqual(try decode(BatteryHealth.self, "battery").history.count, 1)
        XCTAssertEqual(try decode(MileageBucket.self, "mileage").driveCount, 1)
        XCTAssertNil(try decode(FirmwareUpdate.self, "firmware").previousVersion)
        XCTAssertEqual(try decode(Place.self, "place").costPerKwh, 0.23)
        XCTAssertEqual(try decode(Page<DriveSummary>.self, "drivePage").nextCursor, "opaque+cursor/=")
        XCTAssertNil(try decode(Page<ChargeSummary>.self, "chargePage").nextCursor)
        XCTAssertTrue(try decode(Page<IdleSummary>.self, "idlePage").items.isEmpty)
    }
    func testDriveScoreAliasesRouteAndNegativeIDRoundTrip() throws {
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("drive")) as? [String: Any])
        row["id"] = -10
        row["end"] = "2026-10-06T12:30:00Z" // Whole seconds isolate the score Codable round trip.
        row["driveScore"] = 71
        row["efficiencyScore"] = 87
        row["route"] = [["t": "2026-10-08T12:00:00Z", "latitude": 37.4, "longitude": -122.1, "routeBreakBefore": true]]
        func decode() throws -> DriveSummary {
            try APIDataSource.makeDecoder().decode(DriveSummary.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let current = try decode()
        XCTAssertEqual(current.id, -10)
        XCTAssertEqual(current.efficiencyScore, 71)
        XCTAssertEqual(current.route?.first?.routeBreakBefore, true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try APIDataSource.makeDecoder().decode(DriveSummary.self, from: encoder.encode(current)), current)
        row.removeValue(forKey: "driveScore")
        XCTAssertEqual(try decode().efficiencyScore, 87)
        row.removeValue(forKey: "efficiencyScore")
        XCTAssertNil(try decode().efficiencyScore)
        var positive = current; positive.id = 10
        XCTAssertEqual(Set([current, positive]).count, 2)
    }
    func testZonedSummaryPeriod() throws {
        let json = #"{"range":"today","distanceKm":12,"driveCount":1,"chargeCount":0,"energyUsedKwh":null,"efficiencyWhPerKm":null,"energyAddedKwh":null,"chargeCost":null,"currency":"USD","periodStart":"2026-07-01T04:00:00.000Z","periodEnd":"2026-07-01T16:30:00.123Z","timeZone":"America/New_York"}"#
        let summary = try APIDataSource.makeDecoder().decode(ActivitySummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.periodStart, Date(timeIntervalSince1970: 1_782_878_400))
        XCTAssertEqual(try XCTUnwrap(summary.periodEnd).timeIntervalSince1970, 1_782_923_400.123, accuracy: 0.001)
        XCTAssertEqual(summary.timeZone, "America/New_York")
    }
    func testFlattenedDetailsAndRoundTrip() throws {
        let drive = try decode(DriveDetail.self, "driveDetail")
        XCTAssertEqual(drive.summary.id, 10); XCTAssertEqual(drive.path.count, 1); XCTAssertEqual(drive.elevationGainM, 86)
        let charge = try decode(ChargeDetail.self, "chargeDetail")
        XCTAssertEqual(charge.summary.id, 20); XCTAssertEqual(charge.samples.count, 1); XCTAssertEqual(charge.efficiency, 0.92)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for data in [try encoder.encode(drive), try encoder.encode(charge)] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(root["id"]); XCTAssertNil(root["summary"])
        }
    }
    func testFractionalAndWholeSecondDates() throws {
        let detail = try decode(DriveDetail.self, "driveDetail")
        XCTAssertEqual(try XCTUnwrap(detail.summary.end).timeIntervalSince(detail.summary.start), 1800.123, accuracy: 0.001)
        XCTAssertThrowsError(try APIDataSource.makeDecoder().decode(Device.self, from: Data(#"{"id":1,"name":"test","createdAt":"invalid","lastSeenAt":null}"#.utf8)))
    }
    func testMicrosecondsAndOffsetDates() throws {
        let json = Data(#"{"id":1,"name":"Test","createdAt":"2026-10-06T12:00:00.123456+00:00","lastSeenAt":"2026-10-06T12:00:00Z"}"#.utf8)
        let device = try APIDataSource.makeDecoder().decode(Device.self, from: json)
        XCTAssertEqual(device.createdAt.timeIntervalSince(try XCTUnwrap(device.lastSeenAt)), 0.123456, accuracy: 0.00001)
    }
    func testAllEnumWireValues() throws {
        let decoder = APIDataSource.makeDecoder()
        for value in ["online", "asleep", "offline", "driving", "charging", "updating"] { _ = try decoder.decode(VehicleState.self, from: Data("\"\(value)\"".utf8)) }
        for value in ["disconnected", "stopped", "charging", "complete"] { _ = try decoder.decode(ChargingState.self, from: Data("\"\(value)\"".utf8)) }
        for value in ["drive", "charge", "idle", "asleep", "offline"] { _ = try decoder.decode(TimelineKind.self, from: Data("\"\(value)\"".utf8)) }
    }
}
