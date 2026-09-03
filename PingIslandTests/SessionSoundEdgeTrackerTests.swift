import XCTest
@testable import Ping_Island

/// Coverage for the semantic sound edge detector.
///
/// The Island's primary list is filtered, deduplicated, and sorted before it
/// reaches these surfaces, so a session can enter or leave it without its own
/// state changing. The tracker must key on the session, not on list membership:
/// two Claude sessions sharing a directory used to trade places in the list every
/// few seconds, and a whole-set diff read every swap as "a session started
/// processing".
final class SessionSoundEdgeTrackerTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String,
        pid: Int? = nil,
        provider: SessionProvider = .claude,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        completedErrorToolIDs: Set<String> = [],
        suppressInAppPromptControls: Bool = false,
        latestTurnId: String? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/ping-island-workspace",
            provider: provider,
            clientInfo: provider == .codex
                ? SessionClientInfo.codexApp(threadId: id)
                : SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            suppressInAppPromptControls: suppressInAppPromptControls,
            pid: pid,
            phase: phase,
            chatItems: chatItems,
            completedErrorToolIDs: completedErrorToolIDs,
            latestTurnId: latestTurnId,
            lastActivity: reference
        )
    }

    private func completedSession(
        id: String,
        pid: Int? = nil,
        provider: SessionProvider = .claude,
        turnId: String? = nil,
        assistantItemId: String? = nil
    ) -> SessionState {
        session(
            id: id,
            pid: pid,
            provider: provider,
            phase: provider == .codex ? .idle : .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: assistantItemId ?? "\(id)-reply",
                    type: .assistant("done"),
                    timestamp: reference
                )
            ],
            latestTurnId: turnId
        )
    }

    // MARK: - Priming

    func testFirstSnapshotIsAdoptedSilently() {
        var tracker = SessionSoundEdgeTracker()
        XCTAssertFalse(tracker.isPrimed)

        XCTAssertNil(tracker.edge(for: [session(id: "a", phase: .processing)]))
        XCTAssertTrue(tracker.isPrimed)
    }

    func testExplicitPrimeSuppressesTheFirstEdge() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .processing)])

        XCTAssertNil(tracker.edge(for: [session(id: "a", phase: .processing)]))
    }

    // MARK: - Processing edges

    func testEnteringProcessingFiresOnce() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .idle)])

        let edge = tracker.edge(for: [session(id: "a", phase: .processing)])
        XCTAssertEqual(edge?.event, .processingStarted)
        XCTAssertEqual(edge?.sessions.map(\.sessionId), ["a"])

        XCTAssertNil(
            tracker.edge(for: [session(id: "a", phase: .processing)]),
            "Staying in processing is not an edge"
        )
    }

    func testNewProcessingSessionUsesSessionStartedCue() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", pid: 1, phase: .processing)])

        let edge = tracker.edge(for: [
            session(id: "a", pid: 1, phase: .processing),
            session(id: "b", pid: 2, phase: .processing)
        ])

        XCTAssertEqual(edge?.event, .sessionStarted)
        XCTAssertEqual(
            edge?.sessions.map(\.sessionId),
            ["b"],
            "The focus-based mute must be evaluated against the terminal that caused the sound, not every busy session"
        )
    }

    func testReturningToProcessingAfterIdleFiresAgain() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .processing)])

        XCTAssertNil(tracker.edge(for: [session(id: "a", phase: .idle)]))
        XCTAssertEqual(
            tracker.edge(for: [session(id: "a", phase: .processing)])?.event,
            .processingStarted
        )
    }

    // MARK: - List churn

    func testSessionsTradingPlacesInTheListStayQuiet() {
        let a = session(id: "a", pid: 1, phase: .processing)
        let b = session(id: "b", pid: 2, phase: .processing)

        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [a])

        var events: [AppSoundFeedbackEvent] = []
        // The list can only show one of the two, and which one it shows changes
        // every time the other reports activity.
        for index in 0..<12 {
            let visible = index.isMultiple(of: 2) ? b : a
            if let edge = tracker.edge(for: [visible]) {
                events.append(edge.event)
            }
        }

        XCTAssertEqual(
            events,
            [.sessionStarted],
            "Only the first sighting of the second session is a real edge; the remaining swaps are list churn"
        )
    }

    func testDisappearingSessionDoesNotReplayItsStateOnReturn() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .processing)])

        XCTAssertNil(tracker.edge(for: []))
        XCTAssertNil(
            tracker.edge(for: [session(id: "a", phase: .processing)]),
            "Absence from the list is not a state change"
        )
    }

    // MARK: - Other events

    func testAttentionEdgeCarriesOnlyTheNewlyWaitingSession() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", pid: 1, suppressInAppPromptControls: true)])

        let edge = tracker.edge(for: [
            session(id: "a", pid: 1, suppressInAppPromptControls: true),
            session(id: "b", pid: 2, suppressInAppPromptControls: true)
        ])

        XCTAssertEqual(edge?.event, .attentionRequired)
        XCTAssertEqual(edge?.sessions.map(\.sessionId), ["b"])
    }

    func testCompletionFiresOncePerSession() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .processing)])

        let edge = tracker.edge(for: [completedSession(id: "a")])
        XCTAssertEqual(edge?.event, .taskCompleted)
        XCTAssertEqual(edge?.sessions.map(\.sessionId), ["a"])

        XCTAssertNil(tracker.edge(for: [completedSession(id: "a")]))
    }

    func testSameCodexCompletionTurnReplayedTenTimesOnlyFiresOnce() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [
            session(id: "codex", provider: .codex, phase: .processing, latestTurnId: "turn-1")
        ])

        var completionCount = 0
        for _ in 0..<10 {
            let completed = completedSession(
                id: "codex",
                provider: .codex,
                turnId: "turn-1",
                assistantItemId: "assistant-1"
            )
            if tracker.edge(for: [completed])?.event == .taskCompleted {
                completionCount += 1
            }
            _ = tracker.edge(for: [
                session(id: "codex", provider: .codex, phase: .processing, latestTurnId: "turn-1")
            ])
        }

        XCTAssertEqual(completionCount, 1)
    }

    func testNewCodexTurnCanPlayCompletionAfterPreviousTurnWasConsumed() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [
            session(id: "codex", provider: .codex, phase: .processing, latestTurnId: "turn-1")
        ])

        XCTAssertEqual(
            tracker.edge(for: [completedSession(
                id: "codex",
                provider: .codex,
                turnId: "turn-1",
                assistantItemId: "assistant-1"
            )])?.event,
            .taskCompleted
        )

        _ = tracker.edge(for: [
            session(id: "codex", provider: .codex, phase: .processing, latestTurnId: "turn-2")
        ])

        XCTAssertEqual(
            tracker.edge(for: [completedSession(
                id: "codex",
                provider: .codex,
                turnId: "turn-2",
                assistantItemId: "assistant-2"
            )])?.event,
            .taskCompleted
        )
    }

    func testSharedTrackerDoesNotReplayCompletionWhenPresentationSurfaceChanges() {
        var sharedTracker = SessionSoundEdgeTracker()
        sharedTracker.prime(with: [
            session(id: "codex", provider: .codex, phase: .processing, latestTurnId: "turn-1")
        ])
        let completed = completedSession(
            id: "codex",
            provider: .codex,
            turnId: "turn-1",
            assistantItemId: "assistant-1"
        )

        XCTAssertEqual(sharedTracker.edge(for: [completed])?.event, .taskCompleted)
        XCTAssertNil(
            sharedTracker.edge(for: [completed]),
            "The SessionMonitor-owned tracker must outlive docked/floating surface reconstruction"
        )
    }

    func testFailedToolFiresOncePerToolId() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a")])

        let first = tracker.edge(for: [session(id: "a", completedErrorToolIDs: ["tool-1"])])
        XCTAssertEqual(first?.event, .taskError)

        XCTAssertNil(tracker.edge(for: [session(id: "a", completedErrorToolIDs: ["tool-1"])]))

        let second = tracker.edge(for: [session(id: "a", completedErrorToolIDs: ["tool-1", "tool-2"])])
        XCTAssertEqual(second?.event, .taskError)
    }

    func testCompactingFiresResourceLimit() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", phase: .idle)])

        let edge = tracker.edge(for: [session(id: "a", phase: .compacting)])
        XCTAssertEqual(edge?.event, .resourceLimit)
    }

    // MARK: - Severity

    func testOnlyTheMostSevereEdgeIsReported() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [
            session(id: "a", pid: 1),
            session(id: "b", pid: 2),
            session(id: "c", pid: 3)
        ])

        let edge = tracker.edge(for: [
            session(id: "a", pid: 1, completedErrorToolIDs: ["tool-1"]),
            session(id: "b", pid: 2, suppressInAppPromptControls: true),
            session(id: "c", pid: 3, phase: .processing)
        ])

        XCTAssertEqual(edge?.event, .taskError)
        XCTAssertEqual(edge?.sessions.map(\.sessionId), ["a"])
    }

    func testSuppressedLowerSeverityEdgeDoesNotFireLater() {
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session(id: "a", pid: 1), session(id: "b", pid: 2)])

        XCTAssertEqual(
            tracker.edge(for: [
                session(id: "a", pid: 1, completedErrorToolIDs: ["tool-1"]),
                session(id: "b", pid: 2, phase: .processing)
            ])?.event,
            .taskError
        )

        XCTAssertNil(
            tracker.edge(for: [
                session(id: "a", pid: 1, completedErrorToolIDs: ["tool-1"]),
                session(id: "b", pid: 2, phase: .processing)
            ]),
            "The processing transition was already consumed by the snapshot the error won"
        )
    }

    // MARK: - Retention bound

    func testRetainedRecordsAreBounded() {
        var tracker = SessionSoundEdgeTracker(retainedSessionLimit: 1)
        tracker.prime(with: [session(id: "a", pid: 1, phase: .processing)])

        for index in 0..<5 {
            _ = tracker.edge(for: [session(id: "filler-\(index)", pid: 100 + index, phase: .processing)])
        }

        XCTAssertEqual(
            tracker.edge(for: [session(id: "a", pid: 1, phase: .processing)])?.event,
            .sessionStarted,
            "Retention is bounded, so a long-absent session is eventually treated as new again"
        )
    }
}
