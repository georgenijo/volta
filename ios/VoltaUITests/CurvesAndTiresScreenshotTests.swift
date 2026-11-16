import XCTest

/// Charge curve comparison and tire pressure history in demo mode: the flows
/// the owner uses, with screenshots attached at each state.
@MainActor
final class CurvesAndTiresScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    private func launch(_ extra: [String] = []) {
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-VoltaDisableMotion"] + extra
        app.launch()
    }

    // MARK: Comparison

    func testChargeCurveComparison() throws {
        defer { app.terminate() }
        launch(["-demoTab", "charging", "-demoOpenCharge", "fast"])
        try wait("screen.charge-detail")
        try scrollTo("charge.compare", in: "scroll.charge-detail")
        try tap("charge.compare")
        try wait("screen.charge-comparison")
        // The session and the two newest at the same Supercharger.
        try wait("comparison.chart")
        try wait("comparison.window")
        capture("comparison-three")

        try tap("comparison.edit")
        try wait("comparison.picker.count")
        capture("comparison-picker")
        try pick(11)
        XCTAssertEqual(element("comparison.picker.count").label, "2 of 5 chosen")
        try closePicker()
        try wait("comparison.chart")
        capture("comparison-two")

        try tap("comparison.edit")
        try tapButton("All")
        for id in [2, 4, MockIDs.noCurve] { try pick(id) }
        XCTAssertEqual(element("comparison.picker.count").label, "5 of 5 chosen. Remove one to add another.")
        // A disabled row is never hittable, so scroll until it is on screen.
        let sixth = element("comparison.pick.3"), window = app.windows.firstMatch
        for _ in 0..<10 where !(sixth.exists && window.frame.contains(sixth.frame)) {
            swipe(element("scroll.comparison-picker"), up: true)
        }
        XCTAssertTrue(sixth.exists)
        XCTAssertFalse(sixth.isEnabled, "a sixth session can't be added")
        capture("comparison-picker-full")
        try closePicker()
        try wait("comparison.chart")
        capture("comparison-five")
        XCTAssertTrue(element("comparison.session.\(MockIDs.noCurve)").label.contains("No curve recorded"))
        swipe(element("scroll.charge-comparison"), up: true)
        capture("comparison-five-sessions")
        // Tapping a session picks out its line.
        try scrollTo("comparison.session.2", in: "scroll.charge-comparison")
        try tap("comparison.session.2")
        XCTAssertTrue(element("comparison.session.2").isSelected)
        for _ in 0..<3 { swipe(element("scroll.charge-comparison"), up: false) }
        capture("comparison-highlight")
        try scrollTo("comparison.session.2", in: "scroll.charge-comparison")
        try tap("comparison.session.2")

        for _ in 0..<3 { swipe(element("scroll.charge-comparison"), up: false) }
        try tapButton("TIME")
        try waitForLabel("comparison.chart", containing: "over time")
        capture("comparison-time")

        try tap("comparison.edit")
        try tapButton("All")
        for id in [-1, -6, 2, 4, MockIDs.noCurve] { try pick(id) }
        try closePicker()
        try wait("comparison.empty")
        capture("comparison-empty")
    }

    func testCompareFromChargingInsights() throws {
        defer { app.terminate() }
        launch(["-demoTab", "more"])
        try scrollTo("row.more.charging-insights", in: "scroll.more", optional: true)
        if !element("row.more.charging-insights").exists { app.buttons["Charging Insights"].firstMatch.tap() } else { try tap("row.more.charging-insights") }
        try wait("screen.charging-insights")
        try scrollTo("insights.compare.home-away", in: "scroll.charging-insights")
        capture("insights-compare")
        try tap("insights.compare.home-away")
        try wait("screen.charge-comparison")
        try wait("comparison.chart")
        capture("comparison-home-away")
    }

    func testComparisonReadout() throws {
        defer { app.terminate() }
        launch(["-demoTab", "charging", "-demoOpenCharge", "fast", "-demoComparisonSelect", "60"])
        try wait("screen.charge-detail")
        try scrollTo("charge.compare", in: "scroll.charge-detail")
        try tap("charge.compare")
        try wait("comparison.verdict")
        try waitForValue("comparison.chart", containing: "Selected 60%")
        capture("comparison-readout")
    }

    // MARK: Tires

    func testTireHistory() throws {
        defer { app.terminate() }
        launch(["-demoTab", "more"])
        try openTires()
        try scrollTo("tires.history.chart", in: "scroll.tires")
        try wait("tires.history.apart")
        // The flagged wheel is focused from the start, its value at the line's end.
        try waitForValue("tires.history.chart", containing: "Rear left focused, latest")
        try wait("tires.history.bandLegend")
        try scrollTo("tires.history.legend.rl", in: "scroll.tires")
        XCTAssertTrue(element("tires.history.legend.rl").isSelected)
        capture("tires-history")
        try tap("tires.history.legend.rl")
        XCTAssertFalse(element("tires.history.bandLegend").exists, "no focus, no band")
        capture("tires-history-all")
        swipe(element("scroll.tires"), up: true)
        try wait("tires.rotation")
        capture("tires-history-rows")
    }

    func testTireHistoryMissingWheel() throws {
        defer { app.terminate() }
        launch(["-demoTab", "more", "-demoTireMissingWheel", "YES"])
        try openTires()
        try scrollTo("tires.history.chart", in: "scroll.tires")
        try scrollTo("tires.history.legend.rr", in: "scroll.tires")
        XCTAssertEqual(element("tires.history.legend.rr").label, "Rear right, no data")
        XCTAssertEqual(element("tires.history.legend.rr").elementType, .staticText, "a wheel without readings is not a control")
        capture("tires-missing-wheel")
        swipe(element("scroll.tires"), up: true)
        XCTAssertTrue(element("tires.history.rr").label.contains("No readings"))
        capture("tires-missing-wheel-rows")
    }

    func testTireHistoryReadout() throws {
        defer { app.terminate() }
        launch(["-demoTab", "more", "-demoTireSelectDaysAgo", "20"])
        try openTires()
        try scrollTo("tires.history.chart", in: "scroll.tires")
        try waitForValue("tires.history.chart", containing: "Selected")
        // The legend sits under the chart: once it is on screen, so is all of the chart.
        try scrollTo("tires.history.legend.rl", in: "scroll.tires")
        capture("tires-readout")
    }

    func testTireHistoryEmpty() throws {
        defer { app.terminate() }
        launch(["-demoTab", "more", "-demoTireHistoryEmpty", "YES"])
        try openTires()
        try scrollTo("tires.history.empty", in: "scroll.tires")
        swipe(element("scroll.tires"), up: true)
        capture("tires-empty")
    }

    // MARK: Helpers

    private enum MockIDs { static let noCurve = 13 }

    private func openTires() throws {
        try wait("scroll.more")
        try scrollTo("row.more.tires", in: "scroll.more")
        try tap("row.more.tires")
        try wait("screen.tires")
    }

    /// iPhone Duo hides a sheet's navigation bar while its list scrolls down
    /// and shows it again on the way back up.
    private func closePicker() throws {
        let done = element("comparison.picker.done")
        for _ in 0..<4 where !(done.exists && done.isHittable) {
            swipe(element("scroll.comparison-picker"), up: false)
        }
        try tap("comparison.picker.done")
    }

    private func pick(_ id: Int) throws {
        try scrollTo("comparison.pick.\(id)", in: "scroll.comparison-picker")
        try tap("comparison.pick.\(id)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(_ identifier: String) throws {
        guard element(identifier).waitForExistence(timeout: 20) else {
            capture("failure-\(identifier)")
            XCTFail("Missing \(identifier)")
            throw Failure.missing(identifier)
        }
    }

    /// Swipes `container` until `identifier` is on screen and hittable. The
    /// swipe runs down the side gutter, so it never lands on a chart and
    /// opens its readout.
    private func scrollTo(_ identifier: String, in container: String, optional: Bool = false) throws {
        let target = element(identifier), scroll = element(container)
        _ = scroll.waitForExistence(timeout: 20)
        for _ in 0..<10 where !(target.exists && target.isHittable) {
            swipe(scroll, up: true)
        }
        if !optional && !(target.exists && target.isHittable) {
            capture("failure-\(identifier)")
            XCTFail("Could not scroll to \(identifier)")
            throw Failure.missing(identifier)
        }
    }

    /// A slow swipe down the left gutter, clear of the charts' touch readouts.
    private func swipe(_ scroll: XCUIElement, up: Bool) {
        let low = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.75))
        let high = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.35))
        (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low, withVelocity: .slow, thenHoldForDuration: 0)
    }

    private func waitForLabel(_ identifier: String, containing text: String) throws {
        let ready = NSPredicate(format: "label CONTAINS %@", text)
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element(identifier))], timeout: 15) == .completed else {
            capture("failure-\(identifier)")
            XCTFail("\(identifier) never showed \(text)")
            throw Failure.missing(identifier)
        }
    }

    private func waitForValue(_ identifier: String, containing text: String) throws {
        let ready = NSPredicate(format: "value CONTAINS %@", text)
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element(identifier))], timeout: 15) == .completed else {
            capture("failure-\(identifier)")
            XCTFail("\(identifier) never showed \(text)")
            throw Failure.missing(identifier)
        }
    }

    private func tap(_ identifier: String) throws {
        let target = element(identifier)
        let ready = NSPredicate(format: "exists == true AND hittable == true")
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: target)], timeout: 15) == .completed else {
            capture("failure-\(identifier)")
            XCTFail("Missing or obscured \(identifier)")
            throw Failure.missing(identifier)
        }
        target.tap()
    }

    private func tapButton(_ label: String) throws {
        let button = app.buttons[label].firstMatch
        guard button.waitForExistence(timeout: 10) else { XCTFail("Missing button \(label)"); throw Failure.missing(label) }
        button.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum Failure: Error { case missing(String) }
}
