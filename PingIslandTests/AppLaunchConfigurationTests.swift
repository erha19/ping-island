import AppKit
import XCTest
@testable import Ping_Island

final class AppLaunchConfigurationTests: XCTestCase {
    func testDefaultLaunchConfigurationMatchesProductionBehavior() {
        let configuration = AppLaunchConfiguration(environment: [:])

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
            environment: ["PING_ISLAND_UI_TEST_MODE": "1"]
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
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
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
}
