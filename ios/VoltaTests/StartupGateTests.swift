import XCTest
@testable import Volta

/// The dashboard's first-frame gate for below-fold sections, and the order
/// startup milestones are logged in around it.
@MainActor
final class StartupGateTests: XCTestCase {
    // MARK: Gate

    func testColumnLeavesBelowFoldOutOfTheFirstFrame() {
        XCTAssertFalse(DashboardView.mountsBelowFold(.column, launchFrameShown: false))
        XCTAssertTrue(DashboardView.mountsBelowFold(.column, launchFrameShown: true))
    }

    func testLaterMountIsNotDeferred() {
        // Every mount after the launch's first frame sees it shown.
        for layout in [DashboardView.Layout.column, .stage, .upright] {
            XCTAssertTrue(DashboardView.mountsBelowFold(layout, launchFrameShown: true))
        }
    }

    func testTwoPaneLayoutsNeverDefer() {
        // Their sections are on screen at launch.
        XCTAssertTrue(DashboardView.mountsBelowFold(.stage, launchFrameShown: false))
        XCTAssertTrue(DashboardView.mountsBelowFold(.upright, launchFrameShown: false))
    }

    // MARK: Milestone order

    func testSectionsLogsAfterBelowFold() {
        var order = MilestoneOrder()
        order.hold(.sections, until: .belowFold)
        XCTAssertEqual(order.release(.firstFrame), [.firstFrame])
        XCTAssertEqual(order.release(.sections), [], "held until the sections are mounted")
        XCTAssertEqual(order.release(.belowFold), [.belowFold, .sections])
        XCTAssertEqual(order.logged, [.firstFrame, .belowFold, .sections])
    }

    /// Compact → regular before the gate opens, history finished first: the
    /// two-pane layout mounts the sections, which releases `sections`.
    func testFoldToTwoPanesBeforeGateReleasesFinishedHistory() {
        var order = MilestoneOrder()
        XCTAssertFalse(DashboardView.mountsBelowFold(.column, launchFrameShown: false))
        order.hold(.sections, until: .belowFold)
        XCTAssertEqual(order.release(.sections), [])
        // The fold swaps in `stage` while the launch frame is still pending.
        XCTAssertTrue(DashboardView.mountsBelowFold(.stage, launchFrameShown: false))
        XCTAssertEqual(order.release(.belowFold), [.belowFold, .sections])
    }

    /// Compact → regular before the gate opens, history finishing afterwards.
    func testFoldToTwoPanesBeforeGateThenHistoryFinishes() {
        var order = MilestoneOrder()
        order.hold(.sections, until: .belowFold)
        XCTAssertTrue(DashboardView.mountsBelowFold(.upright, launchFrameShown: false))
        XCTAssertEqual(order.release(.belowFold), [.belowFold])
        XCTAssertEqual(order.release(.sections), [.sections])
        XCTAssertEqual(order.logged, [.belowFold, .sections])
    }

    func testHoldAfterPrerequisiteIsNoHold() {
        var order = MilestoneOrder()
        XCTAssertEqual(order.release(.belowFold), [.belowFold])
        order.hold(.sections, until: .belowFold)
        XCTAssertEqual(order.release(.sections), [.sections])
    }

    func testUnheldMilestonesLogAtOnce() {
        var order = MilestoneOrder()
        XCTAssertEqual(order.release(.sections), [.sections])
        XCTAssertEqual(order.release(.aboveFold), [.aboveFold])
    }
}
