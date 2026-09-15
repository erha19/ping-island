import Darwin
import Foundation
import XCTest
@testable import Ping_Island

/// Tests for the periodic liveness sweep introduced by
/// `fix-claude-sound-triggers`. The sweep removes sessions whose tracked pid
/// is no longer alive (Ctrl-C, OOM, terminal closed) and garbage-collects
/// sessions already in `.ended` phase.
final class SessionStoreLivenessSweepTests: XCTestCase {

    func testTerminalOnlyQuestionSurvivesSiblingAndLivenessCleanup() async throws {
        let store = SessionStore.shared
        for pid in [nil, 999_999] as [Int?] {
            let id = "terminal-question-\(UUID().uuidString)"
            let siblingID = "terminal-question-sibling-\(UUID().uuidString)"
            await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: pid)))
            let captured = await store.session(for: id)
            let original = try XCTUnwrap(captured)
            var question = original
            question.phase = .waitingForInput
            question.suppressInAppPromptControls = true
            question.lastActivity = Date().addingTimeInterval(-120)
            _ = await store.commitTranscriptUpdate(question, basedOn: original)

            await store.process(.hookReceived(makeClaudeEvent(sessionId: siblingID, pid: nil)))
            await store.expireStaleHookSessions(now: Date().addingTimeInterval(3 * 60 * 60))
            await store.pruneOrphanedSessions()
            await store.sweepDeadOrEndedSessions()
            let retained = await store.session(for: id)
            XCTAssertEqual(retained?.phase, .waitingForInput)
            XCTAssertTrue(retained?.needsPromptNotification == true)
            await store.process(.sessionEnded(sessionId: id))
            await store.sweepDeadOrEndedSessions()
            let ended = await store.session(for: id)
            XCTAssertNil(ended)
            await store.process(.sessionArchived(sessionId: siblingID))
        }
    }

    func testSessionEndDuringTranscriptEnrichmentPreservesFinalContent() async throws {
        let id = "liveness-enrichment-end-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        await store.process(.permissionAutoApprovalChanged(sessionId: id, isEnabled: true))
        let captured = await store.session(for: id)
        let original = try XCTUnwrap(captured)
        XCTAssertTrue(original.autoApprovePermissions)
        var enriched = original
        enriched.chatItems.append(ChatHistoryItem(
            id: "enriched-final", type: .assistant("Final subagent result"), timestamp: Date()
        ))

        // A Task-result parser await allows SessionEnd to land between capture
        // and commit; reproduce that ordering without a timing-dependent sleep.
        await store.process(.sessionEnded(sessionId: id))
        let ended = await store.session(for: id)
        let committed = await store.commitTranscriptUpdate(enriched, basedOn: original)
        XCTAssertEqual(committed?.phase, .ended)
        XCTAssertEqual(committed?.autoApprovePermissions, false)
        XCTAssertEqual(committed?.lastActivity, ended?.lastActivity)
        XCTAssertTrue(committed?.chatItems.contains(where: { $0.id == "enriched-final" }) == true)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testPermissionToggleDuringTranscriptEnrichmentIsNotOverwritten() async throws {
        let id = "liveness-permissions-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        for isEnabled in [true, false] {
            let captured = await store.session(for: id)
            let original = try XCTUnwrap(captured)
            await store.process(.permissionAutoApprovalChanged(sessionId: id, isEnabled: isEnabled))
            let committed = await store.commitTranscriptUpdate(original, basedOn: original)
            XCTAssertEqual(committed?.autoApprovePermissions, isEnabled)
        }
        await store.process(.sessionArchived(sessionId: id))
    }

    func testStopDuringTranscriptEnrichmentPreservesCompletionLifecycle() async throws {
        let id = "liveness-enrichment-stop-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let captured = await store.session(for: id)
        let original = try XCTUnwrap(captured)
        var enriched = original
        enriched.chatItems.append(ChatHistoryItem(
            id: "late-final", type: .assistant("Done"), timestamp: Date()
        ))

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: id,
            pid: nil,
            event: "Stop",
            status: "waiting_for_input"
        )))
        let stoppedSession = await store.session(for: id)
        let stopped = try XCTUnwrap(stoppedSession)
        let committed = await store.commitTranscriptUpdate(enriched, basedOn: original)
        XCTAssertEqual(committed?.phase, .waitingForInput)
        XCTAssertEqual(committed?.completionSequence, stopped.completionSequence)
        XCTAssertTrue(committed?.chatItems.contains(where: { $0.id == "late-final" }) == true)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testArchiveDuringTranscriptEnrichmentDropsStaleUpdate() async throws {
        let id = "liveness-enrichment-archive-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let captured = await store.session(for: id)
        let original = try XCTUnwrap(captured)
        await store.process(.sessionArchived(sessionId: id))
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertNil(committed)
        let current = await store.session(for: id)
        XCTAssertNil(current)
    }

    func testSessionEndDuringTranscriptReadCannotBeOverwritten() async throws {
        let id = "liveness-read-end-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let payload = FileUpdatePayload(
            sessionId: id, cwd: "/tmp/project",
            messages: [ChatMessage(
                id: "final-reply", role: .assistant, timestamp: Date(), content: [.text("Finished")]
            )],
            isIncremental: true, completedToolIds: [], toolResults: [:], structuredResults: [:]
        )
        // Deterministically interleave SessionEnd at the parser await boundary.
        await store.processFileUpdate(payload, conversationInfoLoader: {
            await store.process(.sessionEnded(sessionId: id))
            return ConversationInfo(
                summary: nil, lastMessage: "Finished", lastMessageRole: "assistant",
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        })
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertTrue(session?.chatItems.contains(where: { $0.id == "final-reply-text-0" }) == true)
        await store.sweepDeadOrEndedSessions()
        let reaped = await store.session(for: id)
        XCTAssertNil(reaped)
    }

    func testArchiveDuringTranscriptReadCannotRecreateSession() async {
        let id = "liveness-read-archive-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        await store.processFileUpdate(FileUpdatePayload(
            sessionId: id, cwd: "/tmp/project", messages: [], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: [:]
        ), conversationInfoLoader: {
            await store.process(.sessionArchived(sessionId: id))
            return ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        })
        let archived = await store.session(for: id)
        XCTAssertNil(archived)
    }

    func testSweepRemovesSessionWithDeadPid() async throws {
        // Spawn /usr/bin/true and wait for it to exit so we have a real pid
        // that is guaranteed dead at the moment we register the session.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPid = Int(process.processIdentifier)
        XCTAssertGreaterThan(deadPid, 0)
        XCTAssertTrue(
            Darwin.kill(pid_t(deadPid), 0) != 0 && errno == ESRCH,
            "Test setup precondition: spawned pid must be dead before the sweep runs"
        )

        let sessionId = "liveness-dead-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: deadPid
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertNotNil(beforeSweep, "Session must exist before sweep")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, "Session with dead pid must be removed by the sweep")
    }

    func testSweepRemovesEndedSession() async {
        let sessionId = "liveness-ended-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Use a real SessionEnd hook to drive the session into `.ended` phase
        // (the only public way to invoke markSessionEnded).
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "SessionEnd",
            status: "ended"
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertEqual(beforeSweep?.phase, .ended,
                       "Test setup precondition: session must reach .ended phase")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, ".ended sessions must be garbage-collected by the sweep")
    }

    func testSweepLeavesSessionWithoutPidAlone() async {
        let sessionId = "liveness-nopid-\(UUID().uuidString)"
        let store = SessionStore.shared

        // pid: nil means we cannot assert the process is dead.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: nil
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Sessions without a tracked pid must NOT be removed on liveness grounds")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSweepLeavesLiveSessionAlone() async {
        let sessionId = "liveness-live-\(UUID().uuidString)"
        let store = SessionStore.shared

        // getpid() is the test runner itself — guaranteed alive, phase != .ended.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid())
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Live, non-ended sessions must be untouched by the sweep")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRemotePidIsNeverReapedOrInspectedAsALocalProcess() async {
        let store = SessionStore.shared
        let id = "remote-pid-\(UUID().uuidString)"
        let remotePID = Int(Int32.max)
        let client = SessionClientInfo(
            kind: .claudeCode, remoteHost: "agent.example.invalid", remoteEndpointID: UUID(),
            processName: "remote-agent"
        )
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: id, pid: remotePID, ingress: .remoteBridge, clientInfo: client
        )))
        let before = await store.session(for: id)
        XCTAssertEqual(before?.pid, remotePID, "Keep remote PID as metadata, never local liveness")
        XCTAssertEqual(before?.clientInfo.processName, "remote-agent")
        if let before {
            var stale = before
            stale.lastActivity = Date().addingTimeInterval(-120)
            _ = await store.commitTranscriptUpdate(stale, basedOn: before)
        }
        await store.sweepDeadOrEndedSessions()
        await store.pruneOrphanedSessions()
        let after = await store.session(for: id)
        XCTAssertEqual(after?.phase, .processing)
        XCTAssertEqual(after?.connectionState, .connected)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testRemoteDisconnectMatchesEndpointBeforeLegacyHostAndCanReconnect() async throws {
        let store = SessionStore.shared
        let endpointID = UUID()
        let otherEndpointID = UUID()
        let suffix = UUID().uuidString
        let ids = ["endpoint-\(suffix)", "other-\(suffix)", "legacy-\(suffix)", "local-\(suffix)"]
        for index in ids.indices {
            let client = SessionClientInfo(
                kind: .claudeCode, remoteHost: " Agent.Example.Invalid ",
                remoteEndpointID: index == 0 ? endpointID : (index == 1 ? otherEndpointID : nil)
            )
            await store.process(.hookReceived(makeClaudeEvent(
                sessionId: ids[index], pid: nil,
                ingress: index == 3 ? .hookBridge : .remoteBridge, clientInfo: client
            )))
        }
        let beforeSnapshot = await store.session(for: ids[0])
        let before = try XCTUnwrap(beforeSnapshot)
        await store.markRemoteSessionsDisconnected(endpointID: endpointID, legacyRemoteHost: "agent.example.invalid")
        let disconnected = await store.session(for: ids[0])
        let other = await store.session(for: ids[1])
        let legacy = await store.session(for: ids[2])
        let local = await store.session(for: ids[3])
        XCTAssertEqual(disconnected?.connectionState, .disconnected)
        XCTAssertEqual(disconnected?.phase, .processing)
        XCTAssertEqual(disconnected?.lastActivity, before.lastActivity)
        XCTAssertFalse(disconnected?.isExecutionActive ?? true)
        XCTAssertEqual(other?.connectionState, .connected, "A stable endpoint ID outranks a shared host label")
        XCTAssertEqual(legacy?.connectionState, .disconnected)
        XCTAssertEqual(local?.connectionState, .connected)

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: ids[0], pid: nil, ingress: .remoteBridge,
            clientInfo: SessionClientInfo(kind: .claudeCode, remoteHost: "agent.example.invalid", remoteEndpointID: endpointID)
        )))
        let reconnected = await store.session(for: ids[0])
        XCTAssertEqual(reconnected?.connectionState, .connected)
        XCTAssertTrue(reconnected?.isExecutionActive ?? false)
        for id in ids { await store.process(.sessionArchived(sessionId: id)) }
    }

    func testDisconnectedApprovalIsPreservedButNotActionable() async {
        let store = SessionStore.shared
        let id = "remote-approval-\(UUID().uuidString)"
        let endpointID = UUID()
        await store.process(.hookReceived(HookEvent(
            sessionId: id, cwd: "/srv/remote-project", event: "PermissionRequest", status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, remoteEndpointID: endpointID),
            pid: Int(Int32.max), tty: nil, tool: "Bash", toolInput: ["command": AnyCodable("true")],
            toolUseId: "remote-request", notificationType: nil, message: "Allow command?", ingress: .remoteBridge
        )))
        let before = await store.session(for: id)
        XCTAssertTrue(before?.needsManualAttention ?? false)
        await store.markRemoteSessionsDisconnected(endpointID: endpointID, legacyRemoteHost: nil)
        await store.sweepDeadOrEndedSessions()
        let disconnected = await store.session(for: id)
        XCTAssertEqual(disconnected?.phase, before?.phase)
        XCTAssertEqual(disconnected?.intervention, before?.intervention)
        XCTAssertFalse(disconnected?.needsManualAttention ?? true)
        XCTAssertFalse(disconnected?.canInteract ?? true)
        await store.process(.sessionArchived(sessionId: id))
    }

    // MARK: - Helpers

    private func makeClaudeEvent(
        sessionId: String,
        pid: Int?,
        event: String = "UserPromptSubmit",
        status: String = "processing",
        ingress: SessionIngress = .hookBridge,
        clientInfo: SessionClientInfo? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: clientInfo ?? SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: pid,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: ingress
        )
    }
}
