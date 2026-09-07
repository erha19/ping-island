import XCTest
@testable import Ping_Island

final class KeepAwakePolicyTests: XCTestCase {

    // MARK: - Modes

    func testOffNeverHolds() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .off
        inputs.hasWorkingSession = true
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .release(.disabled))
    }

    func testAlwaysHoldsEvenWithNoSessions() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .always
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.alwaysOn))
    }

    func testAlwaysIgnoresBatteryFloorBecauseItIsAnExplicitChoice() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .always
        inputs.isOnBattery = true
        inputs.batteryPercent = 5
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.alwaysOn))
    }

    // MARK: - Auto

    func testAutoHoldsWhileASessionIsWorking() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = true
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.sessionWorking))
    }

    func testAutoReleasesWhenNothingIsWorking() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = false
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .release(.nothingWorking))
    }

    /// A session waiting on the user is not working. It will not resume by itself, so
    /// holding the machine awake for it only costs battery. `hasWorkingSession` is
    /// driven by `phase.isActive` (.processing/.compacting) rather than by
    /// `EnergyMode.active`, which also covers `hasAttentionSession`.
    func testAutoReleasesForSessionsWaitingOnTheUser() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = false
        inputs.secondsSinceWorking = KeepAwakePolicy.defaultGraceSeconds + 1
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .release(.nothingWorking))
    }

    // MARK: - Grace window

    func testGraceWindowHoldsThroughShortGenerationGaps() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = false
        inputs.secondsSinceWorking = 30
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.graceWindow))
    }

    func testGraceWindowExpires() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = false
        inputs.secondsSinceWorking = KeepAwakePolicy.defaultGraceSeconds
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .release(.nothingWorking))
    }

    func testGraceWindowIsConfigurable() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.secondsSinceWorking = 30
        XCTAssertEqual(
            KeepAwakePolicy.decide(for: inputs, graceSeconds: 10),
            .release(.nothingWorking)
        )
    }

    func testNeverHavingWorkedDoesNotHold() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.secondsSinceWorking = nil
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .release(.nothingWorking))
    }

    // MARK: - Battery floor

    func testAutoReleasesAtOrBelowTheBatteryFloorEvenWhileWorking() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = true
        inputs.isOnBattery = true
        inputs.batteryPercent = KeepAwakePolicy.defaultBatteryFloorPercent
        XCTAssertEqual(
            KeepAwakePolicy.decide(for: inputs),
            .release(.batteryFloor(percent: KeepAwakePolicy.defaultBatteryFloorPercent))
        )
    }

    func testAutoHoldsAboveTheBatteryFloor() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = true
        inputs.isOnBattery = true
        inputs.batteryPercent = KeepAwakePolicy.defaultBatteryFloorPercent + 1
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.sessionWorking))
    }

    func testBatteryFloorDoesNotApplyOnACPower() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = true
        inputs.isOnBattery = false
        inputs.batteryPercent = 5
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.sessionWorking))
    }

    func testUnknownBatteryPercentDoesNotBlockHolding() {
        var inputs = KeepAwakeInputs.empty
        inputs.mode = .auto
        inputs.hasWorkingSession = true
        inputs.isOnBattery = true
        inputs.batteryPercent = nil
        XCTAssertEqual(KeepAwakePolicy.decide(for: inputs), .hold(.sessionWorking))
    }

    // MARK: - Assertion wrapper

    func testSleepAssertionHoldAndReleaseAreIdempotent() {
        let assertion = SleepAssertion(name: "PingIsland unit test")
        XCTAssertFalse(assertion.isHeld)

        XCTAssertTrue(assertion.hold())
        XCTAssertTrue(assertion.isHeld)
        XCTAssertTrue(assertion.hold(), "holding twice should be a no-op")
        XCTAssertTrue(assertion.isHeld)

        XCTAssertTrue(assertion.release())
        XCTAssertFalse(assertion.isHeld)
        XCTAssertTrue(assertion.release(), "releasing twice should be a no-op")
        XCTAssertFalse(assertion.isHeld)
    }

    func testSleepAssertionFollowsDecision() {
        let assertion = SleepAssertion(name: "PingIsland unit test")

        assertion.apply(.hold(.sessionWorking))
        XCTAssertTrue(assertion.isHeld)

        assertion.apply(.release(.nothingWorking))
        XCTAssertFalse(assertion.isHeld)
    }
}
