//
//  EnergyGovernor.swift
//  PingIsland
//
//  Coordinates app-wide low-power behavior so background services and UI
//  animation degrade together during quiet, locked, or sleeping periods.
//

import AppKit
import Combine
import Foundation

enum EnergyMode: Equatable {
    case active
    case idleVisible
    case quietBackground
    case systemSuspended
    case wakeGrace
}

enum EnergyAnimationLevel: Equatable {
    case full
    case reduced
    case staticFrames
}

enum EnergyEventMonitoringLevel: Equatable {
    case disabled
    case interactionOnly
    case full
}

struct EnergyPolicy: Equatable {
    let codexThreadListRefreshInterval: Duration?
    let sessionMaintenanceInterval: Duration?
    let usageRefreshInterval: Duration?
    let animationLevel: EnergyAnimationLevel
    let eventMonitoringLevel: EnergyEventMonitoringLevel
    let allowsSilentUpdates: Bool
    let allowsFileWatcherRetry: Bool

    static func policy(for mode: EnergyMode) -> EnergyPolicy {
        switch mode {
        case .active:
            EnergyPolicy(
                codexThreadListRefreshInterval: .seconds(15),
                sessionMaintenanceInterval: .seconds(60),
                usageRefreshInterval: .seconds(60),
                animationLevel: .full,
                eventMonitoringLevel: .full,
                allowsSilentUpdates: false,
                allowsFileWatcherRetry: true
            )
        case .idleVisible:
            EnergyPolicy(
                codexThreadListRefreshInterval: .seconds(60),
                sessionMaintenanceInterval: .seconds(5 * 60),
                usageRefreshInterval: .seconds(5 * 60),
                animationLevel: .reduced,
                eventMonitoringLevel: .interactionOnly,
                allowsSilentUpdates: true,
                allowsFileWatcherRetry: true
            )
        case .quietBackground:
            EnergyPolicy(
                codexThreadListRefreshInterval: .seconds(5 * 60),
                sessionMaintenanceInterval: .seconds(10 * 60),
                usageRefreshInterval: .seconds(15 * 60),
                animationLevel: .staticFrames,
                eventMonitoringLevel: .interactionOnly,
                allowsSilentUpdates: true,
                allowsFileWatcherRetry: true
            )
        case .systemSuspended:
            EnergyPolicy(
                codexThreadListRefreshInterval: nil,
                sessionMaintenanceInterval: nil,
                usageRefreshInterval: nil,
                animationLevel: .staticFrames,
                eventMonitoringLevel: .disabled,
                allowsSilentUpdates: false,
                allowsFileWatcherRetry: false
            )
        case .wakeGrace:
            EnergyPolicy(
                codexThreadListRefreshInterval: .seconds(30),
                sessionMaintenanceInterval: .seconds(60),
                usageRefreshInterval: .seconds(5 * 60),
                animationLevel: .reduced,
                eventMonitoringLevel: .interactionOnly,
                allowsSilentUpdates: false,
                allowsFileWatcherRetry: true
            )
        }
    }
}

struct EnergyGovernorInputs: Equatable {
    var hasActiveSession: Bool
    var hasAttentionSession: Bool
    var hasRecentSessionActivity: Bool
    var hasVisibleSession: Bool
    var isSystemSuspended: Bool
    var isWakeGraceActive: Bool
    var isLowPowerModeEnabled: Bool

    static let empty = EnergyGovernorInputs(
        hasActiveSession: false,
        hasAttentionSession: false,
        hasRecentSessionActivity: false,
        hasVisibleSession: false,
        isSystemSuspended: false,
        isWakeGraceActive: false,
        isLowPowerModeEnabled: false
    )
}

@MainActor
final class EnergyGovernor: ObservableObject {
    static let shared = EnergyGovernor()
    nonisolated static let idleVisibleAnimationGraceDuration: TimeInterval = 10 * 60

    @Published private(set) var mode: EnergyMode = .quietBackground
    @Published private(set) var policy: EnergyPolicy = EnergyPolicy.policy(for: .quietBackground)

    private var inputs = EnergyGovernorInputs.empty
    private var cancellables = Set<AnyCancellable>()
    private var wakeGraceTask: Task<Void, Never>?

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observeSessions: Bool = true
    ) {
        inputs.isLowPowerModeEnabled = Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled

        if observeSessions {
            SessionStore.shared.sessionsPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] sessions in
                    self?.updateSessions(sessions)
                }
                .store(in: &cancellables)
        }

        observeLifecycle(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        applyResolvedMode()
    }

    deinit {
        wakeGraceTask?.cancel()
    }

    nonisolated static func resolvedMode(for inputs: EnergyGovernorInputs) -> EnergyMode {
        if inputs.isSystemSuspended {
            return .systemSuspended
        }
        if inputs.hasActiveSession || inputs.hasAttentionSession {
            return .active
        }
        if inputs.isWakeGraceActive {
            return .wakeGrace
        }
        if inputs.hasVisibleSession && inputs.hasRecentSessionActivity && !inputs.isLowPowerModeEnabled {
            return .idleVisible
        }
        return .quietBackground
    }

    private func observeLifecycle(
        notificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter
    ) {
        let suspendedNotifications: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        for name in suspendedNotifications {
            workspaceNotificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    self?.setSystemSuspended(true)
                }
                .store(in: &cancellables)
        }

        let resumedNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in resumedNotifications {
            workspaceNotificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    self?.resumeFromSuspension()
                }
                .store(in: &cancellables)
        }

        notificationCenter.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in
                self?.setLowPowerMode(Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
            .store(in: &cancellables)
    }

    private func updateSessions(_ sessions: [SessionState]) {
        let now = Date()
        let next = EnergyGovernorInputs(
            hasActiveSession: sessions.contains { $0.phase.isActive },
            hasAttentionSession: sessions.contains { $0.needsAttention },
            hasRecentSessionActivity: sessions.contains {
                !$0.shouldHideFromPrimaryUI &&
                now.timeIntervalSince($0.lastActivity) <= Self.idleVisibleAnimationGraceDuration
            },
            hasVisibleSession: sessions.contains { !$0.shouldHideFromPrimaryUI },
            isSystemSuspended: inputs.isSystemSuspended,
            isWakeGraceActive: inputs.isWakeGraceActive,
            isLowPowerModeEnabled: inputs.isLowPowerModeEnabled
        )
        updateInputs(next)
    }

    private func setSystemSuspended(_ isSuspended: Bool) {
        var next = inputs
        next.isSystemSuspended = isSuspended
        if isSuspended {
            next.isWakeGraceActive = false
            wakeGraceTask?.cancel()
            wakeGraceTask = nil
        }
        updateInputs(next)
    }

    private func resumeFromSuspension() {
        wakeGraceTask?.cancel()
        var next = inputs
        next.isSystemSuspended = false
        next.isWakeGraceActive = true
        updateInputs(next)

        wakeGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                var next = self.inputs
                next.isWakeGraceActive = false
                self.updateInputs(next)
                self.wakeGraceTask = nil
            }
        }
    }

    private func setLowPowerMode(_ isEnabled: Bool) {
        var next = inputs
        next.isLowPowerModeEnabled = isEnabled
        updateInputs(next)
    }

    private func updateInputs(_ next: EnergyGovernorInputs) {
        guard next != inputs else { return }
        inputs = next
        applyResolvedMode()
    }

    private func applyResolvedMode() {
        let nextMode = Self.resolvedMode(for: inputs)
        guard nextMode != mode else { return }
        mode = nextMode
        policy = EnergyPolicy.policy(for: nextMode)
    }
}
