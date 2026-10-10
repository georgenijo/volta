import XCTest

/// Independent launches let completed screens produce evidence while other screens land.
@MainActor
final class ScreenScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    // Synchronous XCTest setup overrides are nonisolated. Keep UI work on the
    // main actor inside each test, including cleanup when navigation throws.
    private func launchDemo() throws {
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES"]
        app.launch()
        try waitForScreen("dashboard")
    }

    func testDashboard() throws {
        defer { app.terminate() }
        try launchDemo()
        try tap("tab.dashboard")
        try waitForScreen("dashboard")
        capture("dashboard-map")
        try scroll("dashboard", screenshot: "dashboard-mid")
        try scroll("dashboard", screenshot: "dashboard-scrolled")
    }

    func testCharging() throws {
        defer { app.terminate() }
        try launchDemo()
        try tap("tab.charging")
        try waitForScreen("charging")
        capture("charging")
    }

    func testDrives() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        capture("drives")
        try scroll("drives", screenshot: "drives-day-sections")
    }

    func testDrivesPagination() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        let container = element("scroll.drives")
        let last = element("row.drive.60")
        for _ in 0..<45 {
            if last.exists && last.isHittable { break }
            container.swipeUp()
        }
        XCTAssertTrue(last.exists && last.isHittable, "Scrolling must load the second page and expose the final synthetic drive")
        capture("drives-last-page")
    }

    func testIdles() throws {
        defer { app.terminate() }
        try launchDemo()
        try tap("tab.idles")
        try waitForScreen("idles")
        capture("idles")
    }

    func testMore() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMore()
        capture("more-top")
        try scroll("more", screenshot: "more-bottom")
    }

    func testSettings() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMore()
        try tap("button.settings")
        try waitForScreen("settings")
        capture("settings-top")
        try scroll("settings", screenshot: "settings-bottom")
    }

    func testDriveDetail() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        try tapFirstRow(prefix: "row.drive.")
        try waitForScreen("drive-detail")
        capture("drive-detail")
        try scroll("drive-detail", screenshot: "drive-detail-scrolled")
    }

    func testChargeDetail() throws {
        defer { app.terminate() }
        try launchDemo()
        try tap("tab.charging")
        try waitForScreen("charging")
        try tapFirstRow(prefix: "row.charge.")
        try waitForScreen("charge-detail")
        capture("charge-detail")
    }

    func testControls() throws {
        defer { app.terminate() }
        try launchDemo()
        try tap("button.controls")
        try waitForScreen("controls")
        capture("controls-top")
        try scroll("controls", screenshot: "controls-bottom")
    }

    func testTeslaSignInNoVehicle() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demoNoVehicles", "YES"]
        app.launch()
        try waitForElement("button.teslaSignIn")
        capture("tesla-no-vehicle")
    }

    func testAccountTesla() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMore()
        try tap("button.settings")
        try waitForScreen("settings")
        try tap("button.account")
        try waitForElement("button.teslaSignIn")
        capture("settings-account")
    }

    // MARK: Analytics (More tab rows) and drive overviews (Drives tab chips)

    func testStats() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("stats", screen: "stats")
        capture("stats-top")
        try scroll("stats", screenshot: "stats-scrolled")
    }

    func testBatteryHealth() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("battery-health", screen: "battery-health")
        capture("battery-health-top")
        try scroll("battery-health", screenshot: "battery-health-scrolled")
    }

    func testBatteryClimate() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("battery-climate", screen: "battery-climate")
        capture("battery-climate-top")
        try scroll("battery-climate", screenshot: "battery-climate-scrolled")
    }

    func testMileage() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("mileage", screen: "mileage")
        capture("mileage-top")
        try scroll("mileage", screenshot: "mileage-scrolled")
    }

    func testFirmware() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("firmware", screen: "firmware")
        capture("firmware-top")
        try scroll("firmware", screenshot: "firmware-scrolled")
    }

    func testSpecsWarranty() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMoreRow("specs", screen: "specs")
        capture("specs-top")
        try scroll("specs", screenshot: "specs-scrolled")
    }

    func testRoadtrips() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        try tap("button.drives.roadtrips")
        try waitForScreen("roadtrips")
        capture("roadtrips-top")
        try scroll("roadtrips", screenshot: "roadtrips-scrolled")
        // Trip cards combine into one button whose label carries the stop count.
        try tapFirstHittable(in: "roadtrips", where: NSPredicate(format: "label CONTAINS 'STOP'"))
        try waitForScreen("roadtrip")
        _ = element("roadtrip.never").waitForExistence(timeout: 3)
        capture("roadtrip-detail")
    }

    func testHeatmap() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        try tap("button.drives.heatmap")
        try waitForScreen("heatmap")
        // Map tiles render asynchronously; give them a moment before capturing.
        _ = element("heatmap.never").waitForExistence(timeout: 3)
        capture("heatmap-top")
        try scroll("heatmap", screenshot: "heatmap-scrolled")
        // Calendar cells are labelled "<date>, <distance>"; open a driven day.
        try tapFirstHittable(in: "heatmap", where: NSPredicate(format: "label ENDSWITH ' mi' OR label ENDSWITH ' km'"))
        try waitForScreen("heatmap-day")
        capture("heatmap-day")
    }

    private func tapFirstHittable(in screen: String, where predicate: NSPredicate) throws {
        let candidates = element("scroll.\(screen)").buttons.matching(predicate)
        guard candidates.firstMatch.waitForExistence(timeout: 10),
              let target = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No hittable button in scroll.\(screen) matching \(predicate)")
            throw NavigationFailure.missing("button in scroll.\(screen)")
        }
        target.tap()
    }

    /// Opens a More row by its `row.more.<slug>` identifier, scrolling it into view first.
    private func openMoreRow(_ slug: String, screen: String) throws {
        try openMore()
        let row = element("row.more.\(slug)")
        let container = element("scroll.more")
        for _ in 0..<4 where !(row.exists && row.isHittable) { container.swipeUp() }
        try tap("row.more.\(slug)")
        try waitForScreen(screen)
    }

    private func waitForElement(_ identifier: String) throws {
        guard element(identifier).waitForExistence(timeout: 20) else {
            capture("failure-\(identifier)")
            XCTFail("Missing \(identifier)")
            throw NavigationFailure.missing(identifier)
        }
    }

    private func openMore() throws {
        try navigate("button.more", to: "more")
    }

    /// A cold CI simulator can report a tab hittable before its first synthesized
    /// tap is delivered. Retry navigation once; the original final screen
    /// assertion remains mandatory, so a persistent failure still fails the test.
    private func navigate(_ button: String, to screen: String) throws {
        try tap(button)
        if !element("screen.\(screen)").waitForExistence(timeout: 10) {
            try tap(button)
        }
        try waitForScreen(screen)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForScreen(_ name: String) throws {
        let marker = element("screen.\(name)")
        guard marker.waitForExistence(timeout: 20) else {
            capture("failure-\(name)")
            XCTFail("Missing screen.\(name). Check demo launch handling and the identifier contract in VoltaUITests/README.md.")
            throw NavigationFailure.missing("screen.\(name)")
        }
    }

    private func tap(_ identifier: String) throws {
        let target = element(identifier)
        let ready = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: target)
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            capture("failure-\(identifier)")
            XCTFail("Missing or obscured navigation control: \(identifier)")
            throw NavigationFailure.missing(identifier)
        }
        target.tap()
    }

    private func tapFirstRow(prefix: String) throws {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        let ready = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: row)
        guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
            capture("failure-\(prefix)")
            XCTFail("Populated demo data must expose a tappable \(prefix)<id> row.")
            throw NavigationFailure.missing(prefix)
        }
        row.tap()
    }

    private func scroll(_ screen: String, screenshot name: String) throws {
        // SwiftUI List/Form containers may surface as collection views.
        let container = element("scroll.\(screen)")
        guard container.waitForExistence(timeout: 10) else {
            XCTFail("Missing scroll.\(screen) for reference screenshot coverage")
            throw NavigationFailure.missing("scroll.\(screen)")
        }
        container.swipeUp()
        capture(name)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum NavigationFailure: Error {
        case missing(String)
    }
}
