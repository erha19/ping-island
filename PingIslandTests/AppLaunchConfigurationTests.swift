import AppKit
import XCTest
@testable import Ping_Island

final class AppLaunchConfigurationTests: XCTestCase {
    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.AppLaunchConfiguration.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultLaunchConfigurationMatchesProductionBehavior() {
        let configuration = AppLaunchConfiguration(environment: [:], isDebuggerAttached: false)

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertFalse(configuration.isRunningTests)
        XCTAssertTrue(configuration.shouldInstallIntegrations)
        XCTAssertTrue(configuration.shouldCreateNotchWindow)
        XCTAssertTrue(configuration.shouldObserveScreens)
        XCTAssertTrue(configuration.shouldEnforceSingleInstance)
        XCTAssertFalse(configuration.shouldPresentSettingsWindowOnLaunch)
        XCTAssertEqual(configuration.activationPolicy, .accessory)
    }

    func testUITestLaunchConfigurationDisablesSideEffectsAndShowsSettings() {
        let configuration = AppLaunchConfiguration(
            environment: ["PING_ISLAND_UI_TEST_MODE": "1"],
            isDebuggerAttached: false
        )

        XCTAssertTrue(configuration.isUITesting)
        XCTAssertTrue(configuration.isRunningTests)
        XCTAssertFalse(configuration.shouldInstallIntegrations)
        XCTAssertFalse(configuration.shouldCreateNotchWindow)
        XCTAssertFalse(configuration.shouldObserveScreens)
        XCTAssertFalse(configuration.shouldEnforceSingleInstance)
        XCTAssertTrue(configuration.shouldPresentSettingsWindowOnLaunch)
        XCTAssertEqual(configuration.activationPolicy, .regular)
    }

    func testXCTestLaunchConfigurationDisablesStartupSideEffects() {
        let configuration = AppLaunchConfiguration(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            isDebuggerAttached: false
        )

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertTrue(configuration.isRunningTests)
        XCTAssertFalse(configuration.shouldInstallIntegrations)
        XCTAssertFalse(configuration.shouldCreateNotchWindow)
        XCTAssertFalse(configuration.shouldObserveScreens)
        XCTAssertFalse(configuration.shouldEnforceSingleInstance)
        XCTAssertFalse(configuration.shouldPresentSettingsWindowOnLaunch)
        XCTAssertEqual(configuration.activationPolicy, .accessory)
    }

    func testDebuggerLaunchDisablesSingleInstanceEnforcement() {
        let configuration = AppLaunchConfiguration(environment: [:], isDebuggerAttached: true)

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertFalse(configuration.isRunningTests)
        XCTAssertTrue(configuration.shouldInstallIntegrations)
        XCTAssertTrue(configuration.shouldCreateNotchWindow)
        XCTAssertTrue(configuration.shouldObserveScreens)
        XCTAssertFalse(configuration.shouldEnforceSingleInstance)
        XCTAssertFalse(configuration.shouldPresentSettingsWindowOnLaunch)
        XCTAssertEqual(configuration.activationPolicy, .accessory)
    }

    func testLaunchFlowDefersMainWindowUntilPresentationModeOnboardingCompletes() {
        let configuration = AppLaunchConfiguration(environment: [:], isDebuggerAttached: false)

        let flow = AppLaunchFlow(
            configuration: configuration,
            presentationModeOnboardingPending: true
        )

        XCTAssertTrue(flow.shouldStartMonitoringImmediately)
        XCTAssertTrue(flow.shouldPresentSurfaceModeOnboarding)
        XCTAssertFalse(flow.shouldCreateInitialIslandWindow)
        XCTAssertFalse(flow.shouldPresentSettingsWindowImmediately)
        XCTAssertFalse(flow.shouldPresentSettingsWindowAfterOnboarding)
    }

    func testLaunchFlowDefersSettingsWindowUntilAfterOnboardingWhenRequested() {
        let configuration = AppLaunchConfiguration(
            environment: ["PING_ISLAND_SHOW_SETTINGS_ON_LAUNCH": "1"],
            isDebuggerAttached: false
        )

        let flow = AppLaunchFlow(
            configuration: configuration,
            presentationModeOnboardingPending: true
        )

        XCTAssertTrue(flow.shouldStartMonitoringImmediately)
        XCTAssertTrue(flow.shouldPresentSurfaceModeOnboarding)
        XCTAssertFalse(flow.shouldCreateInitialIslandWindow)
        XCTAssertFalse(flow.shouldPresentSettingsWindowImmediately)
        XCTAssertTrue(flow.shouldPresentSettingsWindowAfterOnboarding)
    }

    func testLaunchFlowKeepsMonitoringDisabledWhileRunningTests() {
        let configuration = AppLaunchConfiguration(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            isDebuggerAttached: false
        )

        let flow = AppLaunchFlow(
            configuration: configuration,
            presentationModeOnboardingPending: false
        )

        XCTAssertFalse(flow.shouldStartMonitoringImmediately)
        XCTAssertFalse(flow.shouldPresentSurfaceModeOnboarding)
        XCTAssertFalse(flow.shouldCreateInitialIslandWindow)
    }

