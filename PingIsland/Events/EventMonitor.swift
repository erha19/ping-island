//
//  EventMonitor.swift
//  PingIsland
//
//  Wraps NSEvent monitoring for safe lifecycle management
//

import AppKit

protocol EventMonitoring: AnyObject {
    func start()
    func stop()
}

enum MouseEventReplay {
    private static let marker: Int64 = 0x50494E47

    static func isReplayed(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func appKitScreenLocation(
        for event: NSEvent,
        fallbackScreenLocation: NSPoint? = nil
    ) -> CGPoint {
        if let cgLocation = event.cgEvent?.location {
            return appKitScreenLocation(fromQuartzScreenLocation: cgLocation)
        }

        return fallbackScreenLocation ?? .zero
    }

    static func repostLocation(for event: NSEvent, fallbackScreenLocation: NSPoint? = nil) -> CGPoint {
        if let cgLocation = event.cgEvent?.location {
            return cgLocation
        }

        guard let fallbackScreenLocation else {
            return .zero
        }

        return quartzScreenLocation(fromAppKitScreenLocation: fallbackScreenLocation)
    }

    static func appKitScreenLocation(
        fromQuartzScreenLocation location: CGPoint,
        screenBounds: CGRect? = nil
    ) -> CGPoint {
        guard let bounds = resolvedScreenBounds(fallback: screenBounds) else {
            return location
        }

        return CGPoint(
            x: location.x,
            y: bounds.maxY - location.y
        )
    }

    private static func quartzScreenLocation(fromAppKitScreenLocation location: CGPoint) -> CGPoint {
        guard let bounds = resolvedScreenBounds() else {
            return location
        }

        return CGPoint(
            x: location.x,
            y: bounds.maxY - location.y
        )
    }

    private static func resolvedScreenBounds(fallback: CGRect? = nil) -> CGRect? {
        let screenBounds = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }

        if !screenBounds.isNull {
            return screenBounds
        }

        return fallback
    }
}

final class EventMonitor: EventMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        // Global monitor for events outside our app
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
        }

        // Local monitor for events inside our app
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
