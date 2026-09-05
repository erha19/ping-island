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

    /// Minimal input routing stays active while hover previews are energy-gated.
    let mouseRoutingLocation = CurrentValueSubject<CGPoint, Never>(.zero)
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
    private var monitoringLevel: EnergyEventMonitoringLevel = .full
    private var cancellables = Set<AnyCancellable>()

    convenience private init() {
        self.init(
            notificationCenter: .default,
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            currentMouseLocation: { NSEvent.mouseLocation },
            monitorFactory: { mask, handler in
                EventMonitor(mask: mask, handler: handler)
            },
            energyPolicyPublisher: EnergyGovernor.shared.$policy.eraseToAnyPublisher()
        )
    }

    init(
        notificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter,
        currentMouseLocation: @escaping () -> CGPoint,
        monitorFactory: @escaping (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> EventMonitoring,
        energyPolicyPublisher: AnyPublisher<EnergyPolicy, Never>? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.currentMouseLocation = currentMouseLocation
        self.monitorFactory = monitorFactory

        observeLifecycle()
        observeEnergyPolicy(energyPolicyPublisher)
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

    private func observeEnergyPolicy(_ publisher: AnyPublisher<EnergyPolicy, Never>?) {
        publisher?
            .map(\.eventMonitoringLevel)
            .removeDuplicates()
            .sink { [weak self] level in
                guard let self, self.monitoringLevel != level else { return }
                self.monitoringLevel = level
                self.restartMonitoring()
            }
            .store(in: &cancellables)
    }

    func restartMonitoring() {
        stopMonitoring()
        setupMonitors(level: monitoringLevel)
        let location = currentMouseLocation()
        mouseRoutingLocation.send(location)
        mouseLocation.send(location)
    }

    private func setupMonitors(level: EnergyEventMonitoringLevel) {
        guard level != .disabled else { return }

        // Even interaction-only mode must arm the closed notch before the first
        // click reaches the menu bar. Keep expensive hover work on mouseLocation.
        mouseMoveMonitor = monitorFactory(.mouseMoved) { [weak self] _ in
            guard let self else { return }
            let location = self.currentMouseLocation()
            self.mouseRoutingLocation.send(location)
            if self.monitoringLevel == .full {
                self.mouseLocation.send(location)
            }
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = monitorFactory(.leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = monitorFactory(.leftMouseDragged) { [weak self] event in
            guard let self else { return }
            let location = self.currentMouseLocation()
            self.mouseRoutingLocation.send(location)
            self.mouseLocation.send(location)
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
