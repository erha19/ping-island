import AppKit
import Foundation

struct AppLaunchConfiguration: Equatable {
    let isUITesting: Bool
    let isRunningTests: Bool
    let shouldInstallIntegrations: Bool
    let shouldCreateNotchWindow: Bool
    let shouldObserveScreens: Bool
    let shouldEnforceSingleInstance: Bool
    let shouldPresentSettingsWindowOnLaunch: Bool
    let activationPolicy: NSApplication.ActivationPolicy

    init(environment: [String: String] = Foundation.ProcessInfo.processInfo.environment) {
        let isUITesting = environment["PING_ISLAND_UI_TEST_MODE"] == "1"
        let isRunningUnderXCTest = environment["XCTestConfigurationFilePath"] != nil
        let shouldShowSettings = environment["PING_ISLAND_SHOW_SETTINGS_ON_LAUNCH"] == "1"
        let isRunningTests = isUITesting || isRunningUnderXCTest

        self.isUITesting = isUITesting
        self.isRunningTests = isRunningTests
        self.shouldInstallIntegrations = !isRunningTests
        self.shouldCreateNotchWindow = !isRunningTests
        self.shouldObserveScreens = !isRunningTests
        self.shouldEnforceSingleInstance = !isRunningTests
        self.shouldPresentSettingsWindowOnLaunch = isUITesting || shouldShowSettings
        self.activationPolicy = isUITesting ? .regular : .accessory
    }
}
