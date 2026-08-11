//
//  NotchWindow.swift
//  PingIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    var shouldAcceptMouseEvents: () -> Bool = { false }

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

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
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
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel:
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

        if event.type == .scrollWheel {
            guard let copiedEvent = event.cgEvent?.copy() else {
                super.sendEvent(event)
                return
            }
            ignoresMouseEvents = true
            MouseEventReplay.mark(copiedEvent)
            copiedEvent.post(tap: .cghidEventTap)

            // Keep the transparent window out of hit testing while Quartz routes
            // the copied wheel event, then restore interaction if the Island is
            // still open. State changes during the delay remain authoritative.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.shouldAcceptMouseEvents() else { return }
                self.ignoresMouseEvents = false
            }
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
