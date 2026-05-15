import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testFloatingPetGuidanceStringsMentionSecondaryClickToReopenSettings() {
        let zhHans = try! localizationFileContents(named: "zh-Hans")
        XCTAssertTrue(
            zhHans.contains("\"进入独立悬浮宠物模式后，右键宠物形象可重新打开设置面板。\" = \"进入独立悬浮宠物模式后，右键宠物形象可重新打开设置面板。\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"独立悬浮宠物默认贴近当前激活窗口右下角显示。拖动后会记住新位置，右键宠物形象可重新打开设置面板。\" = \"独立悬浮宠物默认贴近当前激活窗口右下角显示。拖动后会记住新位置，右键宠物形象可重新打开设置面板。\";")
        )

        let english = try! localizationFileContents(named: "en")
        XCTAssertTrue(
            english.contains("\"进入独立悬浮宠物模式后，右键宠物形象可重新打开设置面板。\" = \"After entering floating pet mode, right-click the mascot to reopen the Settings panel.\";")
        )
        XCTAssertTrue(
            english.contains("\"独立悬浮宠物默认贴近当前激活窗口右下角显示。拖动后会记住新位置，右键宠物形象可重新打开设置面板。\" = \"The floating pet appears near the bottom-right corner of the active window by default. Dragging remembers the new position, and right-clicking the mascot reopens the Settings panel.\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"拖动宠物，让宠物离岛工作\" = \"拖动宠物，让宠物离岛工作\";")
        )
        XCTAssertTrue(
            english.contains("\"拖动宠物，让宠物离岛工作\" = \"Drag the mascot to let the pet work away from the Island.\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"刘海拖拽引导\" = \"刘海拖拽引导\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"重新演示老用户首次打开新版本时看到的刘海拖拽提示。\" = \"重新演示老用户首次打开新版本时看到的刘海拖拽提示。\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"重新演示\" = \"重新演示\";")
        )
        XCTAssertTrue(
            english.contains("\"刘海拖拽引导\" = \"Notch drag guidance\";")
        )
        XCTAssertTrue(
            english.contains("\"重新演示老用户首次打开新版本时看到的刘海拖拽提示。\" = \"Replay the notch drag hint that returning users see the first time they open the new version.\";")
        )
        XCTAssertTrue(
            english.contains("\"重新演示\" = \"Replay\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"最后一步：右键宠物形象\" = \"最后一步：右键宠物形象\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"需要重新打开设置面板时，直接右键宠物形象就可以。\" = \"需要重新打开设置面板时，直接右键宠物形象就可以。\";")
        )
        XCTAssertTrue(
            english.contains("\"最后一步：右键宠物形象\" = \"Last step: right-click the mascot\";")
        )
        XCTAssertTrue(
            english.contains("\"需要重新打开设置面板时，直接右键宠物形象就可以。\" = \"When you need the Settings panel again, just right-click the mascot.\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"重新体验首次引导\" = \"重新体验首次引导\";")
        )
        XCTAssertTrue(
            zhHans.contains("\"手动打开形态选择引导；选择刘海屏或独立悬浮宠物后，会继续进入 Hooks 演示。\" = \"手动打开形态选择引导；选择刘海屏或独立悬浮宠物后，会继续进入 Hooks 演示。\";")
        )
        XCTAssertTrue(
            english.contains("\"重新体验首次引导\" = \"Replay first-run onboarding\";")
        )
        XCTAssertTrue(
            english.contains("\"手动打开形态选择引导；选择刘海屏或独立悬浮宠物后，会继续进入 Hooks 演示。\" = \"Manually open the surface selection onboarding. After choosing the top Island or floating pet, Ping Island continues into the Hooks demo.\";")
        )
    }

    func testPresentReusesExistingWindowAndKeepsItVisible() throws {
        let controller = SettingsWindowController.shared
        controller.dismiss()

        controller.present()
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.width, SettingsWindowDefaults.defaultContentSize.width)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.height, SettingsWindowDefaults.defaultContentSize.height)

        controller.present()

        XCTAssertTrue(window.isVisible)
        XCTAssertIdentical(controller.window, window)
        XCTAssertFalse(window.isMiniaturized)

        controller.dismiss()
    }

    func testSettingsWindowPublishesVisibilityChanges() {
        let controller = SettingsWindowController.shared
        controller.dismiss()

        var visibilityChanges: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsWindowVisibilityDidChange,
            object: controller,
            queue: nil
        ) { notification in
            guard let isVisible = notification.userInfo?[SettingsWindowVisibilityNotification.isVisibleKey] as? Bool else {
                return
            }
            visibilityChanges.append(isVisible)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            controller.dismiss()
        }

        controller.present()
        controller.dismiss()

        XCTAssertEqual(visibilityChanges, [true, false])
    }

    func testPresentationModeWelcomeWindowStaysVisibleUntilCompleted() throws {
        let controller = PresentationModeWelcomeWindowController.shared
        controller.dismiss()

        controller.present { _ in }
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.width, 760)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.height, 520)

        controller.dismiss()
    }

    private func localizationFileContents(named localeCode: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDirectory.deletingLastPathComponent()
        let fileURL = repoRoot
            .appendingPathComponent("PingIsland")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(localeCode).lproj")
            .appendingPathComponent("Localizable.strings")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
