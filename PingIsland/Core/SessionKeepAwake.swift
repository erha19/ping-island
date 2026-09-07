//
//  SessionKeepAwake.swift
//  PingIsland
//
//  Holds a system-only IOPM assertion while tracked sessions are working so
//  idle sleep cannot drop an agent mid-run. Waiting-for-input / approval
//  releases (after a short hysteresis), and a battery floor avoids draining
//  an unattended laptop. Toggle lives next to the temporary mute shortcut.
//

import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os.log

struct SessionKeepAwakeBatteryStatus: Equatable, Sendable {
    /// True when the machine is drawing from the internal battery.
    var isOnBattery: Bool
    /// 0...100 when known. Desktops and unknown sources leave this nil.
    var percentage: Double?
}

enum SessionKeepAwakeEvaluator {
    /// Grace window that covers model-generation gaps between tool calls so
    /// the assertion does not flap acquire/release mid-turn.
    nonisolated static let releaseGraceDuration: TimeInterval = 120

    /// Release below this charge while on battery so keep-awake cannot flatten
    /// an unattended machine. AC power ignores the floor.
    nonisolated static let batteryFloorPercentage: Double = 35

    struct Inputs: Equatable, Sendable {
        var featureEnabled: Bool
        var hasWorkingSession: Bool
        var lastWorkingAt: Date?
        var now: Date
        var battery: SessionKeepAwakeBatteryStatus
    }

    /// Pure decision for whether the system idle-sleep assertion should be held.
    nonisolated static func shouldHoldAssertion(_ inputs: Inputs) -> Bool {
        guard inputs.featureEnabled else { return false }

        if inputs.battery.isOnBattery,
           let percentage = inputs.battery.percentage,
           percentage < batteryFloorPercentage {
            return false
        }

        if inputs.hasWorkingSession {
            return true
        }

        guard let lastWorkingAt = inputs.lastWorkingAt else {
            return false
        }

        return inputs.now.timeIntervalSince(lastWorkingAt) < releaseGraceDuration
    }
}

enum SystemBatteryStatusReader {
    nonisolated static func current() -> SessionKeepAwakeBatteryStatus {
        guard let snapshotInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return SessionKeepAwakeBatteryStatus(isOnBattery: false, percentage: nil)
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshotInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return SessionKeepAwakeBatteryStatus(isOnBattery: false, percentage: nil)
        }

        var sawInternalBattery = false
        var isOnBattery = false
        var percentage: Double?

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshotInfo, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = description[kIOPSTypeKey as String] as? String
            guard type == (kIOPSInternalBatteryType as String) else { continue }
            sawInternalBattery = true

            if let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
               maxCapacity > 0 {
                percentage = (Double(currentCapacity) / Double(maxCapacity)) * 100
            } else if let capacity = description[kIOPSCurrentCapacityKey as String] as? Int {
                percentage = Double(capacity)
            }

            let powerState = description[kIOPSPowerSourceStateKey as String] as? String
            if powerState == (kIOPSBatteryPowerValue as String) {
                isOnBattery = true
            }
        }

        guard sawInternalBattery else {
            return SessionKeepAwakeBatteryStatus(isOnBattery: false, percentage: nil)
        }

        return SessionKeepAwakeBatteryStatus(isOnBattery: isOnBattery, percentage: percentage)
    }
}

protocol SessionKeepAwakeAssertionClient: AnyObject {
    func acquire(reason: String) -> Bool
    func release()
    var isHolding: Bool { get }
}

/// System-sleep assertion only — never a display assertion. Lid-close sleep
/// cannot be prevented from user space; document that in the UI help text.
final class IOPMSystemSleepAssertionClient: SessionKeepAwakeAssertionClient {
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "KeepAwake")
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHolding = false

    func acquire(reason: String) -> Bool {
        if isHolding {
            return true
        }

        var nextID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &nextID
        )

        guard status == kIOReturnSuccess else {
            logger.error("IOPMAssertionCreateWithName failed status=\(status, privacy: .public)")
            return false
        }

        assertionID = nextID
        isHolding = true
        return true
    }

    func release() {
        guard isHolding else { return }
        let status = IOPMAssertionRelease(assertionID)
        if status != kIOReturnSuccess {
            logger.error("IOPMAssertionRelease failed status=\(status, privacy: .public)")
        }
        assertionID = 0
        isHolding = false
    }

    deinit {
        if isHolding {
            IOPMAssertionRelease(assertionID)
        }
    }
}

@MainActor
final class SessionKeepAwakeController: ObservableObject {
    static let shared = SessionKeepAwakeController()

    nonisolated static let assertionReason = "Ping Island: agent session working"

