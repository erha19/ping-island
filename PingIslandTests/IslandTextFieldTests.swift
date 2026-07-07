import AppKit
import SwiftUI
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

    func testEditableTextFieldKeepsFirstResponderDuringTransientFocusMismatch() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = IslandNSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        let parent = IslandTextField(
            placeholder: "Answer",
            text: .constant(""),
            isFocused: false,
            isEditable: true
        )
        let coordinator = IslandTextField.Coordinator(parent: parent)
        textField.delegate = coordinator
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(textField)
        defer { window.orderOut(nil) }

        coordinator.focus(textField)
        XCTAssertTrue(isEditing(textField, in: window))

        coordinator.syncFocus(for: textField)

        XCTAssertTrue(isEditing(textField, in: window))
    }

    func testMarkedTextChangeStaysLocalUntilCompositionCommits() throws {
        var publishedText = ""
        let (window, textField, coordinator) = makeFocusedTextField(
            text: Binding(
                get: { publishedText },
                set: { publishedText = $0 }
            )
        )
        defer { window.orderOut(nil) }

        let editor = try XCTUnwrap(textField.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "ni" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())

        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: textField)
        )

        XCTAssertEqual(publishedText, "")

        editor.unmarkText()
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: textField)
        )

        XCTAssertEqual(publishedText, "ni")
    }

    func testMarkedTextSyncDoesNotOverwriteActiveComposition() throws {
        let (window, textField, coordinator) = makeFocusedTextField(text: .constant(""))
        defer { window.orderOut(nil) }

        let editor = try XCTUnwrap(textField.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "zhong" as NSString,
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())

        coordinator.syncText("", for: textField)

        XCTAssertEqual(editor.string, "zhong")
        XCTAssertTrue(editor.hasMarkedText())
    }

    private func isEditing(_ textField: IslandNSTextField, in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }
        return firstResponder === textField || firstResponder === textField.currentEditor()
    }

    private func makeFocusedTextField(
        text: Binding<String>
    ) -> (window: NSWindow, textField: IslandNSTextField, coordinator: IslandTextField.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = IslandNSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        let parent = IslandTextField(
            placeholder: "Answer",
            text: text,
            isFocused: true,
            isEditable: true
        )
        let coordinator = IslandTextField.Coordinator(parent: parent)
        textField.delegate = coordinator
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(textField)
        coordinator.focus(textField)
        XCTAssertTrue(isEditing(textField, in: window))

        return (window, textField, coordinator)
    }
}
