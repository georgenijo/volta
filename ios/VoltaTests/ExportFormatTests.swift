import XCTest
@testable import Volta

final class ExportFormatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z

    // MARK: CSV

    func testCSVEscaping() {
        XCTAssertEqual(CSVExport.escape("plain"), "plain")
        XCTAssertEqual(CSVExport.escape("Palo Alto, CA"), "\"Palo Alto, CA\"")
        XCTAssertEqual(CSVExport.escape("The \"Lot\""), "\"The \"\"Lot\"\"\"")
        XCTAssertEqual(CSVExport.escape("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(CSVExport.escape("cr\r"), "\"cr\r\"")
        XCTAssertEqual(CSVExport.row(["a", "b,c", ""]), "a,\"b,c\",\r\n")
    }

    func testCSVTextGuardsFormulas() {
        XCTAssertEqual(CSVExport.text("=HYPERLINK(\"x\")"), "'=HYPERLINK(\"x\")")
        XCTAssertEqual(CSVExport.text("+1"), "'+1")
        XCTAssertEqual(CSVExport.text("-x"), "'-x")
        XCTAssertEqual(CSVExport.text("@sum"), "'@sum")
        XCTAssertEqual(CSVExport.text("100 Example Ave"), "100 Example Ave")
        XCTAssertEqual(CSVExport.text(nil), "")
        // Numbers are not text: a negative temperature stays a number.
        XCTAssertEqual(CSVExport.number(-3.25, digits: 1), "-3.2")
    }

    func testCSVValuesAreLocaleFreeAndUnknownIsEmpty() {
        XCTAssertEqual(CSVExport.number(12345.678), "12345.678")
        XCTAssertEqual(CSVExport.number(2), "2")
        XCTAssertEqual(CSVExport.number(nil), "")
        XCTAssertEqual(CSVExport.number(.nan), "")
        XCTAssertEqual(CSVExport.integer(nil), "")
        XCTAssertEqual(CSVExport.bool(true), "true")
        XCTAssertEqual(CSVExport.date(t0), "2026-09-21T14:13:20Z")
    }

    func testChargesCSVKeepsUnknownCostEmpty() {
        let charge = ChargeSummary(id: 7, start: t0, end: nil, address: "100 Example Ave, Palo Alto", placeName: "Home",
                                   energyAddedKwh: 22.5, energyUsedKwh: nil, startBatteryLevel: 40, endBatteryLevel: 80,
                                   durationMin: 190, maxPowerKw: 7.7, fastCharger: false, cost: nil, currency: "USD", outsideTempAvgC: nil)
        let csv = CSVExport.charges([charge])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3, "header, one row, trailing empty after the final CRLF")
        XCTAssertTrue(lines[0].hasPrefix("id,start_utc,end_utc,place_name,address,energy_added_kwh"))
        XCTAssertEqual(lines[1], "7,2026-09-21T14:13:20Z,,Home,\"100 Example Ave, Palo Alto\",22.5,,,40,80,190,7.7,,false,,,,")
        XCTAssertEqual(lines[0].split(separator: ",").count, lines[1].split(separator: ",", omittingEmptySubsequences: false).count - 1,
                       "the quoted address holds one comma")
    }

    func testDrivesAndIdlesCSVHeadersMatchRowWidths() {
        let drive = DriveSummary(id: 1, start: t0, end: t0.addingTimeInterval(600), startAddress: "A", endAddress: "B",
                                 distanceKm: 10, durationMin: 10, startBatteryLevel: 80, endBatteryLevel: 78, energyUsedKwh: 1.6,
                                 efficiencyWhPerKm: 160, maxSpeedKph: 90, avgSpeedKph: 60, outsideTempAvgC: -2)
        let idle = IdleSummary(id: 2, start: t0, end: nil, address: nil, placeName: nil, durationMin: 60, startBatteryLevel: nil,
                               endBatteryLevel: nil, rangeLostKm: nil, energyLostKwh: nil, sentryMinutes: nil, climateMinutes: nil,
                               asleepMinutes: nil)
        for csv in [CSVExport.drives([drive]), CSVExport.idles([idle])] {
            let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(lines[0].split(separator: ",").count,
                           lines[1].split(separator: ",", omittingEmptySubsequences: false).count)
        }
        XCTAssertTrue(CSVExport.drives([drive]).contains(",-2,"))
    }

    // MARK: GPX

    private func detail(_ path: [DrivePoint], telemetry: FleetTelemetrySeries? = nil) -> DriveDetail {
        let summary = DriveSummary(id: 3, start: t0, end: nil, startAddress: nil, endAddress: nil, distanceKm: 1, durationMin: 2,
                                   startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: nil, efficiencyWhPerKm: nil,
                                   maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
        var detail = DriveDetail(summary: summary, path: path, elevationGainM: nil, telemetry: telemetry)
        detail.path = path
        return detail
    }

    private func point(_ s: Double, _ lat: Double, _ lon: Double, ele: Double? = nil, breakBefore: Bool? = nil) -> DrivePoint {
        DrivePoint(t: t0.addingTimeInterval(s), latitude: lat, longitude: lon, speedKph: nil, powerKw: nil, elevationM: ele,
                   batteryLevel: nil, routeBreakBefore: breakBefore)
    }

    func testGPXStructureSplitsSegmentsAtBreaks() throws {
        let gpx = try XCTUnwrap(GPXExport.document(detail([
            point(10, 37.4419, -122.143, ele: 12.34), point(0, 37.44, -122.14),
            point(20, 37.45, -122.15, breakBefore: true), point(30, .nan, -122.15),
        ]), name: "Drive <A & B>"))
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Volta\" xmlns=\"http://www.topografix.com/GPX/1/1\">"))
        XCTAssertTrue(gpx.contains("<name>Drive &lt;A &amp; B&gt;</name>"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, 3, "the NaN point is dropped")
        // Time-ordered: the t=0 point comes first.
        let first = try XCTUnwrap(gpx.range(of: "<trkpt lat=\"37.44\" lon=\"-122.14\"><time>2026-09-21T14:13:20Z</time>"))
        let second = try XCTUnwrap(gpx.range(of: "<trkpt lat=\"37.4419\" lon=\"-122.143\"><ele>12.3</ele>"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertTrue(gpx.hasSuffix("</trk>\n</gpx>\n"))
        // Well-formed XML.
        let parser = XMLParser(data: Data(gpx.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError.map(String.init(describing:)) ?? "")
    }

    func testGPXFallsBackToTelemetryAndIsNilWithoutPositions() throws {
        XCTAssertNil(GPXExport.document(detail([]), name: "x"))
        let samples = [FleetTelemetrySample(t: t0, latitude: 37.4, longitude: -122.1, speedKph: nil, powerKw: nil, elevationM: nil,
                                            batteryLevel: nil, energyRemainingKwh: nil, batteryTempMinC: nil, batteryTempMaxC: nil,
                                            insideTempC: nil, outsideTempC: nil, voltage: nil, currentA: nil, ratedRangeKm: nil,
                                            routeBreakBefore: false),
                       FleetTelemetrySample(t: t0.addingTimeInterval(1), latitude: nil, longitude: nil, speedKph: 40, powerKw: nil,
                                            elevationM: nil, batteryLevel: nil, energyRemainingKwh: nil, batteryTempMinC: nil,
                                            batteryTempMaxC: nil, insideTempC: nil, outsideTempC: nil, voltage: nil, currentA: nil,
                                            ratedRangeKm: nil, routeBreakBefore: false)]
        let series = FleetTelemetrySeries(source: "fleet_telemetry", samples: samples, gaps: [], truncated: false)
        let gpx = try XCTUnwrap(GPXExport.document(detail([], telemetry: series), name: "x"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, 1)
    }

    func testGPXFileNameHasNoAddress() {
        let drive = DriveSummary(id: 3, start: t0, end: nil, startAddress: "100 Example Ave", endAddress: nil, distanceKm: 1,
                                 durationMin: 2, startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: nil,
                                 efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(GPXExport.fileName(for: drive, timeZone: utc), "volta-drive-2026-09-21-1413.gpx")
        XCTAssertEqual(GPXExport.name(for: drive, timeZone: utc), "Volta drive 2026-09-21 14:13")
    }
}
