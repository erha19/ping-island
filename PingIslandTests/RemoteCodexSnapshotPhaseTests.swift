import Foundation
import XCTest
@testable import Ping_Island

final class RemoteCodexSnapshotPhaseTests: XCTestCase {
    func testSnapshotCreatesIdleSessionWhenFirstObserved() async {
        let sessionId = "codex-remote-snapshot-new-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeSnapshot(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSnapshotPreservesExistingLifecyclePhase() async {
        let store = SessionStore.shared
        let cases: [(name: String, phase: SessionPhase)] = [
            ("waiting", .waitingForInput),
            ("ended", .ended)
        ]

        for testCase in cases {
            let sessionId = "codex-remote-snapshot-\(testCase.name)-\(UUID().uuidString)"
            await store.upsertCodexSession(
                sessionId: sessionId,
                name: "Remote task",
                preview: "Existing lifecycle state",
                cwd: snapshotCwd(sessionId: sessionId),
                phase: testCase.phase,
                intervention: nil,
                clientInfo: .codexCLI()
            )
            await store.process(.hookReceived(makeSnapshot(sessionId: sessionId)))

            let session = await store.session(for: sessionId)
            XCTAssertEqual(session?.phase, testCase.phase, testCase.name)
            await store.process(.sessionArchived(sessionId: sessionId))
        }
    }

    private func makeSnapshot(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: snapshotCwd(sessionId: sessionId),
            event: "RemoteCodexThreadUpdated",
            status: "processing",
            provider: .codex,
            clientInfo: .codexCLI(),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Remote task snapshot",
            ingress: .remoteBridge
        )
    }

    private func snapshotCwd(sessionId: String) -> String {
        "/tmp/remote-project-\(sessionId)"
    }
}
