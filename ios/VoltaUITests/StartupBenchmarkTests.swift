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
        // The fixture has no Apple sign-in, so start on the pairing-code form.
        app.launchArguments = ["-serverURL", "https://127.0.0.1:9443", "-pairing-code"]
        app.launch()
        defer { app.terminate() }
        let code = app.textFields["field.pairingCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "Use a fresh, unpaired benchmark simulator")
        code.tap()
        code.typeText("BENCH123")
        app.buttons["Connect"].tap()
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
            let shell = app.tabBars.buttons["Dashboard"]
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
            // History keeps loading after status. Stay in the foreground long
            // enough for the app's `startup` log milestones to record it.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "history settles")], timeout: 4)
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
