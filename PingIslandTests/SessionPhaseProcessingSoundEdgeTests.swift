import XCTest
@testable import Ping_Island

/// Tests for `SessionPhase.contributesToProcessingSoundEdge`, the predicate
/// that decides whether a session keeps participating in the
/// `processingStarted` notification-sound edge set. Regression coverage for
/// the bug where a PermissionRequest → auto-approve flow briefly removed
/// the session from the set (because `.waitingForApproval` was excluded)
/// and the re-entry then fired a spurious processingStarted edge right
/// before the Stop-driven taskCompleted, audible as two chimes at once.
final class SessionPhaseProcessingSoundEdgeTests: XCTestCase {

    func testProcessingPhaseContributes() {
        XCTAssertTrue(SessionPhase.processing.contributesToProcessingSoundEdge)
    }

    func testCompactingPhaseContributes() {
        XCTAssertTrue(SessionPhase.compacting.contributesToProcessingSoundEdge)
    }

    func testWaitingForApprovalPhaseContributes() {
        let phase: SessionPhase = .waitingForApproval(PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date()
        ))
        XCTAssertTrue(
            phase.contributesToProcessingSoundEdge,
            "PermissionRequest must keep the session in the processing set so resolution does not trigger a spurious processingStarted edge"
        )
    }

    func testIdlePhaseDoesNotContribute() {
        XCTAssertFalse(SessionPhase.idle.contributesToProcessingSoundEdge)
    }

    func testWaitingForInputPhaseDoesNotContribute() {
        XCTAssertFalse(
            SessionPhase.waitingForInput.contributesToProcessingSoundEdge,
            "Stop transitions the phase to .waitingForInput; this MUST exit the processing set so taskCompleted edge fires correctly"
        )
    }

    func testEndedPhaseDoesNotContribute() {
        XCTAssertFalse(SessionPhase.ended.contributesToProcessingSoundEdge)
    }

    /// Regression: simulate the membership delta across the
    /// `.processing → .waitingForApproval → .processing` round-trip and
    /// assert no spurious "new entry" appears.
    func testPermissionRequestRoundTripDoesNotProduceNewEntry() {
        let stableId = "session-roundtrip"
        let phaseBefore: SessionPhase = .processing
        let phaseDuring: SessionPhase = .waitingForApproval(PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date()
        ))
        let phaseAfter: SessionPhase = .processing

        // Frame 1: session is in .processing — it should be in the set.
        let setBefore: Set<String> = phaseBefore.contributesToProcessingSoundEdge ? [stableId] : []
        // Frame 2: PermissionRequest hook arrives — the session should STILL
        // be in the set (this is the fix; pre-fix this set went to {}).
        let setDuring: Set<String> = phaseDuring.contributesToProcessingSoundEdge ? [stableId] : []
        // Frame 3: resolution completes — session is back in .processing.
        let setAfter: Set<String> = phaseAfter.contributesToProcessingSoundEdge ? [stableId] : []

        // The "new entry" delta on each transition must be empty so that
        // processingStarted does not fire spuriously during the round-trip.
        XCTAssertTrue(
            setDuring.subtracting(setBefore).isEmpty,
            "Entering .waitingForApproval must not introduce a new processing-set member"
        )
        XCTAssertTrue(
            setAfter.subtracting(setDuring).isEmpty,
            "Returning to .processing from .waitingForApproval must not introduce a new processing-set member"
        )
    }
}
