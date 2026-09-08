import XCTest
@testable import Ping_Island

final class KeepAwakePolicyTests: XCTestCase {
    func testOffOverridesWorkingSessions() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .off, hasWorkingSession: true)), .release(.disabled))
    }

    func testAlwaysOverridesIdleAndBatteryFloor() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .always, isOnBattery: true, batteryPercent: 1)), .hold(.alwaysOn))
    }

    func testAutoHoldsForWorkingSession() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, hasWorkingSession: true)), .hold(.sessionWorking))
    }

    func testIdleWithoutPriorWorkDoesNotHold() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto)), .release(.nothingWorking))
    }

    func testGraceExpiresAtExactBoundary() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, secondsSinceWorking: 119)), .hold(.graceWindow))
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, secondsSinceWorking: 120)), .release(.nothingWorking))
    }

    func testBatteryFloorIncludesExactBoundary() {
        for percent in [0, 34, 35] {
            XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, hasWorkingSession: true, isOnBattery: true, batteryPercent: percent)), .release(.batteryFloor(percent: percent)))
        }
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, hasWorkingSession: true, isOnBattery: true, batteryPercent: 36)), .hold(.sessionWorking))
    }

    func testBatteryFloorAlsoOverridesGrace() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, secondsSinceWorking: 1, isOnBattery: true, batteryPercent: 20)), .release(.batteryFloor(percent: 20)))
    }

    func testACAndUnknownChargeDoNotSuppressWorkingSession() {
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, hasWorkingSession: true, isOnBattery: false, batteryPercent: 10)), .hold(.sessionWorking))
        XCTAssertEqual(KeepAwakePolicy.decide(for: .init(mode: .auto, hasWorkingSession: true, isOnBattery: true, batteryPercent: nil)), .hold(.sessionWorking))
    }

    func testDefaultThresholds() {
        XCTAssertEqual(KeepAwakePolicy.defaultGraceSeconds, 120)
        XCTAssertEqual(KeepAwakePolicy.defaultBatteryFloorPercent, 35)
        XCTAssertEqual(KeepAwakeInputs.empty.mode, .off)
    }
}
