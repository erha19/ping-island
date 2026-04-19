import XCTest
@testable import Ping_Island

@MainActor
final class SessionMonitorNativeRuntimeTests: XCTestCase {
    private actor StubRuntimeCoordinator: RuntimeCoordinating {
        var managedSessionIDs: Set<String> = []
        var approvedSessionIDs: [(String, Bool)] = []
        var deniedSessionIDs: [String] = []
        var answeredSessionIDs: [(String, [String: [String]])] = []
        var sentInputs: [(SessionProvider, String, String)] = []
        var continuedSessions: [(SessionProvider, String, String?, String)] = []

        func markManaged(_ sessionID: String) {
            managedSessionIDs.insert(sessionID)
        }

        func approvals() -> [(String, Bool)] {
            approvedSessionIDs
        }

        func denials() -> [String] {
            deniedSessionIDs
        }

        func answers() -> [(String, [String: [String]])] {
            answeredSessionIDs
        }

        func userInputs() -> [(SessionProvider, String, String)] {
            sentInputs
        }

        func continuations() -> [(SessionProvider, String, String?, String)] {
            continuedSessions
        }

        func start() async {}
        func stop() async {}

        func startSession(
            provider: SessionProvider,
            cwd: String,
            preferredSessionID: String?,
            metadata: [String: String]
        ) async throws -> SessionRuntimeHandle {
            let sessionID = preferredSessionID ?? UUID().uuidString
            managedSessionIDs.insert(sessionID)
            return SessionRuntimeHandle(
                sessionID: sessionID,
                provider: provider,
                cwd: cwd,
                createdAt: Date(),
                resumeToken: nil,
                runtimeIdentifier: "stub",
                sessionFilePath: nil
            )
        }

        func terminateSession(provider: SessionProvider, sessionID: String) async throws {}

        func sendUserInput(provider: SessionProvider, sessionID: String, text: String) async throws {
            sentInputs.append((provider, sessionID, text))
        }

        func approveSession(provider: SessionProvider, sessionID: String, forSession: Bool) async throws {
            approvedSessionIDs.append((sessionID, forSession))
        }

        func denySession(provider: SessionProvider, sessionID: String, reason: String?) async throws {
            deniedSessionIDs.append(sessionID)
        }

        func answerSession(provider: SessionProvider, sessionID: String, answers: [String : [String]]) async throws {
            answeredSessionIDs.append((sessionID, answers))
        }

        func continueSession(provider: SessionProvider, sessionID: String, expectedTurnId: String?, text: String) async throws {
            continuedSessions.append((provider, sessionID, expectedTurnId, text))
        }

        func managesNativeSession(sessionID: String, provider: SessionProvider?) async -> Bool {
            managedSessionIDs.contains(sessionID)
        }

        func launchPreferredSession(provider: SessionProvider, cwd: String) async throws -> SessionRuntimeHandle {
            try await startSession(
                provider: provider,
                cwd: cwd,
                preferredSessionID: nil,
                metadata: [:]
            )
        }
    }

