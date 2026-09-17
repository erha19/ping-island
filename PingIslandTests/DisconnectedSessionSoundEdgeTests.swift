import XCTest
@testable import Ping_Island

@MainActor
final class DisconnectedSessionSoundEdgeTests: XCTestCase {
    func testDiscoveringDisconnectedSessionDoesNotPlayStartupOrAttention() {
        var session = SessionState(sessionId: "remote-session", cwd: "/tmp/sound-test", phase: .processing)
        session.connectionState = .disconnected
        session.suppressInAppPromptControls = true
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [])

        XCTAssertNil(tracker.edge(for: [session]))
        XCTAssertFalse(SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session))
    }

    func testDisconnectedSnapshotsDoNotPlayResourceErrorOrCompletionSounds() {
        var session = SessionState(sessionId: "remote-session", cwd: "/tmp/sound-test", phase: .processing)
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session])
        session.connectionState = .disconnected
        session.phase = .compacting
        session.completedErrorToolIDs = ["stale-failure"]
        XCTAssertNil(tracker.edge(for: [session]))

        session.phase = .waitingForInput
        session.chatItems = [
            ChatHistoryItem(id: "old-reply", type: .assistant("Done"), timestamp: Date())
        ]
        XCTAssertNil(tracker.edge(for: [session]))
    }

    func testReconnectCanResumeProcessingWithoutRepeatedListChurnSounds() {
        var session = SessionState(sessionId: "remote-session", cwd: "/tmp/sound-test", phase: .processing)
        session.connectionState = .disconnected
        var tracker = SessionSoundEdgeTracker()
        tracker.prime(with: [session])
        session.connectionState = .connected

        XCTAssertEqual(tracker.edge(for: [session])?.event, .processingStarted)
        XCTAssertNil(tracker.edge(for: []))
        XCTAssertNil(tracker.edge(for: [session]))
    }
}
