//
//  KeepAwakePolicy.swift
//  PingIsland
//
//  Decides whether the machine should be kept awake based on session state.
//  Kept pure and synchronous so the decision can be unit tested without IOKit,
//  timers, or a running app, in the same spirit as EnergyGovernor.resolvedMode.
//

import Foundation

/// How aggressively PingIsland keeps the machine awake.
enum KeepAwakeMode: String, CaseIterable, Codable, Sendable {
    /// Never take a power assertion. Default; matches behaviour before this feature.
    case off

    /// Take an assertion only while a session is actually working.
    case auto

    /// Take an assertion for as long as the app runs, regardless of session state.
    /// This is the `caffeinate` equivalent and is an explicit user choice, so it
    /// deliberately ignores the battery floor.
    case always
}

struct KeepAwakeInputs: Equatable, Sendable {
    var mode: KeepAwakeMode = .off

    /// True when some session is in `.processing` or `.compacting`.
    ///
    /// Deliberately NOT `EnergyMode.active`: `resolvedMode` returns `.active` for
    /// `hasActiveSession || hasAttentionSession`, and the attention branch is exactly
    /// the case that must release. A session sitting on `.waitingForInput` or
    /// `.waitingForApproval` will not resume on its own, so holding the machine awake
    /// for it burns battery until the user returns and wakes the machine anyway.
    var hasWorkingSession: Bool = false

    /// Seconds since a session was last observed working; nil when never observed.
    var secondsSinceWorking: TimeInterval?

    var isOnBattery: Bool = false

    /// 0-100. Nil when unknown or the machine has no battery.
    var batteryPercent: Int?

    static let empty = KeepAwakeInputs()
}

enum KeepAwakeHoldReason: Equatable, Sendable {
    case alwaysOn
    case sessionWorking
    case graceWindow
}

enum KeepAwakeReleaseReason: Equatable, Sendable {
    case disabled
    case nothingWorking
    case batteryFloor(percent: Int)
}

enum KeepAwakeDecision: Equatable, Sendable {
    case hold(KeepAwakeHoldReason)
    case release(KeepAwakeReleaseReason)

    var isHolding: Bool {
        if case .hold = self { return true }
        return false
    }
}

enum KeepAwakePolicy {
    /// Keep holding for this long after the last working observation.
    ///
    /// Without a grace window the assertion flaps once per model-generation gap: the
    /// pause between one tool finishing and the next starting is indistinguishable
    /// from idle. Measured on an equivalent Windows implementation, no grace window
    /// produced 4 acquire/release cycles in 3 minutes.
    static let defaultGraceSeconds: TimeInterval = 120

    /// Below this charge, `.auto` stops holding. An unattended overnight run can
    /// otherwise flatten the machine, losing the work the assertion was protecting.
    static let defaultBatteryFloorPercent = 35

    nonisolated static func decide(
        for inputs: KeepAwakeInputs,
        graceSeconds: TimeInterval = defaultGraceSeconds,
        batteryFloorPercent: Int = defaultBatteryFloorPercent
    ) -> KeepAwakeDecision {
        switch inputs.mode {
        case .off:
            return .release(.disabled)
        case .always:
            return .hold(.alwaysOn)
        case .auto:
            break
        }

        if inputs.isOnBattery,
           let percent = inputs.batteryPercent,
           percent <= batteryFloorPercent {
            return .release(.batteryFloor(percent: percent))
        }

        if inputs.hasWorkingSession {
            return .hold(.sessionWorking)
        }

        if let elapsed = inputs.secondsSinceWorking, elapsed < graceSeconds {
            return .hold(.graceWindow)
        }

        return .release(.nothingWorking)
    }
}
