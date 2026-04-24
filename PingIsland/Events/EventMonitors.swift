//
//  EventMonitors.swift
//  PingIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

@MainActor
final class EventMonitors {
    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()
    let mouseDragged = PassthroughSubject<NSEvent, Never>()
    let mouseUp = PassthroughSubject<NSEvent, Never>()

    private var mouseMoveMonitor: EventMonitoring?
    private var mouseDownMonitor: EventMonitoring?
    private var mouseDraggedMonitor: EventMonitoring?
    private var mouseUpMonitor: EventMonitoring?
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let currentMouseLocation: () -> CGPoint
    private let monitorFactory: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> EventMonitoring
    private var cancellables = Set<AnyCancellable>()

    convenience private init() {
        self.init(
            notificationCenter: .default,
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            currentMouseLocation: { NSEvent.mouseLocation },
            monitorFactory: { mask, handler in
                EventMonitor(mask: mask, handler: handler)
            }
        )
    }

    init(
        notificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter,
        currentMouseLocation: @escaping () -> CGPoint,
        monitorFactory: @escaping (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> EventMonitoring
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.currentMouseLocation = currentMouseLocation
        self.monitorFactory = monitorFactory

        observeLifecycle()
        restartMonitoring()
    }

    private func observeLifecycle() {
        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.restartMonitoring()
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.restartMonitoring()
            }
            .store(in: &cancellables)

        workspaceNotificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.restartMonitoring()
            }
            .store(in: &cancellables)

        workspaceNotificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.restartMonitoring()
            }
            .store(in: &cancellables)
    }

    func restartMonitoring() {
        stopMonitoring()
        setupMonitors()
        mouseLocation.send(currentMouseLocation())
    }

    private func setupMonitors() {
        mouseMoveMonitor = monitorFactory(.mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.mouseLocation.send(self.currentMouseLocation())
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = monitorFactory(.leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = monitorFactory(.leftMouseDragged) { [weak self] event in
            guard let self else { return }
            self.mouseLocation.send(self.currentMouseLocation())
            self.mouseDragged.send(event)
        }
        mouseDraggedMonitor?.start()

        mouseUpMonitor = monitorFactory(.leftMouseUp) { [weak self] event in
            self?.mouseUp.send(event)
        }
        mouseUpMonitor?.start()
    }

    private func stopMonitoring() {
        mouseMoveMonitor?.stop()
        mouseMoveMonitor = nil
        mouseDownMonitor?.stop()
        mouseDownMonitor = nil
        mouseDraggedMonitor?.stop()
        mouseDraggedMonitor = nil
        mouseUpMonitor?.stop()
        mouseUpMonitor = nil
    }
}
