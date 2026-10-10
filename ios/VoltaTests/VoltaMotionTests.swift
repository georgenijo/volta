import SwiftUI
import XCTest
@testable import Volta

final class VoltaMotionTests: XCTestCase {
    // MARK: Enablement

    func testLaunchFlagDisablesMotion() {
        XCTAssertFalse(VoltaMotion.disablesMotion(arguments: []))
        XCTAssertFalse(VoltaMotion.disablesMotion(arguments: ["-demo-mode", "YES"]))
        XCTAssertTrue(VoltaMotion.disablesMotion(arguments: ["-VoltaDisableMotion"]))
        XCTAssertTrue(VoltaMotion.disablesMotion(arguments: ["-demo-mode", "YES", "-VoltaDisableMotion"]))
        XCTAssertTrue(VoltaMotion.disablesMotion(arguments: ["-VoltaDisableMotion", "YES"]))
        XCTAssertTrue(VoltaMotion.disablesMotion(arguments: ["-VoltaDisableMotion", "-demo-mode", "YES"]))
        XCTAssertFalse(VoltaMotion.disablesMotion(arguments: ["-VoltaDisableMotion", "NO"]))
        XCTAssertFalse(VoltaMotion.disablesMotion(arguments: ["-VoltaDisableMotion", "0"]))
    }

    func testMotionDisabledUnderReduceMotionOrFlag() {
        XCTAssertTrue(VoltaMotion.isEnabled(reduceMotion: false, flagEnabled: true))
        XCTAssertFalse(VoltaMotion.isEnabled(reduceMotion: true, flagEnabled: true))
        XCTAssertFalse(VoltaMotion.isEnabled(reduceMotion: false, flagEnabled: false))
        XCTAssertFalse(VoltaMotion.isEnabled(reduceMotion: true, flagEnabled: false))
    }

