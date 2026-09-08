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

    nonisolated static let assertionReason = "Ping Island: keep awake"

    @Published private(set) var isHoldingAssertion = false
    @Published private(set) var decision: KeepAwakeDecision = .release(.disabled)

    private let settings: AppSettingsStore
    private let assertionClient: SessionKeepAwakeAssertionClient
    private let batteryStatusProvider: () -> SessionKeepAwakeBatteryStatus
    private let nowProvider: () -> Date
    private let powerPollInterval: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var graceTimer: Timer?
    private var batteryTimer: Timer?
    private var stoppedWorkingAt: Date?
    private var cachedHasWorkingSession = false
    private var started = false

    init(
        settings: AppSettingsStore = .shared,
        assertionClient: SessionKeepAwakeAssertionClient = IOPMSystemSleepAssertionClient(),
        batteryStatusProvider: @escaping () -> SessionKeepAwakeBatteryStatus = SystemBatteryStatusReader.current,
        nowProvider: @escaping () -> Date = Date.init,
        observeSessions: Bool = true,
        powerPollInterval: TimeInterval = 30
    ) {
        self.settings = settings
        self.assertionClient = assertionClient
        self.batteryStatusProvider = batteryStatusProvider
        self.nowProvider = nowProvider
        self.powerPollInterval = powerPollInterval

        if observeSessions {
            SessionStore.shared.sessionsPublisher
                .map { sessions in sessions.contains { $0.phase.isActive } }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] hasWorkingSession in
                    self?.handleWorkingSessionChange(hasWorkingSession)
                }
                .store(in: &cancellables)
        }

        settings.$keepAwakeMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPowerState() }
            .store(in: &cancellables)
    }

    deinit {
        graceTimer?.invalidate()
        batteryTimer?.invalidate()
    }

    func start() {
        started = true
        refreshPowerState()
    }

    func stop() {
        started = false
        stoppedWorkingAt = nil
        refreshPowerState()
    }

    /// Aggregate all sessions before applying the transition: one idle session
    /// must not release the assertion while another is still working.
    func handleWorkingSessionChange(_ hasWorkingSession: Bool) {
        if cachedHasWorkingSession && !hasWorkingSession {
            stoppedWorkingAt = nowProvider()
        } else if hasWorkingSession {
            stoppedWorkingAt = nil
        }
        cachedHasWorkingSession = hasWorkingSession
        refreshPowerState()
    }

    /// Used by both settings updates and the power timer. Power changes must not
    /// depend on SessionStore publishing another snapshot during a long tool call.
    func refreshPowerState() {
        let now = nowProvider()
        let mode: KeepAwakeMode = started ? settings.keepAwakeMode : .off
        let battery = mode == .auto
            ? batteryStatusProvider()
            : SessionKeepAwakeBatteryStatus(isOnBattery: false, percentage: nil)
        let elapsed = stoppedWorkingAt.map { now.timeIntervalSince($0) }
        let next = KeepAwakePolicy.decide(for: KeepAwakeInputs(
            mode: mode,
            hasWorkingSession: cachedHasWorkingSession,
            secondsSinceWorking: elapsed,
            isOnBattery: battery.isOnBattery,
            batteryPercent: battery.percentage.map { Int($0) }
        ))

        if next != decision { decision = next }
        applyAssertion(shouldHold: next.isHolding)

        let remaining = elapsed.map { KeepAwakePolicy.defaultGraceSeconds - $0 } ?? 0
        let isInGrace = !cachedHasWorkingSession && remaining > 0
        updateGraceTimer(remaining: mode == .auto && isInGrace ? remaining : nil)
        // Keep checking even after low battery releases the assertion, so AC power
        // or a recovered charge can restore protection without a new session event.
        let needsPowerPolling = mode == .auto && (cachedHasWorkingSession || isInGrace)
        let needsAcquireRetry = next.isHolding && !isHoldingAssertion
        updateBatteryTimer(needed: needsPowerPolling || needsAcquireRetry)
    }

    private func applyAssertion(shouldHold: Bool) {
        let wasHolding = assertionClient.isHolding
        if shouldHold {
            _ = assertionClient.acquire(reason: Self.assertionReason)
        } else {
            assertionClient.release()
        }
        let held = assertionClient.isHolding
        if isHoldingAssertion != held { isHoldingAssertion = held }
        if wasHolding != held {
            IslandTrace.emit("keep_awake", "state=\(held ? "hold" : "release") mode=\(settings.keepAwakeMode.rawValue)")
        }
    }

    private func updateGraceTimer(remaining: TimeInterval?) {
        graceTimer?.invalidate()
        graceTimer = nil
        guard let remaining else { return }

        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPowerState() }
        }
        graceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateBatteryTimer(needed: Bool) {
        guard needed else {
            batteryTimer?.invalidate()
            batteryTimer = nil
            return
        }
        guard batteryTimer == nil else { return }
        let timer = Timer(timeInterval: powerPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPowerState() }
        }
        batteryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
