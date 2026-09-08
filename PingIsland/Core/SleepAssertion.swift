//
//  SleepAssertion.swift
//  PingIsland
//
//  Thin wrapper around a single IOKit power assertion.
//
//  System sleep only, never display sleep: an agent working in the background has
//  nothing to show, and holding the display awake is the larger battery cost of the
//  two. The assertion is named so it is identifiable in `pmset -g assertions`.
//

import Foundation
import IOKit.pwr_mgt

final class SleepAssertion {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isHeld = false

    private let name: String

    init(name: String = "PingIsland: agent session working") {
        self.name = name
    }

    /// Takes the assertion if not already held. Idempotent.
    /// - Returns: true when an assertion is held on return.
    @discardableResult
    func hold() -> Bool {
        guard !isHeld else { return true }

        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &identifier
        )

        guard result == kIOReturnSuccess else { return false }

        assertionID = identifier
        isHeld = true
        return true
    }

    /// Releases the assertion if held. Idempotent.
    /// - Returns: true when no assertion is held on return.
    @discardableResult
    func release() -> Bool {
        guard isHeld else { return true }

        let result = IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isHeld = false
        return result == kIOReturnSuccess
    }

    func apply(_ decision: KeepAwakeDecision) {
        if decision.isHolding {
            hold()
        } else {
            release()
        }
    }

    deinit {
        if isHeld {
            IOPMAssertionRelease(assertionID)
        }
    }
}
