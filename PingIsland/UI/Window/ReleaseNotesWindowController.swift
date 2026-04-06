import AppKit
import SwiftUI

@MainActor
final class ReleaseNotesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ReleaseNotesWindowController()

    private let fixedContentSize = NSSize(width: 840, height: 880)
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))

    private init() {
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: fixedContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = fixedContentSize
        window.maxSize = fixedContentSize
        window.setContentSize(fixedContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("release-notes.window")
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(notes: UpdateReleaseNotes) {
        hostingController.rootView = AnyView(
            ReleaseNotesWindowView(notes: notes) { [weak self] in
                self?.dismiss()
            }
        )

        guard let window else { return }

        window.setContentSize(fixedContentSize)
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
