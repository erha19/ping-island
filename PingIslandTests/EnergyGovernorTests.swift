import XCTest
@testable import Ping_Island

final class EnergyGovernorTests: XCTestCase {
    func testActiveSessionUsesFullPolicy() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: true,
            hasAttentionSession: false,
            hasRecentSessionActivity: true,
            hasVisibleSession: true,
            isSystemSuspended: false,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: true
        )

        let mode = EnergyGovernor.resolvedMode(for: inputs)
        let policy = EnergyPolicy.policy(for: mode)

        XCTAssertEqual(mode, .active)
        XCTAssertEqual(policy.codexThreadListRefreshInterval, .seconds(15))
        XCTAssertEqual(policy.sessionMaintenanceInterval, .seconds(60))
        XCTAssertEqual(policy.eventMonitoringLevel, .full)
        XCTAssertEqual(policy.animationLevel, .full)
        XCTAssertFalse(policy.allowsSilentUpdates)
    }

    func testQuietBackgroundDropsMouseMoveAndSlowsPolling() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: false,
            hasAttentionSession: false,
            hasRecentSessionActivity: false,
            hasVisibleSession: false,
            isSystemSuspended: false,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: false
        )

        let mode = EnergyGovernor.resolvedMode(for: inputs)
        let policy = EnergyPolicy.policy(for: mode)

        XCTAssertEqual(mode, .quietBackground)
        XCTAssertEqual(policy.codexThreadListRefreshInterval, .seconds(5 * 60))
        XCTAssertEqual(policy.sessionMaintenanceInterval, .seconds(10 * 60))
        XCTAssertEqual(policy.eventMonitoringLevel, .interactionOnly)
        XCTAssertEqual(policy.animationLevel, .staticFrames)
    }

    func testRecentlyActiveVisibleIdleDropsMouseMoveMonitoringButKeepsReducedAnimation() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: false,
            hasAttentionSession: false,
            hasRecentSessionActivity: true,
            hasVisibleSession: true,
            isSystemSuspended: false,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: false
        )

        let mode = EnergyGovernor.resolvedMode(for: inputs)
        let policy = EnergyPolicy.policy(for: mode)

        XCTAssertEqual(mode, .idleVisible)
        XCTAssertEqual(policy.eventMonitoringLevel, .interactionOnly)
        XCTAssertEqual(policy.animationLevel, .reduced)
    }

    func testSettledVisibleIdleUsesStaticFramesAfterGracePeriod() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: false,
            hasAttentionSession: false,
            hasRecentSessionActivity: false,
            hasVisibleSession: true,
            isSystemSuspended: false,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: false
        )

        let mode = EnergyGovernor.resolvedMode(for: inputs)
        let policy = EnergyPolicy.policy(for: mode)

        XCTAssertEqual(mode, .quietBackground)
        XCTAssertEqual(policy.eventMonitoringLevel, .interactionOnly)
        XCTAssertEqual(policy.animationLevel, .staticFrames)
        XCTAssertEqual(EnergyGovernor.idleVisibleAnimationGraceDuration, 10 * 60)
    }

    func testSuspendedModePausesBackgroundPolling() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: true,
            hasAttentionSession: true,
            hasRecentSessionActivity: true,
            hasVisibleSession: true,
            isSystemSuspended: true,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: false
        )

        let mode = EnergyGovernor.resolvedMode(for: inputs)
        let policy = EnergyPolicy.policy(for: mode)

        XCTAssertEqual(mode, .systemSuspended)
        XCTAssertNil(policy.codexThreadListRefreshInterval)
        XCTAssertNil(policy.sessionMaintenanceInterval)
        XCTAssertNil(policy.usageRefreshInterval)
        XCTAssertEqual(policy.eventMonitoringLevel, .disabled)
        XCTAssertFalse(policy.allowsFileWatcherRetry)
    }

    func testLowPowerVisibleIdleUsesQuietPolicy() {
        let inputs = EnergyGovernorInputs(
            hasActiveSession: false,
            hasAttentionSession: false,
            hasRecentSessionActivity: true,
            hasVisibleSession: true,
            isSystemSuspended: false,
            isWakeGraceActive: false,
            isLowPowerModeEnabled: true
        )

        XCTAssertEqual(EnergyGovernor.resolvedMode(for: inputs), .quietBackground)
    }
}