    func testRepeatingAnimationsRunOnlyWhenEverythingAllows() {
        XCTAssertTrue(VoltaMotion.shouldRun(isActive: true, motionAllowed: true, isVisible: true, isActiveTab: true, scenePhase: .active))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: false, motionAllowed: true, isVisible: true, isActiveTab: true, scenePhase: .active))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: true, motionAllowed: false, isVisible: true, isActiveTab: true, scenePhase: .active))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: true, motionAllowed: true, isVisible: false, isActiveTab: true, scenePhase: .active))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: true, motionAllowed: true, isVisible: true, isActiveTab: false, scenePhase: .active))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: true, motionAllowed: true, isVisible: true, isActiveTab: true, scenePhase: .inactive))
        XCTAssertFalse(VoltaMotion.shouldRun(isActive: true, motionAllowed: true, isVisible: true, isActiveTab: true, scenePhase: .background))
    }

    // MARK: Count up

    func testCountUpInterpolation() {
        XCTAssertEqual(VoltaMotion.countUpValue(126, progress: 0), 0)
        XCTAssertEqual(VoltaMotion.countUpValue(126, progress: 1), 126)
        XCTAssertEqual(VoltaMotion.countUpValue(100, progress: 0.5), 93.75, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.countUpValue(100, progress: -0.2), 0)
        XCTAssertEqual(VoltaMotion.countUpValue(100, progress: 1.3), 100, "Overshooting progress settles on the exact target")
        XCTAssertEqual(VoltaMotion.countUpValue(-40, progress: 1), -40)
        XCTAssertEqual(VoltaMotion.countUpValue(0.37, progress: 1), 0.37, "Final value is exact, not re-derived from easing")
    }

    func testCountUpIsMonotonicAndBounded() {
        var previous = -Double.infinity
        for step in 0...100 {
            let value = VoltaMotion.countUpValue(250, progress: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 250)
            previous = value
        }
    }

    // MARK: Cascade

    func testCascadeDelayLimits() {
        XCTAssertEqual(VoltaMotion.cascadeDelay(for: 0), 0)
        XCTAssertEqual(VoltaMotion.cascadeDelay(for: 1) ?? -1, 0.09, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.cascadeDelay(for: VoltaMotion.maxCascade - 1) ?? -1, Double(VoltaMotion.maxCascade - 1) * 0.09, accuracy: 1e-9)
        XCTAssertNil(VoltaMotion.cascadeDelay(for: VoltaMotion.maxCascade))
        XCTAssertNil(VoltaMotion.cascadeDelay(for: 40))
        XCTAssertNil(VoltaMotion.cascadeDelay(for: -1))
        XCTAssertEqual(VoltaMotion.maxCascade, 6)
    }

    @MainActor
    func testScopeHandsOutAtMostSixCascadeSlotsPerArrival() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let scope = VoltaArrivalScope(now: start)
        let slots = (0..<10).map { _ in scope.claimCascadeSlot() }
        XCTAssertEqual(slots, [0, 1, 2, 3, 4, 5, nil, nil, nil, nil])
        let generation = scope.generation
        scope.arrive(at: start.addingTimeInterval(10))
        XCTAssertEqual(scope.generation, generation + 1)
        XCTAssertEqual(scope.claimCascadeSlot(), 0, "A fresh arrival restarts the cascade")
    }

    @MainActor
    func testScopeWindowGatesLateArrivals() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let scope = VoltaArrivalScope(now: start)
        XCTAssertTrue(scope.isOpen(at: start))
        XCTAssertTrue(scope.isOpen(at: start.addingTimeInterval(VoltaMotion.arrivalWindow - 0.01)))
        XCTAssertFalse(scope.isOpen(at: start.addingTimeInterval(VoltaMotion.arrivalWindow)), "Rows scrolled in later render final state")

        // First appearance soon after creation keeps the same arrival.
        scope.appeared(at: start.addingTimeInterval(0.1))
        XCTAssertEqual(scope.generation, 1)

        // A reopen (late first load) does not replay what already played.
        scope.reopen(at: start.addingTimeInterval(5))
        XCTAssertEqual(scope.generation, 1)
        XCTAssertTrue(scope.isOpen(at: start.addingTimeInterval(5.5)))
    }

    @MainActor
    func testScopeCreatedLongBeforeAppearingStartsAFreshArrival() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let scope = VoltaArrivalScope(now: start)
        scope.appeared(at: start.addingTimeInterval(30))
        XCTAssertEqual(scope.generation, 2)
        XCTAssertTrue(scope.isOpen(at: start.addingTimeInterval(30.2)))
        scope.appeared(at: start.addingTimeInterval(90))
        XCTAssertEqual(scope.generation, 2, "Only the first appearance counts; pops back from detail don't replay")
    }

    @MainActor
    func testCometLeaseAllowsOneRowAtATime() {
        let lease = CometLease()
        let first = UUID(), second = UUID()
        XCTAssertTrue(lease.claim(first))
        XCTAssertFalse(lease.claim(second))
        XCTAssertTrue(lease.claim(first))
        lease.release(second)
        XCTAssertFalse(lease.claim(second))
        lease.release(first)
        XCTAssertTrue(lease.claim(second))
    }

    // MARK: Repeating curves

    func testBloomPeaksMidSweepAndRestsAtEnds() {
        XCTAssertEqual(VoltaMotion.bloom(0), 0, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.bloom(1), 0, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.bloom(1.04), 0, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.bloom(0.5), 1, accuracy: 1e-9)
    }

    func testPulseRingsExpandAndFade() {
        let start = VoltaMotion.pulseRing(time: 0, offset: 0)
        XCTAssertEqual(start.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(start.opacity, 0.7, accuracy: 1e-6)
        let late = VoltaMotion.pulseRing(time: 1.999, offset: 0)
        XCTAssertGreaterThan(late.scale, 3.3)
        XCTAssertLessThan(late.opacity, 0.01)
        XCTAssertEqual(VoltaMotion.pulseRing(time: 0.5, offset: 1).opacity, 0, "Second ring waits for its stagger")
        XCTAssertEqual(VoltaMotion.pulseRing(time: 2.3, offset: 0).scale, VoltaMotion.pulseRing(time: 0.3, offset: 0).scale, accuracy: 1e-9)
    }

    func testCometWaitsForDrawOnThenTravelsAndRests() {
        XCTAssertNil(VoltaMotion.comet(elapsed: VoltaMotion.routeDrawDuration - 0.1))
        let begin = VoltaMotion.comet(elapsed: VoltaMotion.routeDrawDuration)
        XCTAssertEqual(begin?.fraction ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(begin?.opacity ?? -1, 0, accuracy: 1e-6)
        let mid = VoltaMotion.comet(elapsed: VoltaMotion.routeDrawDuration + VoltaMotion.cometPeriod * 0.3)
        XCTAssertEqual(mid?.opacity, 1)
        XCTAssertGreaterThan(mid?.fraction ?? 0, 0.2)
        XCTAssertLessThan(mid?.fraction ?? 1, 0.9)
        let resting = VoltaMotion.comet(elapsed: VoltaMotion.routeDrawDuration + VoltaMotion.cometPeriod * 0.8)
        XCTAssertEqual(resting?.fraction, 1)
        XCTAssertEqual(resting?.opacity, 0)
    }

    func testBreathAndFlowCycle() {
        XCTAssertEqual(VoltaMotion.breath(0), 0, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.breath(VoltaMotion.breathePeriod / 2), 1, accuracy: 1e-9)
        XCTAssertEqual(VoltaMotion.flowPhase(0, spacing: 34), 34, accuracy: 1e-9)
        XCTAssertLessThan(VoltaMotion.flowPhase(VoltaMotion.flowPeriod * 0.5, spacing: 34), 34, "Pulses move forward along the path")
    }

    func testNumberTemplateKeepsShape() throws {
        let us = Locale(identifier: "en_US")
        let grouped = try XCTUnwrap(VoltaMotion.NumberTemplate("1,234", locale: us))
        XCTAssertEqual(grouped.value, 1234)
        XCTAssertEqual(grouped.string(for: 1234), "1,234")
        XCTAssertEqual(grouped.string(for: 56.4), "56")

        let money = try XCTUnwrap(VoltaMotion.NumberTemplate("$4.10", locale: us))
        XCTAssertEqual(money.value, 4.1, accuracy: 1e-9)
        XCTAssertEqual(money.string(for: 2), "$2.00")

        let signed = try XCTUnwrap(VoltaMotion.NumberTemplate("−2.5%", locale: us))
        XCTAssertEqual(signed.string(for: 1.26), "−1.3%")
    }

    func testNumberTemplateRejectsNonNumbers() {
        XCTAssertNil(VoltaMotion.NumberTemplate("—"))
        XCTAssertNil(VoltaMotion.NumberTemplate("4h 49m"), "Compound values are shown as is")
    }
}
