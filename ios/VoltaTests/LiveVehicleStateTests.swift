import XCTest
@testable import Volta

final class LiveVehicleStateTests: XCTestCase {
    func testPressureConversionsAndThreshold() {
        var units = UnitPreferences.default
        XCTAssertEqual(units.pressureValue(bar: 2.9), 42.06094, accuracy: 0.001)
        units.pressure = .bar
        XCTAssertEqual(units.pressureValue(bar: 2.9), 2.9)
        XCTAssertTrue(TireReading(pressureBar: 2.3, updatedAt: nil).isLow)
        XCTAssertFalse(TireReading(pressureBar: nil, updatedAt: nil).isLow)
        XCTAssertFalse(TireReading(pressureBar: 2.5, updatedAt: nil).isLow)
    }
    func testOldUnitSettingsDecodeWithoutPressure() throws {
        let data = Data(#"{"distance":"miles","temperature":"fahrenheit","currency":"USD"}"#.utf8)
        let units = try JSONDecoder().decode(UnitPreferences.self, from: data)
        XCTAssertEqual(units.pressureUnit, "psi")
    }
    func testDisconnectedFreshnessLabelsLastObservation() {
        let freshness = TelemetryFreshness(connected: false, lastSeenAt: Date(timeIntervalSince1970: 0), recordedAt: [:])
        XCTAssertTrue(freshness.label.contains("as of"))
    }
}
