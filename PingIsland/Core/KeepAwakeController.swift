//
//  KeepAwakeController.swift
//  PingIsland
//
//  Wires session state and the user's KeepAwakeMode into a single power assertion.
//  The decision itself lives in KeepAwakePolicy so it stays unit testable; this type
//  only gathers inputs, drives the grace-window re-evaluation, and applies the result.
//

import Combine
import Foundation
import IOKit.ps

@MainActor
final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    @Published private(set) var decision: KeepAwakeDecision = .release(.disabled)

    private let assertion: SleepAssertion
    private var cancellables = Set<AnyCancellable>()
    private var lastWorkingAt: Date?
    private var hasWorkingSession = false
    private var graceTimer: Timer?

    /// Re-evaluate this often while inside the grace window, so the assertion is
    /// dropped promptly once the window expires rather than waiting for the next
    /// session event, which may never come.
    private static let graceTickInterval: TimeInterval = 15

    init(
        assertion: SleepAssertion = SleepAssertion(),
        observeSessions: Bool = true
    ) {
        self.assertion = assertion

        guard observeSessions else { return }

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateSessions(sessions)
            }
            .store(in: &cancellables)

        AppSettingsStore.shared.$keepAwakeMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)
    }

    deinit {
        graceTimer?.invalidate()
    }

    private func updateSessions(_ sessions: [SessionState]) {
        // `phase.isActive` is .processing/.compacting only. Deliberately not
        // `needsAttention`: a session waiting on the user will not resume by itself.
        hasWorkingSession = sessions.contains { $0.phase.isActive }
        if hasWorkingSession {
            lastWorkingAt = Date()
        }
        reevaluate()
    }

    private func reevaluate() {
        let power = Self.currentPowerState()
        let hasWorking = hasWorkingSession

        var inputs = KeepAwakeInputs.empty
        inputs.mode = AppSettingsStore.shared.keepAwakeMode
        inputs.hasWorkingSession = hasWorking
        inputs.secondsSinceWorking = lastWorkingAt.map { Date().timeIntervalSince($0) }
        inputs.isOnBattery = power.isOnBattery
        inputs.batteryPercent = power.percent

        let next = KeepAwakePolicy.decide(for: inputs)
        if next != decision {
            decision = next
        }
        assertion.apply(next)
        updateGraceTimer(isHolding: next.isHolding, hasWorking: hasWorking)
    }

    /// Only tick while holding without an actively working session, i.e. inside the
    /// grace window. Holding because work is in progress needs no timer, and releasing
    /// needs none either.
    private func updateGraceTimer(isHolding: Bool, hasWorking: Bool) {
        let needsTimer = isHolding && !hasWorking
        if needsTimer {
            guard graceTimer == nil else { return }
            graceTimer = Timer.scheduledTimer(
                withTimeInterval: Self.graceTickInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in self?.reevaluate() }
            }
        } else {
            graceTimer?.invalidate()
            graceTimer = nil
        }
    }

    // MARK: - Power source

    struct PowerState: Equatable {
        var isOnBattery: Bool
        var percent: Int?
    }

    nonisolated static func currentPowerState() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerState(isOnBattery: false, percent: nil)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            let isOnBattery = (state == kIOPSBatteryPowerValue)

            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                percent = Int((Double(current) / Double(maximum)) * 100.0)
            }

            return PowerState(isOnBattery: isOnBattery, percent: percent)
        }

        // Desktops report no power sources; treat that as wall power.
        return PowerState(isOnBattery: false, percent: nil)
    }
}
