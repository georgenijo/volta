import XCTest
@testable import Volta

final class ServiceTests: XCTestCase {
    func testIntervalsAreMetricAndInvalidInputIsRejected() throws {
        let item = try XCTUnwrap(ServiceFormValidation.item(name: "Rotation", distance: "6250", months: "", units: .default))
        XCTAssertEqual(try XCTUnwrap(item.intervalKm), 10058.4, accuracy: 0.001)
        XCTAssertNil(ServiceFormValidation.item(name: "", distance: "10", months: "", units: .default))
        XCTAssertNil(ServiceFormValidation.item(name: "Wipers", distance: "", months: "1.5", units: .default))
        XCTAssertNil(ServiceFormValidation.item(name: "Wipers", distance: "nan", months: "12", units: .default))
        XCTAssertNil(ServiceFormValidation.item(name: "Wipers", distance: "-1", months: "12", units: .default))
        XCTAssertNil(ServiceFormValidation.item(name: "Wipers", distance: "", months: "", units: .default))
    }
    func testUnknownCurrencyIsNeverDefaulted() {
        XCTAssertTrue(ChargerPresentation.cost(12, currency: nil).contains("currency unknown"))
        XCTAssertTrue(ChargerPresentation.cost(nil, currency: "USD").contains("Cost unknown"))
    }
    func testServiceContractDecodesUnknowns() throws {
        let json = #"{"odometerKm":null,"recordedAt":null,"source":null,"items":[{"id":"test","name":"Filter","intervalKm":null,"intervalMonths":24,"nextDate":null,"nextOdometerKm":null,"remainingKm":null,"remainingDays":null,"progress":null}],"events":[]}"#
        let state = try APIDataSource.makeDecoder().decode(ServiceState.self, from: Data(json.utf8))
        XCTAssertNil(state.odometerKm); XCTAssertNil(state.items[0].progress)
    }
}