    @Published private(set) var isHoldingAssertion = false
    @Published private(set) var isFeatureEnabled = false

    private let settings: AppSettingsStore
    private let assertionClient: SessionKeepAwakeAssertionClient
    private let batteryStatusProvider: () -> SessionKeepAwakeBatteryStatus
    private let nowProvider: () -> Date
    private var cancellables = Set<AnyCancellable>()
    private var graceTimer: Timer?
    private var batteryTimer: Timer?
    private var lastWorkingAt: Date?
    private var cachedHasWorkingSession = false
    private var started = false

    init(
        settings: AppSettingsStore = .shared,
        assertionClient: SessionKeepAwakeAssertionClient = IOPMSystemSleepAssertionClient(),
        batteryStatusProvider: @escaping () -> SessionKeepAwakeBatteryStatus = SystemBatteryStatusReader.current,
        nowProvider: @escaping () -> Date = Date.init,
        observeSessions: Bool = true
    ) {
        self.settings = settings
        self.assertionClient = assertionClient
        self.batteryStatusProvider = batteryStatusProvider
        self.nowProvider = nowProvider
        self.isFeatureEnabled = settings.preventSleepWhileWorkingEnabled

        if observeSessions {
            SessionStore.shared.sessionsPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] sessions in
                    self?.handleSessions(sessions)
                }
                .store(in: &cancellables)
        }

        settings.$preventSleepWhileWorkingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.isFeatureEnabled = enabled
                self?.reevaluate(hasWorkingSession: self?.cachedHasWorkingSession ?? false)
            }
            .store(in: &cancellables)
    }

    deinit {
        graceTimer?.invalidate()
        batteryTimer?.invalidate()
    }

    func start() {
        started = true
        isFeatureEnabled = settings.preventSleepWhileWorkingEnabled
        reevaluate(hasWorkingSession: cachedHasWorkingSession)
        refreshBatteryPolling()
    }

    func stop() {
        started = false
        graceTimer?.invalidate()
        graceTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        applyAssertion(shouldHold: false)
    }

    private func handleSessions(_ sessions: [SessionState]) {
        let hasWorkingSession = sessions.contains { $0.phase.isActive }
        cachedHasWorkingSession = hasWorkingSession
        reevaluate(hasWorkingSession: hasWorkingSession)
    }

    private func reevaluate(hasWorkingSession: Bool) {
        let now = nowProvider()
        if hasWorkingSession {
            lastWorkingAt = now
        }

        let shouldHold = SessionKeepAwakeEvaluator.shouldHoldAssertion(
            .init(
                featureEnabled: settings.preventSleepWhileWorkingEnabled && started,
                hasWorkingSession: hasWorkingSession,
                lastWorkingAt: lastWorkingAt,
                now: now,
                battery: batteryStatusProvider()
            )
        )

        applyAssertion(shouldHold: shouldHold)
        scheduleGraceTimerIfNeeded(hasWorkingSession: hasWorkingSession, now: now)
        refreshBatteryPolling()
    }

    private func applyAssertion(shouldHold: Bool) {
        if shouldHold {
            let wasHolding = assertionClient.isHolding
            let acquired = assertionClient.acquire(reason: Self.assertionReason)
            isHoldingAssertion = acquired && assertionClient.isHolding
            if acquired && !wasHolding {
                IslandTrace.emit(
                    "keep_awake",
                    "state=hold feature=\(settings.preventSleepWhileWorkingEnabled)"
                )
            }
            return
        }

        guard assertionClient.isHolding || isHoldingAssertion else {
            isHoldingAssertion = false
            return
        }

        assertionClient.release()
        isHoldingAssertion = false
        IslandTrace.emit(
            "keep_awake",
            "state=release feature=\(settings.preventSleepWhileWorkingEnabled)"
        )
    }

    private func scheduleGraceTimerIfNeeded(hasWorkingSession: Bool, now: Date) {
        graceTimer?.invalidate()
        graceTimer = nil

        guard settings.preventSleepWhileWorkingEnabled,
              started,
              !hasWorkingSession,
              let lastWorkingAt else {
            return
        }

        let remaining = SessionKeepAwakeEvaluator.releaseGraceDuration - now.timeIntervalSince(lastWorkingAt)
        guard remaining > 0 else { return }

        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reevaluate(hasWorkingSession: self.cachedHasWorkingSession)
            }
        }
        graceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshBatteryPolling() {
        let shouldPoll = started && settings.preventSleepWhileWorkingEnabled && isHoldingAssertion
        if shouldPoll {
            guard batteryTimer == nil else { return }
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reevaluate(hasWorkingSession: self.cachedHasWorkingSession)
                }
            }
            batteryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            batteryTimer?.invalidate()
            batteryTimer = nil
        }
    }
}
