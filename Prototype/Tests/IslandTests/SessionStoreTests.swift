import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func sessionStorePrioritizesAttentionSessions() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "PostToolUse",
            sessionKey: "claude:1",
            title: "Regular",
            preview: "working",
            status: SessionStatus(kind: .active)
        )
    )
    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "PermissionRequest",
            sessionKey: "claude:2",
            title: "Needs approval",
            preview: "approve",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: InterventionRequest(sessionID: "claude:2", kind: .approval, title: "Approval", message: "Approve?")
        )
    )

    let sessions = await MainActor.run { recorder.sessions }
    #expect(sessions.first?.id == "claude:2")
}

@Test
func sessionStoreAssignsDefaultTitleAndSelectionForNewCodexSessions() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .codex,
            eventType: "Start",
            sessionKey: "codex:new",
            preview: "Waiting for activity"
        )
    )

    let snapshot = await MainActor.run { recorder.snapshot }
    #expect(snapshot.selectedSessionID == "codex:new")
    #expect(snapshot.sessions.first?.title == "Codex Session")
    #expect(snapshot.sessions.first?.status.kind == .active)
}

@Test
func sessionStoreClearingInterventionResetsStatusButKeepsSessionVisible() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }
    let request = InterventionRequest(
        sessionID: "claude:approval",
        kind: .approval,
        title: "Approval",
        message: "Approve?"
    )

    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "PermissionRequest",
            sessionKey: "claude:approval",
            title: "Approval",
            preview: "Approve?",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: request,
            expectsResponse: true
        )
    )
    await store.clearIntervention(for: "claude:approval")

    let session = try await MainActor.run {
        try #require(recorder.sessions.first(where: { $0.id == "claude:approval" }))
    }
    #expect(session.intervention == nil)
    #expect(session.status.kind == .active)
}

@Test
func sessionStoreKeepsAttentionSnapshotsExpandedEvenAfterManualCollapse() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "PermissionRequest",
            sessionKey: "claude:attention",
            title: "Approval",
            preview: "Approve?",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: InterventionRequest(
                sessionID: "claude:attention",
                kind: .approval,
                title: "Approval",
                message: "Approve?"
            ),
            expectsResponse: true
        )
    )
    await store.setExpanded(false)

    let snapshot = await MainActor.run { recorder.snapshot }
    #expect(snapshot.isExpanded)
    #expect(snapshot.highlightedIntervention?.sessionID == "claude:attention")
}

@Test
func sessionStoreMergesMetadataAcrossUpdates() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "SessionStart",
            sessionKey: "claude:merge",
            title: "Session",
            preview: "Started",
            cwd: "/tmp/one",
            status: SessionStatus(kind: .thinking),
            metadata: ["client_kind": "cursor"],
            sentAt: .distantPast
        )
    )
    await store.ingest(
        BridgeEnvelope(
            provider: .claude,
            eventType: "PostToolUse",
            sessionKey: "claude:merge",
            preview: "Updated",
            cwd: "/tmp/two",
            status: SessionStatus(kind: .active),
            terminalContext: TerminalContext(terminalProgram: "iTerm.app"),
            metadata: ["client_name": "Cursor"]
        )
    )

    let session = try await MainActor.run {
        try #require(recorder.sessions.first(where: { $0.id == "claude:merge" }))
    }
    #expect(session.preview == "Updated")
    #expect(session.cwd == "/tmp/two")
    #expect(session.terminalContext.terminalProgram == "iTerm.app")
    #expect(session.metadata["client_kind"] == "cursor")
    #expect(session.metadata["client_name"] == "Cursor")
}

@Test
func sessionStoreCreatesAndUpdatesCodexStatusSessions() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingestCodexStatus(
        sessionID: "codex:status",
        title: nil,
        preview: nil,
        status: SessionStatus(kind: .thinking),
        metadata: ["thread_source": "app-server"]
    )
    await store.ingestCodexStatus(
        sessionID: "codex:status",
        title: "Codex Build",
        preview: "Finished",
        status: SessionStatus(kind: .completed),
        metadata: ["client_name": "Codex App"]
    )

    let session = try await MainActor.run {
        try #require(recorder.sessions.first(where: { $0.id == "codex:status" }))
    }
    #expect(session.provider == .codex)
    #expect(session.title == "Codex Build")
    #expect(session.preview == "Finished")
    #expect(session.status.kind == .completed)
    #expect(session.metadata["thread_source"] == "app-server")
    #expect(session.metadata["client_name"] == "Codex App")
}
