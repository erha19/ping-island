import AppKit
import XCTest
@testable import Ping_Island

final class GlobalShortcutTests: XCTestCase {
    func testGlobalShortcutRequiresModifierKeys() {
        XCTAssertNil(GlobalShortcut(keyCode: 38, modifierFlags: []))
    }

    func testGlobalShortcutSanitizesToSupportedModifiersAndFormatsDisplayString() {
        let shortcut = GlobalShortcut(
            keyCode: 38,
            modifierFlags: [.control, .option, .command, .capsLock]
        )

        XCTAssertNotNil(shortcut)
        XCTAssertEqual(shortcut?.modifierFlags, [.control, .option, .command])
        XCTAssertEqual(shortcut?.displayParts, ["\u{2303}", "\u{2325}", "\u{2318}", "J"])
        XCTAssertEqual(shortcut?.displayString, "\u{2303} \u{2325} \u{2318} J")
    }

    func testDefaultShortcutsRemainDistinct() {
        XCTAssertNotEqual(
            GlobalShortcutAction.openActiveSession.defaultShortcut,
            GlobalShortcutAction.openSessionList.defaultShortcut
        )
    }

    func testDefaultShortcutsUseOptionModifier() {
        XCTAssertEqual(
            GlobalShortcutAction.openActiveSession.defaultShortcut?.modifierFlags,
            [.option]
        )
        XCTAssertEqual(
            GlobalShortcutAction.openSessionList.defaultShortcut?.modifierFlags,
            [.option]
        )
    }
}
