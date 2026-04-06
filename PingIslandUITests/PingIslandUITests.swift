import XCTest

final class PingIslandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsWindowLaunchesInUITestMode() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PING_ISLAND_UI_TEST_MODE"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["settings.sidebar.general"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["登录时打开"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSidebarCanSwitchToAboutPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PING_ISLAND_UI_TEST_MODE"] = "1"
        app.launch()

        let aboutButton = app.buttons["settings.sidebar.about"]
        XCTAssertTrue(aboutButton.waitForExistence(timeout: 5))
        aboutButton.tap()

        XCTAssertTrue(app.staticTexts["应用信息"].waitForExistence(timeout: 5))
    }
}
