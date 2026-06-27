import AppKit
import SwiftUI

struct IslandTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var isFocused: Bool
    var isEditable: Bool = true
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> IslandNSTextField {
        let textField = IslandNSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        textField.configureTextAppearance()
        textField.focusHandler = { [weak textField, weak coordinator = context.coordinator] in
            guard let textField else { return }
            coordinator?.focus(textField)
        }
        return textField
    }

    func updateNSView(_ textField: IslandNSTextField, context: Context) {
        context.coordinator.parent = self

        if textField.stringValue != text {
            textField.stringValue = text
        }

        textField.placeholderString = placeholder
        textField.isEditable = isEditable
        textField.isEnabled = isEditable
        textField.configureTextAppearance()

        DispatchQueue.main.async {
            context.coordinator.syncFocus(for: textField)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IslandTextField

        init(parent: IslandTextField) {
            self.parent = parent
        }

        func syncFocus(for textField: IslandNSTextField) {
            let hasFocus = hasFocus(textField)
            if parent.isFocused {
                if hasFocus {
                    textField.configureEditorAppearance()
                } else {
                    focus(textField)
                }
            } else if hasFocus {
                textField.window?.makeFirstResponder(nil)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? IslandNSTextField else { return }
            parent.onFocusChanged(true)
            textField.configureTextAppearance()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }

        @objc func submit() {
            parent.onSubmit()
        }

        func focus(_ textField: IslandNSTextField) {
            guard parent.isEditable, let window = textField.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(textField)
            textField.configureEditorAppearance()
        }

        private func hasFocus(_ textField: IslandNSTextField) -> Bool {
            guard let firstResponder = textField.window?.firstResponder else { return false }
            return firstResponder === textField || firstResponder === textField.currentEditor()
        }
    }
}

final class IslandNSTextField: NSTextField {
    var focusHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
        configureEditorAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        configureEditorAppearance()
        return didBecomeFirstResponder
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configureTextAppearance() {
        textColor = .white
        placeholderAttributedString = NSAttributedString(
            string: placeholderString ?? "",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: font ?? NSFont.systemFont(ofSize: 13),
            ]
        )
        configureEditorAppearance()
    }

    func configureEditorAppearance() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .controlAccentColor
    }
}
