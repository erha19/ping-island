import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class IslandTextFieldTests: XCTestCase {
    func testTextFieldAcceptsFirstMouseForInactivePanelClicks() {
        let textField = IslandNSTextField()

        XCTAssertTrue(textField.acceptsFirstMouse(for: nil))
    }

    func testTextFieldUsesVisibleTextAndPlaceholderColors() {
        let textField = IslandNSTextField()
        textField.placeholderString = "Type Something ..."

        textField.configureTextAppearance()

        XCTAssertEqual(textField.textColor, NSColor.white)
        XCTAssertEqual(
            textField.placeholderAttributedString?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.white.withAlphaComponent(0.38)
        )
    }
}
