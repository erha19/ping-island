import XCTest
@testable import Ping_Island

final class NativeRuntimePreviewUnlockStateTests: XCTestCase {
    func testGeneralNeedsSixConsecutiveTapsToUnlock() {
        var state = NativeRuntimePreviewUnlockState()

        for _ in 0..<5 {
            state.registerTap(on: .general)
        }

        XCTAssertFalse(state.isUnlocked)
        XCTAssertEqual(state.tapCount, 5)

        state.registerTap(on: .general)

        XCTAssertTrue(state.isUnlocked)
        XCTAssertEqual(state.tapCount, 6)
    }

    func testNonGeneralTapResetsProgress() {
        var state = NativeRuntimePreviewUnlockState()

        state.registerTap(on: .general)
        state.registerTap(on: .general)
        state.registerTap(on: .integration)

        XCTAssertFalse(state.isUnlocked)
        XCTAssertEqual(state.tapCount, 0)
    }
}
