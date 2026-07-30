import XCTest
@testable import NotchCode

final class SessionMonitorCodexWatcherTests: XCTestCase {
    func testCodexHookBridgeProcessingEventsStartTranscriptWatcher() {
        let event = HookEvent(
            sessionId: "codex-cli-session",
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "thinking",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )

        XCTAssertTrue(SessionMonitor.shouldWatchTranscript(for: event, phase: .idle))
    }

    func testCodexStopEventsStopTranscriptWatcher() {
        let event = HookEvent(
            sessionId: "codex-cli-session",
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )

        XCTAssertTrue(SessionMonitor.shouldStopWatchingTranscript(for: event))
    }
}
