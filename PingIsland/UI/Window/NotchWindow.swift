//
//  NotchWindow.swift
//  PingIsland
//
//  Transparent window that overlays the notch area
//  Mouse routing follows the visible notch and shared pointer monitoring.
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // The controller arms closed-notch input as the pointer enters its bounds.
        // Areas outside the closed notch remain available to the menu bar.
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Click-through for areas outside the panel content

    static func shouldPassThroughEvent(
        _ type: NSEvent.EventType,
        hitsInteractiveContent: Bool
    ) -> Bool {
        guard !hitsInteractiveContent else { return false }

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            return true
        default:
            return false
        }
    }

    override func sendEvent(_ event: NSEvent) {
        let locationInWindow = event.locationInWindow
        let hitsInteractiveContent = contentView?.hitTest(locationInWindow) != nil
        guard Self.shouldPassThroughEvent(
            event.type,
            hitsInteractiveContent: hitsInteractiveContent
        ) else {
            super.sendEvent(event)
            return
        }

        ignoresMouseEvents = true
        let screenLocation = convertPoint(toScreen: locationInWindow)
        DispatchQueue.main.async { [weak self] in
            self?.repostMouseEvent(event, at: screenLocation)
        }
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        let cgPoint = MouseEventReplay.repostLocation(
            for: event,
            fallbackScreenLocation: screenLocation
        )

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            MouseEventReplay.mark(cgEvent)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