    func testNotchDetachmentHintExperienceSchedulesHintForUpgradingUsers() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettingsDefaultKeys.notchDetachmentHintPending)
        defaults.set(false, forKey: AppSettingsDefaultKeys.floatingPetSettingsHintPending)

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.4.1",
            currentVersion: "0.5.0"
        )

        XCTAssertTrue(defaults.bool(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending))
        XCTAssertTrue(defaults.bool(forKey: AppSettingsDefaultKeys.floatingPetSettingsHintPending))
    }

    func testNotchDetachmentHintExperienceDoesNotScheduleHintForFreshInstall() {
        let defaults = makeDefaults()

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: nil,
            currentVersion: "0.5.0"
        )

        XCTAssertFalse(defaults.bool(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending))
    }

    func testNotchDetachmentHintExperienceOnlyAppliesUpgradePromptOncePerVersion() {
        let defaults = makeDefaults()

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.4.1",
            currentVersion: "0.5.0"
        )
        defaults.set(false, forKey: AppSettingsDefaultKeys.notchDetachmentHintPending)

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.4.1",
            currentVersion: "0.5.0"
        )

        XCTAssertFalse(defaults.bool(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending))
    }

    func testNotchDetachmentHintExperienceSchedulesAgainForNextVersionUpgrade() {
        let defaults = makeDefaults()

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.4.1",
            currentVersion: "0.5.0"
        )
        defaults.set(false, forKey: AppSettingsDefaultKeys.notchDetachmentHintPending)

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.5.0",
            currentVersion: "0.5.1"
        )

        XCTAssertTrue(defaults.bool(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending))
    }

    func testNotchDetachmentHintExperienceSkipsWhenPreviousVersionMatchesCurrentVersion() {
        let defaults = makeDefaults()

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.5.1",
            currentVersion: "0.5.1"
        )

        XCTAssertFalse(defaults.bool(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending))
    }

    func testNotchDetachmentHintExperienceUsesInjectedPendingMarkerForUpgrades() {
        let defaults = makeDefaults()
        var injectedMarkerInvocationCount = 0

        NotchDetachmentHintExperience.prepareForLaunch(
            defaults: defaults,
            previousVersion: "0.5.0",
            currentVersion: "0.5.1",
            markHintsPending: {
                injectedMarkerInvocationCount += 1
            }
        )

        XCTAssertEqual(injectedMarkerInvocationCount, 1)
    }

    func testFirstLaunchCheckUsesInjectedPendingMarker() {
        let defaults = makeDefaults()
        var injectedMarkerInvocationCount = 0

        let isFirstLaunch = HookInstaller.checkAndMarkFirstLaunch(
            defaults: defaults,
            markPresentationOnboardingPending: {
                injectedMarkerInvocationCount += 1
            }
        )

        XCTAssertTrue(isFirstLaunch)
        XCTAssertEqual(injectedMarkerInvocationCount, 1)
        XCTAssertEqual(defaults.object(forKey: "HookInstaller.isFirstLaunch.v1") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: AppSettingsDefaultKeys.presentationModeOnboardingPending))
    }

    func testFirstLaunchCheckFallsBackToDefaultsWithoutInjectedPendingMarker() {
        let defaults = makeDefaults()

        let isFirstLaunch = HookInstaller.checkAndMarkFirstLaunch(defaults: defaults)

        XCTAssertTrue(isFirstLaunch)
        XCTAssertEqual(defaults.object(forKey: "HookInstaller.isFirstLaunch.v1") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.presentationModeOnboardingPending) as? Bool, true)
    }

    func testMouseEventReplayMarkerDistinguishesSyntheticEvents() {
        let location = CGPoint(x: 120, y: 48)
        let originalEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        )
        let replayedEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        )

        XCTAssertNotNil(originalEvent)
        XCTAssertNotNil(replayedEvent)

        guard
            let originalEvent,
            let replayedEvent,
            let originalNSEvent = NSEvent(cgEvent: originalEvent),
            let replayedNSEvent = NSEvent(cgEvent: replayedEvent)
        else {
            return XCTFail("Expected to create mouse events for replay marker tests")
        }

        XCTAssertFalse(MouseEventReplay.isReplayed(originalNSEvent))

        MouseEventReplay.mark(replayedEvent)

        guard let markedReplayEvent = NSEvent(cgEvent: replayedEvent) else {
            return XCTFail("Expected to wrap marked replay event")
        }

        XCTAssertTrue(MouseEventReplay.isReplayed(markedReplayEvent))
        XCTAssertFalse(MouseEventReplay.isReplayed(originalNSEvent))
        XCTAssertEqual(replayedNSEvent.type, .leftMouseDown)
    }
}
