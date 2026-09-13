import XCTest
@testable import Ping_Island

final class AutoOpenSuppressionPolicyTests: XCTestCase {
    private let threshold = AutoOpenSuppressionPolicy.userActiveIdleThreshold

    func testSmartSuppressionDisabledNeverSuppresses() {
        XCTAssertFalse(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: false,
                isTerminalVisible: true,
                suppressWhileUserActive: true,
                idleSeconds: 0
            )
        )
        XCTAssertFalse(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: false,
                isTerminalVisible: false,
                suppressWhileUserActive: true,
                idleSeconds: 0
            )
        )
    }

    func testVisibleTerminalSuppressesWithoutUserActiveRule() {
        XCTAssertTrue(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: true,
                isTerminalVisible: true,
                suppressWhileUserActive: false,
                idleSeconds: threshold * 10
            )
        )
    }

    func testRecentInputSuppressesWhenUserActiveRuleEnabled() {
        XCTAssertTrue(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: true,
                isTerminalVisible: false,
                suppressWhileUserActive: true,
                idleSeconds: 0
            )
        )
    }

    func testUserAwayAllowsAutoOpen() {
        XCTAssertFalse(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: true,
                isTerminalVisible: false,
                suppressWhileUserActive: true,
                idleSeconds: threshold + 0.1
            )
        )
    }

    func testUserActiveRuleDisabledFallsBackToTerminalVisibilityOnly() {
        XCTAssertFalse(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: true,
                isTerminalVisible: false,
                suppressWhileUserActive: false,
                idleSeconds: 0
            )
        )
    }

    func testIdleExactlyAtThresholdCountsAsAway() {
        XCTAssertFalse(
            AutoOpenSuppressionPolicy.shouldSuppressAutoOpen(
                smartSuppressionEnabled: true,
                isTerminalVisible: false,
                suppressWhileUserActive: true,
                idleSeconds: threshold
            )
        )
    }
}
