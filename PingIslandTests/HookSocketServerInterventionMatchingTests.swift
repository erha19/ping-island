import XCTest
@testable import NotchCode

final class HookSocketServerInterventionMatchingTests: XCTestCase {
    func testCodexPermissionRequestStillMatchesPreToolUseWhenDescriptionIsInjected() {
        let sessionId = "codex-match-\(UUID().uuidString)"
        let preToolUse = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("date")
            ],
            toolUseId: "call-date-1",
            notificationType: nil,
            message: nil
        )
        let permissionRequest = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("date"),
                "description": AnyCodable("Show the current time.")
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(HookSocketServer.eventsLikelyReferToSameIntervention(preToolUse, permissionRequest))
    }

    func testDifferentCodexCommandsDoNotMatchAsSameIntervention() {
        let sessionId = "codex-mismatch-\(UUID().uuidString)"
        let firstEvent = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("date")
            ],
            toolUseId: "call-date-1",
            notificationType: nil,
            message: nil
        )
        let secondEvent = HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("pwd"),
                "description": AnyCodable("Show the current directory.")
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertFalse(HookSocketServer.eventsLikelyReferToSameIntervention(firstEvent, secondEvent))
    }
}
