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

    @MainActor
    func testSettingsCategoriesSwitchWithoutBlockingContent() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PING_ISLAND_UI_TEST_MODE"] = "1"
        app.launch()

        for category in ["display", "analytics", "sound", "general", "display", "sound"] {
            let sidebarButton = app.buttons["settings.sidebar.\(category)"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5))
            sidebarButton.tap()
            XCTAssertTrue(
                sidebarButton.isSelected,
                "Sidebar selection for \(category) should update before detail loading finishes"
            )

            XCTAssertTrue(
                app.scrollViews["settings.detail.\(category)"].waitForExistence(timeout: 1),
                "Settings content for \(category) should become available immediately"
            )
        }
    }

    @MainActor
    func testSettingsSoundPageShowsAllExperienceThemes() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PING_ISLAND_UI_TEST_MODE"] = "1"
        app.launch()

        let soundButton = app.buttons["settings.sidebar.sound"]
        XCTAssertTrue(soundButton.waitForExistence(timeout: 5))
        soundButton.tap()

        for themeID in ["standard", "macOS", "pixel"] {
            XCTAssertTrue(
                app.buttons["settings.theme.\(themeID)"].waitForExistence(timeout: 2),
                "The \(themeID) experience theme card should remain visible"
            )
        }

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Settings-Sound-Experience-Themes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
