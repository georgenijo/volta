import XCTest

/// Opt-in benchmark against scripts/startup-fixture.py. No production credentials
/// or demo data-source override: pair a dedicated simulator with the HTTPS fixture.
/// Run with TEST_RUNNER_VOLTA_STARTUP_BENCHMARK=1; ordinary CI skips these tests.
@MainActor
final class StartupBenchmarkTests: XCTestCase {
    private func requireBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOLTA_STARTUP_BENCHMARK"] == "1",
                          "Requires the local HTTPS startup fixture and a dedicated simulator")
        continueAfterFailure = false
    }

    func testPairFixture() throws {
        try requireBenchmark()
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let server = app.textFields["https://your-server.tailnet.ts.net"]
        XCTAssertTrue(server.waitForExistence(timeout: 10), "Use a fresh, unpaired benchmark simulator")
        server.tap()
        server.typeText("https://127.0.0.1:9443")
        let code = app.textFields["8-character code"]
        code.tap()
        code.typeText("BENCH123")
        app.swipeUp()
        app.buttons["Pair this device"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.dashboard"].firstMatch.waitForExistence(timeout: 30))
    }

    func testDashboardReadiness() throws {
        try requireBenchmark()
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", "https://127.0.0.1:9443"]
        var samples: [[String: Any]] = []
        // One warm-up is retained in the evidence but excluded from comparisons.
        for trial in 0..<6 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            let launchReturned = ProcessInfo.processInfo.systemUptime - start
            let shell = app.buttons["tab.dashboard"]
            XCTAssertTrue(shell.waitForExistence(timeout: 30))
            let shellReady = ProcessInfo.processInfo.systemUptime - start
            let dashboard = app.descendants(matching: .any)["screen.dashboard"].firstMatch
            XCTAssertTrue(dashboard.waitForExistence(timeout: 30))
            let ready = ProcessInfo.processInfo.systemUptime - start
            samples.append(["trial": trial, "warmup": trial == 0,
                            "launchReturnedSeconds": launchReturned,
                            "shellSeconds": shellReady, "dashboardSeconds": ready])
            print("STARTUP_SAMPLE trial=\(trial) shell=\(shellReady) dashboard=\(ready)")
            if trial == 1 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "startup-dashboard"; shot.lifetime = .keepAlways; add(shot)
            }
            app.terminate()
        }
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "startup-samples.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFirstFramePerformance() throws {
        try requireBenchmark()
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", "https://127.0.0.1:9443"]
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            app.terminate()
        }
    }
}
