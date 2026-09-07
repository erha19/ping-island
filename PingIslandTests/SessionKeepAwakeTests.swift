import XCTest
@testable import Ping_Island

final class SessionKeepAwakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDisabledFeatureNeverHolds() {
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: false,
                hasWorkingSession: true,
                lastWorkingAt: now,
                now: now,
                battery: .init(isOnBattery: false, percentage: 100)
            )
        )
        XCTAssertFalse(shouldHold)
    }

    func testWorkingSessionHoldsSystemAssertionIntent() {
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: true,
                lastWorkingAt: now,
                now: now,
                battery: .init(isOnBattery: false, percentage: nil)
            )
        )
        XCTAssertTrue(shouldHold)
    }

    func testWaitingForInputReleasesOutsideGrace() {
        let lastWorkingAt = now.addingTimeInterval(-SessionKeepAwakeEvaluator.releaseGraceDuration - 1)
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: false,
                lastWorkingAt: lastWorkingAt,
                now: now,
                battery: .init(isOnBattery: false, percentage: 80)
            )
        )
        XCTAssertFalse(shouldHold)
    }

    func testHysteresisKeepsHoldBetweenToolCalls() {
        let lastWorkingAt = now.addingTimeInterval(-(SessionKeepAwakeEvaluator.releaseGraceDuration - 5))
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: false,
                lastWorkingAt: lastWorkingAt,
                now: now,
                battery: .init(isOnBattery: true, percentage: 70)
            )
        )
        XCTAssertTrue(shouldHold)
    }

    func testBatteryFloorReleasesOnBattery() {
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: true,
                lastWorkingAt: now,
                now: now,
                battery: .init(
                    isOnBattery: true,
                    percentage: SessionKeepAwakeEvaluator.batteryFloorPercentage - 1
                )
            )
        )
        XCTAssertFalse(shouldHold)
    }

    func testBatteryFloorIgnoredOnACPower() {
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: true,
                lastWorkingAt: now,
                now: now,
                battery: .init(
                    isOnBattery: false,
                    percentage: SessionKeepAwakeEvaluator.batteryFloorPercentage - 10
                )
            )
        )
        XCTAssertTrue(shouldHold)
    }

    func testNeverWorkedDoesNotHold() {
        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: true,
                hasWorkingSession: false,
                lastWorkingAt: nil,
                now: now,
                battery: .init(isOnBattery: false, percentage: 100)
            )
        )
        XCTAssertFalse(shouldHold)
    }

    func testGraceDurationMatchesIssueGuidance() {
        XCTAssertEqual(SessionKeepAwakeEvaluator.releaseGraceDuration, 120)
        XCTAssertEqual(SessionKeepAwakeEvaluator.batteryFloorPercentage, 35)
    }
}
