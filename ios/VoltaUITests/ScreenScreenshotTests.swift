import XCTest

/// Independent launches let completed screens produce evidence while other screens land.
@MainActor
final class ScreenScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    // Synchronous XCTest setup overrides are nonisolated. Keep UI work on the
    // main actor inside each test, including cleanup when navigation throws.
    private func launchDemo() throws {
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-VoltaDisableMotion"]
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

    /// Leaving the tab and coming back keeps the pages already loaded.
    func testDrivesKeepsPagesAcrossTabs() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        let container = element("scroll.drives")
        let last = element("row.drive.60")
        for _ in 0..<45 {
            if last.exists && last.isHittable { break }
            container.swipeUp()
        }
        XCTAssertTrue(last.exists && last.isHittable, "Scrolling must load the second page")
        try tap("tab.dashboard")
        try waitForScreen("dashboard")
        try tap("tab.drives")
        _ = element("drives.never").waitForExistence(timeout: 2)
        XCTAssertTrue(last.exists && last.isHittable, "Returning to Drives must keep the second page and the scroll position")
        capture("drives-after-tab-switch")
    }

    func testIdles() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.idles", to: "idles")
        capture("idles")
        // A stop opens its detail: pushed on a phone, beside the list on the open inner display.
        try tapFirstRow(prefix: "row.idle.")
        try waitForScreen("idle-detail")
        capture("idle-detail")
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

    func testElectricityRate() throws {
        defer { app.terminate() }
        try launchDemo()
        try openMore()
        try tap("button.settings")
        try waitForScreen("settings")
        let row = element("row.settings.charging")
        for _ in 0..<4 where !(row.exists && row.isHittable) { element("scroll.settings").swipeUp() }
        try tap("row.settings.charging")
        try waitForScreen("settings-charging")
        capture("settings-charging")
        try tap("button.electricity-rate")
        try waitForScreen("electricity-rate")
        capture("electricity-rate")
    }

    func testDriveDetail() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.drives", to: "drives")
        try tapFirstRow(prefix: "row.drive.")
        try waitForScreen("drive-detail")
        capture("drive-detail")
        try scroll("drive-detail", screenshot: "drive-detail-scrolled")
        let elevation = element("trip.chart.coverage.elevation")
        // Slow swipes; step back if a swipe carries the section past the top.
        for _ in 0..<12 {
            if elevation.exists && elevation.isHittable { break }
            if elevation.exists && elevation.frame.maxY < app.frame.midY {
                element("scroll.drive-detail").swipeDown(velocity: .slow)
            } else {
                element("scroll.drive-detail").swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(elevation.exists && elevation.isHittable, "The synthetic drive must render its elevation section")
        capture("drive-detail-elevation")
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
        // `button.controls` is the dock's Controls tile.
        try openControls()
        try waitForScreen("controls")
        XCTAssertTrue(element("row.doors").waitForExistence(timeout: 5), "Doors states the lock and offers its action")
        capture("controls-top")
        try scroll("controls", screenshot: "controls-bottom")
        XCTAssertTrue(element("list.commandLog").exists, "Sent this session closes the Controls list")

        // Opened before the Dashboard's first appearance (the launch argument): shown once it appears.
        app.terminate()
        app.launchArguments = ["-demo-mode", "YES", "-VoltaDisableMotion", "-dashboardOpenControls", "YES"]
        app.launch()
        try waitForScreen("controls")
    }

    /// The Dashboard's dock and Now card send through the same path as Controls.
    func testDashboardDockAndNowCard() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demoCharging", "YES", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("dashboard")
        XCTAssertTrue(element("card.now").waitForExistence(timeout: 10))
        XCTAssertTrue(element("stepper.chargeLimit").exists, "Charging shows one charge limit stepper")
        XCTAssertTrue(element("button.liveCharge").exists)
        // One column on an ordinary iPhone: the dock sits under the Now card.
        let lights = element("dock.lights")
        for _ in 0..<5 where !(lights.exists && lights.isHittable) { element("scroll.dashboard").swipeUp() }
        try tap("dock.lights")
        XCTAssertTrue(element("banner.commandActivity").waitForExistence(timeout: 5))
        capture("dashboard-dock-sent")
    }

    /// Demo mode's drive refreshes on its own while the Dashboard shows; Park removes the card.
    func testLiveDrivingCardRefreshesAndLeavesWhenParked() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demoDriving", "city", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("dashboard")
        let card = element("card.liveDriving")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let first = card.label
        XCTAssertTrue(first.hasPrefix("Driving"), first)
        capture("dashboard-live-driving")
        // Two refreshes later the city loop has moved on.
        let changed = NSPredicate(format: "label != %@", first)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: card)], timeout: 15), .completed,
                       "the card refreshes by itself")
        app.terminate()
        // Shifting into Park mid-refresh: the card leaves and the Dashboard reloads.
        app.launchArguments = ["-demo-mode", "YES", "-demoDriving", "arriving", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("dashboard")
        XCTAssertTrue(element("card.liveDriving").waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: element("card.liveDriving"))], timeout: 40),
                       .completed, "Park removes the driving card")
        XCTAssertTrue(element("card.now").exists, "the parked card takes its place")
    }

    func testClimateControlsFitAndSend() throws {
        defer { app.terminate() }
        try launchDemo()
        try openControls()
        try waitForScreen("controls")
        let climate = element("button.climate")
        for _ in 0..<5 where !climate.isHittable { element("scroll.controls").swipeUp() }
        XCTAssertTrue(climate.isHittable)
        climate.tap()
        try waitForScreen("climate")
        // Side bars (iPhone Duo) label the system back button "BackButton".
        let back = app.buttons["Back"].exists ? app.buttons["Back"] : app.buttons["BackButton"]
        for control in [back, app.buttons["Increase driver target"],
                        app.buttons["Increase passenger target"], element("button.seat.0.0"),
                        element("button.seat.0.3")] {
            XCTAssertTrue(control.isHittable, "Every climate action must fit on screen")
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
        }
        app.buttons["Increase driver target"].tap()
        app.buttons["Set cabin temperatures"].tap()
        XCTAssertTrue(app.staticTexts["Demo simulated set cabin temperatures. No vehicle was contacted."].waitForExistence(timeout: 5))
        capture("climate-controls")
        try tap("button.seat.0.3")
        XCTAssertTrue(app.staticTexts["Demo simulated set driver seat heat to 3. No vehicle was contacted."].waitForExistence(timeout: 5))
        capture("climate-seat-command")
    }

    func testControlRecoveryRequiresFreshConfirmation() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demo-command-outcome-unknown", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("dashboard")
        try openControls()
        try waitForScreen("controls")
        let openFrunk = app.buttons["Open frunk"].firstMatch
        XCTAssertTrue(openFrunk.waitForExistence(timeout: 10))
        openFrunk.tap()
        let original = app.alerts["Open the frunk?"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.buttons["Open frunk"].tap()
        let retry = app.buttons["Retry request"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        let confirmation = app.alerts["Retry open frunk?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["Retry Open frunk"].exists)
        capture("controls-retry-confirmation")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(retry.exists, "Cancel keeps the unresolved intent visible")
    }

    func testTeslaSignInNoVehicle() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demoNoVehicles", "YES", "-VoltaDisableMotion"]
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

    // MARK: Further screens (appearance coverage, docs/APPEARANCE.md)

    func testMoreDestinations() throws {
        defer { app.terminate() }
        for (slug, screen) in [("charging-insights", "charging-insights"), ("tires", "tires"),
                               ("maintenance", "maintenance"), ("lease", "lease"), ("charger-map", "charger-map")] {
            try launchDemo()
            try openMoreRow(slug, screen: screen)
            // The charger map's tiles render asynchronously.
            if slug == "charger-map" { _ = element("charger-map.never").waitForExistence(timeout: 3) }
            capture(slug)
            app.terminate()
        }
    }

    func testSettingsDestinations() throws {
        defer { app.terminate() }
        for (row, screen) in [("vehicle", "vehicle-settings"), ("general", "general-settings"), ("places", "places"),
                              ("security", "security"), ("data-management", "data-management"), ("support", "support")] {
            try launchDemo()
            try openMore()
            try tap("button.settings")
            try waitForScreen("settings")
            let target = element("row.settings.\(row)")
            for _ in 0..<4 where !(target.exists && target.isHittable) { element("scroll.settings").swipeUp() }
            try tap("row.settings.\(row)")
            try waitForScreen(screen)
            if row == "places" { _ = element("places.never").waitForExistence(timeout: 3) }
            capture("settings-\(row)")
            app.terminate()
        }
    }

    /// The Dashboard while the car charges, and its live charging sheet.
    func testLiveCharging() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "YES", "-demoCharging", "YES", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("dashboard")
        _ = element("dashboard.never").waitForExistence(timeout: 2)
        capture("dashboard-charging")
        app.terminate()
        app.launchArguments = ["-demo-mode", "YES", "-demoCharging", "YES", "-dashboardOpenLiveCharge", "YES", "-VoltaDisableMotion"]
        app.launch()
        try waitForScreen("liveCharge")
        _ = element("liveCharge.never").waitForExistence(timeout: 2)
        capture("live-charging")
    }

    func testParkedSummary() throws {
        defer { app.terminate() }
        try launchDemo()
        try navigate("tab.idles", to: "idles")
        try tap("button.parked.summary")
        try waitForScreen("parked-summary")
        capture("parked-summary")
        try scroll("parked-summary", screenshot: "parked-summary-scrolled")
    }

    /// Not paired: the sign-in and pairing screen.
    func testPairing() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        app.launchArguments = ["-demo-mode", "NO", "-VoltaDisableMotion"]
        app.launch()
        try waitForElement("button.signInWithApple")
        capture("pairing")
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
        try navigate("tab.more", to: "more")
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
        // The system tab bar does not reliably carry SwiftUI's tab identifiers,
        // so `tab.<name>` is found by the tab's title.
        if identifier.hasPrefix("tab.") {
            let name = String(identifier.dropFirst(4))
            // The idles tab is titled "Parked"; its identifier keeps the API's name.
            let title = name == "idles" ? "Parked" : name.capitalized
            // iPhone Duo's outer display puts the tabs in a side toolbar instead of a tab bar.
            let side = app.toolbars.buttons[title].firstMatch
            return side.exists ? side : app.tabBars.buttons[title].firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForScreen(_ name: String) throws {
        let marker = element("screen.\(name)")
        guard marker.waitForExistence(timeout: 20) else {
            capture("failure-\(name)")
            XCTFail("Missing screen.\(name). Check demo launch handling and the identifier contract in VoltaUITests/README.md.")
            throw NavigationFailure.missing("screen.\(name)")
        }
    }

    /// Taps the dock's Controls tile, scrolling the Dashboard to it first: on
    /// short windows the dock sits under the Now card.
    private func openControls() throws {
        let tile = element("button.controls")
        for _ in 0..<5 where !(tile.exists && tile.isHittable) { element("scroll.dashboard").swipeUp() }
        try tap("button.controls")
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
