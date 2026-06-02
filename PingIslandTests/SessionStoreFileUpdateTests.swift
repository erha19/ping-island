import Combine
import XCTest
@testable import Ping_Island

final class SessionStoreFileUpdateTests: XCTestCase {
    func testNoOpEventDoesNotRepublishUnchangedSessions() async throws {
        let store = SessionStore.shared
        let sessionId = "publish-dedupe-\(UUID().uuidString)"
        for session in await store.allSessions() {
            await store.process(.sessionArchived(sessionId: session.sessionId))
        }

        var cancellables = Set<AnyCancellable>()
        var initialEmissionCount = 0
        var noOpEmissionCount = 0
        var isObservingNoOpEvent = false
        let firstEmission = expectation(description: "Initial session publication")
        let unexpectedDuplicate = expectation(description: "Unexpected duplicate session publication")
        unexpectedDuplicate.isInverted = true

        store.sessionsPublisher
            .sink { sessions in
                guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
                if isObservingNoOpEvent {
                    noOpEmissionCount += 1
                    unexpectedDuplicate.fulfill()
                    return
                }

                initialEmissionCount += 1
                if initialEmissionCount == 1 {
                    firstEmission.fulfill()
                }
            }
            .store(in: &cancellables)

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "Start work"
            )
        ))

        await fulfillment(of: [firstEmission], timeout: 1)
        try await Task.sleep(nanoseconds: 350_000_000)
        isObservingNoOpEvent = true

        await store.process(.agentFileUpdated(
            sessionId: sessionId,
            taskToolId: "unused-task",
            tools: []
        ))

        await fulfillment(of: [unexpectedDuplicate], timeout: 0.2)
        XCTAssertEqual(noOpEmissionCount, 0)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testHookWorkspaceRefreshUpdatesDisplayedProjectName() async throws {
        let store = SessionStore.shared
        let sessionId = "cursor-workspace-refresh-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/.cursor",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .custom, name: "Cursor"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Waiting"
            )
        ))

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .custom, name: "Cursor"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "Continue"
            )
        ))

        let updatedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(updatedSession)
        XCTAssertEqual(session.cwd, "/tmp/project")
        XCTAssertEqual(session.projectName, "project")
        XCTAssertEqual(session.displayTitle, "project")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testFileUpdatePromotesIdleSessionToProcessingAndRefreshesActivityTime() async throws {
        let store = SessionStore.shared
        let sessionId = "file-update-idle-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Waiting"
            )
        ))

        let previousSession = await store.session(for: sessionId)
        let previousLastActivity = try XCTUnwrap(previousSession?.lastActivity)

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-update",
                        role: .assistant,
                        timestamp: Date(),
                        content: [.text("Continuing work")],
                        usage: nil
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let updatedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(updatedSession)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertGreaterThan(session.lastActivity, previousLastActivity)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testEndedSessionResumesProcessingAfterFreshHookActivity() async throws {
        let store = SessionStore.shared
        let sessionId = "ended-hook-resume-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Waiting"
            )
        ))
        await store.process(.sessionEnded(sessionId: sessionId))

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "Follow-up question"
            )
        ))

        let resumedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(resumedSession)
        XCTAssertEqual(session.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testIncrementalUserTranscriptResumesEndedSession() async throws {
        let store = SessionStore.shared
        let sessionId = "ended-transcript-resume-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Done"
            )
        ))
        await store.process(.sessionEnded(sessionId: sessionId))

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "user-followup",
                        role: .user,
                        timestamp: Date(),
                        content: [.text("One more thing")],
                        usage: nil
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let resumedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(resumedSession)
        XCTAssertEqual(session.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRepeatedSessionEndDoesNotRefreshEndedSessionActivity() async throws {
        let store = SessionStore.shared
        let sessionId = "duplicate-ended-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Done"
            )
        ))
        await store.process(.sessionEnded(sessionId: sessionId))
        let endedSession = await store.session(for: sessionId)
        let endedAt = try XCTUnwrap(endedSession?.lastActivity)

        try await Task.sleep(nanoseconds: 20_000_000)
        await store.process(.sessionEnded(sessionId: sessionId))

        let repeatedEndSessionSnapshot = await store.session(for: sessionId)
        let repeatedEndSession = try XCTUnwrap(repeatedEndSessionSnapshot)
        XCTAssertEqual(repeatedEndSession.phase, .ended)
        XCTAssertEqual(repeatedEndSession.lastActivity, endedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testAssistantOnlyTranscriptUpdateDoesNotRefreshEndedSessionActivity() async throws {
        let store = SessionStore.shared
        let sessionId = "ended-assistant-sync-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "idle",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Done"
            )
        ))
        await store.process(.sessionEnded(sessionId: sessionId))
        let endedSession = await store.session(for: sessionId)
        let endedAt = try XCTUnwrap(endedSession?.lastActivity)

        try await Task.sleep(nanoseconds: 20_000_000)
        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-final",
                        role: .assistant,
                        timestamp: Date(),
                        content: [.text("Final answer")],
                        usage: nil
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let updatedSessionSnapshot = await store.session(for: sessionId)
        let updatedSession = try XCTUnwrap(updatedSessionSnapshot)
        XCTAssertEqual(updatedSession.phase, .ended)
        XCTAssertEqual(updatedSession.lastActivity, endedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testIdlePromptTransitionsProcessingToIdleWhenNoLiveEvidence() async throws {
        let store = SessionStore.shared
        let sessionId = "recent-processing-idle-transition-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "Please keep going"
            )
        ))

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "waiting_for_input",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Idle heartbeat"
            )
        ))

        // When no tools are running and no thinking is in progress, an idle
        // notification should transition the session from processing to idle
        // immediately -- no grace window needed.
        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testIdlePromptDoesNotDowngradeRunningToolSession() async throws {
        let store = SessionStore.shared
        let sessionId = "running-tool-grace-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "PreToolUse",
                status: "running_tool",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "Bash",
                toolInput: ["command": AnyCodable("sleep 120")],
                toolUseId: "tool-\(sessionId)",
                notificationType: nil,
                message: "Running Bash"
            )
        ))

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "waiting_for_input",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Idle heartbeat"
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    @MainActor
    func testFileUpdateRefreshesSessionMonitorForProcessingSession() async throws {
        let store = SessionStore.shared
        let monitor = SessionMonitor()
        let sessionId = "file-update-publish-\(UUID().uuidString)"

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "Start work"
            )
        ))

        try await waitForSession(in: monitor, sessionId: sessionId) { session in
            session.phase == .processing
        }

        let previousLastActivity = try XCTUnwrap(
            monitor.instances.first(where: { $0.sessionId == sessionId })?.lastActivity
        )

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-followup",
                        role: .assistant,
                        timestamp: Date(),
                        content: [.text("Fresh transcript output")],
                        usage: nil
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let refreshed = try await waitForSession(in: monitor, sessionId: sessionId) { session in
            session.phase == .processing
                && session.lastActivity != previousLastActivity
                && !session.chatItems.isEmpty
        }

        XCTAssertNotEqual(refreshed.lastActivity, previousLastActivity)
        XCTAssertFalse(refreshed.chatItems.isEmpty)
        await store.process(.sessionArchived(sessionId: sessionId))
    }

    @MainActor
    private func waitForSession(
        in monitor: SessionMonitor,
        sessionId: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping (SessionState) -> Bool
    ) async throws -> SessionState {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if let session = monitor.instances.first(where: { $0.sessionId == sessionId }),
               condition(session) {
                return session
            }

            try await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }

        XCTFail("Timed out waiting for session \(sessionId)")
        return try XCTUnwrap(monitor.instances.first(where: { $0.sessionId == sessionId }))
    }
}