    func testHandleIncomingHookEventRoutesManagedSessionToNativeIngress() async {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-hook-\(UUID().uuidString)"
        await runtimeCoordinator.markManaged(sessionID)

        let event = HookEvent(
            sessionId: sessionID,
            cwd: "/tmp/native-hook",
            event: "SessionStart",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Starting"
        )

        await monitor.handleIncomingHookEvent(event)

        let session = await SessionStore.shared.session(for: sessionID)
        XCTAssertEqual(session?.ingress, .nativeRuntime)
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testApprovePermissionUsesNativeRuntimeCoordinatorForNativeSession() async {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-approval-\(UUID().uuidString)"

        await SessionStore.shared.process(.runtimeSessionStarted(
            SessionRuntimeHandle(
                sessionID: sessionID,
                provider: .claude,
                cwd: "/tmp/native-approval",
                createdAt: Date(),
                resumeToken: nil,
                runtimeIdentifier: "stub",
                sessionFilePath: nil
            )
        ))
        await runtimeCoordinator.markManaged(sessionID)
        await SessionStore.shared.process(.hookReceived(
            HookEvent(
                sessionId: sessionID,
                cwd: "/tmp/native-approval",
                event: "PermissionRequest",
                status: "waiting_for_approval",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "Bash",
                toolInput: ["command": AnyCodable("pwd")],
                toolUseId: "tool-native-approve",
                notificationType: nil,
                message: nil,
                ingress: .nativeRuntime
            )
        ))

        monitor.approvePermission(sessionId: sessionID, forSession: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let approved = await runtimeCoordinator.approvals()
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.0, sessionID)
        XCTAssertEqual(approved.first?.1, true)

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testHandleIncomingHookEventRoutesQuestionInterventionToNativeSession() async {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-question-\(UUID().uuidString)"
        await runtimeCoordinator.markManaged(sessionID)

        await monitor.handleIncomingHookEvent(
            HookEvent(
                sessionId: sessionID,
                cwd: "/tmp/native-question",
                event: "PreToolUse",
                status: "waiting_for_input",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "AskUserQuestion",
                toolInput: [
                    "questions": AnyCodable([
                        [
                            "id": "color",
                            "header": "颜色",
                            "question": "请选择喜欢的颜色",
                            "options": [["label": "蓝色"], ["label": "绿色"]]
                        ]
                    ])
                ],
                toolUseId: "tool-native-question",
                notificationType: nil,
                message: nil
            )
        )

        let session = await SessionStore.shared.session(for: sessionID)
        XCTAssertEqual(session?.ingress, .nativeRuntime)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.questions.first?.prompt, "请选择喜欢的颜色")

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testDenyAndAnswerUseNativeRuntimeCoordinatorForNativeSession() async {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-deny-answer-\(UUID().uuidString)"

        await SessionStore.shared.process(.runtimeSessionStarted(
            SessionRuntimeHandle(
                sessionID: sessionID,
                provider: .claude,
                cwd: "/tmp/native-deny-answer",
                createdAt: Date(),
                resumeToken: nil,
                runtimeIdentifier: "stub",
                sessionFilePath: nil
            )
        ))
        await runtimeCoordinator.markManaged(sessionID)

        await monitor.handleIncomingHookEvent(
            HookEvent(
                sessionId: sessionID,
                cwd: "/tmp/native-deny-answer",
                event: "PreToolUse",
                status: "waiting_for_input",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "AskUserQuestion",
                toolInput: [
                    "questions": AnyCodable([
                        [
                            "id": "mode",
                            "header": "模式",
                            "question": "请选择模式",
                            "options": [["label": "自动"], ["label": "手动"]]
                        ]
                    ])
                ],
                toolUseId: "tool-native-ask",
                notificationType: nil,
                message: nil
            )
        )

        monitor.answerIntervention(sessionId: sessionID, answers: ["mode": ["自动"]])
        try? await Task.sleep(nanoseconds: 100_000_000)
        let answers = await runtimeCoordinator.answers()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, sessionID)
        XCTAssertEqual(answers.first?.1["mode"], ["自动"])

        await SessionStore.shared.process(.hookReceived(
            HookEvent(
                sessionId: sessionID,
                cwd: "/tmp/native-deny-answer",
                event: "PermissionRequest",
                status: "waiting_for_approval",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "Bash",
                toolInput: ["command": AnyCodable("ls")],
                toolUseId: "tool-native-deny",
                notificationType: nil,
                message: nil,
                ingress: .nativeRuntime
            )
        ))

        monitor.denyPermission(sessionId: sessionID, reason: "nope")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let denials = await runtimeCoordinator.denials()
        XCTAssertEqual(denials, [sessionID])

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testSendSessionMessageUsesNativeRuntimeInputForClaudeSession() async throws {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-send-claude-\(UUID().uuidString)"

        await SessionStore.shared.process(.runtimeSessionStarted(
            SessionRuntimeHandle(
                sessionID: sessionID,
                provider: .claude,
                cwd: "/tmp/native-send-claude",
                createdAt: Date(),
                resumeToken: nil,
                runtimeIdentifier: "stub",
                sessionFilePath: nil
            )
        ))
        await runtimeCoordinator.markManaged(sessionID)

        try await monitor.sendSessionMessage(sessionId: sessionID, text: "追问一下")

        let inputs = await runtimeCoordinator.userInputs()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.0, .claude)
        XCTAssertEqual(inputs.first?.1, sessionID)
        XCTAssertEqual(inputs.first?.2, "追问一下")

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testSendSessionMessageUsesContinuationForNativeCodexSession() async throws {
        let runtimeCoordinator = StubRuntimeCoordinator()
        let monitor = SessionMonitor(runtimeCoordinator: runtimeCoordinator)
        let sessionID = "native-send-codex-\(UUID().uuidString)"

        await SessionStore.shared.process(.runtimeSessionStarted(
            SessionRuntimeHandle(
                sessionID: sessionID,
                provider: .codex,
                cwd: "/tmp/native-send-codex",
                createdAt: Date(),
                resumeToken: nil,
                runtimeIdentifier: "stub",
                sessionFilePath: nil
            )
        ))
        await runtimeCoordinator.markManaged(sessionID)

        try await monitor.sendSessionMessage(
            sessionId: sessionID,
            text: "继续这个思路",
            expectedTurnId: "turn-123"
        )

        let continuations = await runtimeCoordinator.continuations()
        XCTAssertEqual(continuations.count, 1)
        XCTAssertEqual(continuations.first?.0, .codex)
        XCTAssertEqual(continuations.first?.1, sessionID)
        XCTAssertEqual(continuations.first?.2, "turn-123")
        XCTAssertEqual(continuations.first?.3, "继续这个思路")

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }
}
