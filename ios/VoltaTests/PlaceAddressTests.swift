import XCTest
@testable import Volta

final class PlaceAddressTests: XCTestCase {
    private func pill(_ address: String?, place: String? = nil) -> (String, String?) {
        let location = Location(latitude: 37.4419, longitude: -122.1430, heading: nil, address: address, placeName: place)
        return (AddressPill.title(for: location), AddressPill.locality(for: location))
    }

    func testOpenStreetMapNameSkipsTheHouseNumber() {
        let (title, town) = pill("Coffee Shop, 120, University Avenue, Downtown North, Palo Alto, Santa Clara County, California, 94301, United States")
        XCTAssertEqual(title, "Coffee Shop")
        XCTAssertEqual(town, "Palo Alto")
    }

    func testOpenStreetMapStreetAddressJoinsNumberAndStreet() {
        let (title, town) = pill("120, University Avenue, Palo Alto, Santa Clara County, California, 94301, United States")
        XCTAssertEqual(title, "120 University Avenue")
        XCTAssertEqual(town, "Palo Alto")
    }

    func testOpenStreetMapWithoutCounty() {
        XCTAssertEqual(pill("Main Street, Union City, California, 94587, United States").1, "Union City")
    }

    func testSavedPlaceShowsTheTown() {
        XCTAssertEqual(pill("Palo Alto, CA", place: "Home").1, "Palo Alto")
        XCTAssertEqual(pill("120, University Avenue, Palo Alto, Santa Clara County, California, 94301, United States",
                            place: "Office").1, "Palo Alto")
    }

    func testShortAddressesKeepTheirOrder() {
        XCTAssertEqual(pill("Main Street, Palo Alto, CA").0, "Main Street")
        XCTAssertEqual(pill("Main Street, Palo Alto, CA").1, "Palo Alto")
        XCTAssertNil(pill("Palo Alto").1)
        XCTAssertEqual(pill(nil).0, "Unknown location")
    }

    func testNumbers() {
        for n in ["120", "120A", "12-14", "94301", "94301-1234"] { XCTAssertTrue(PlaceAddress.isNumber(n), n) }
        for w in ["1st Street", "Route 1", "A1", "Downtown North"] { XCTAssertFalse(PlaceAddress.isNumber(w), w) }
    }
}
