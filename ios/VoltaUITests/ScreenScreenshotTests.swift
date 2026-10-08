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
        try tap("tab.drives")
        try waitForScreen("drives")
        capture("drives")
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
        try tap("tab.drives")
        try waitForScreen("drives")
        try tapFirstRow(prefix: "row.drive.")
        try waitForScreen("drive-detail")
        capture("drive-detail")
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

    private func waitForElement(_ identifier: String) throws {
        guard element(identifier).waitForExistence(timeout: 20) else {
            capture("failure-\(identifier)")
            XCTFail("Missing \(identifier)")
            throw NavigationFailure.missing(identifier)
        }
    }

    private func openMore() throws {
        try tap("button.more")
        try waitForScreen("more")
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
