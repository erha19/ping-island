import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func socketServerPersistsStateOnlyEnvelopes() async throws {
    try await withTemporaryDirectory { directory in
        let recorder = await MainActor.run { SnapshotRecorder() }
        let store = SessionStore { snapshot in
            recorder.snapshot = snapshot
        }
        let coordinator = ApprovalCoordinator()
        let socketPath = directory.appending(path: "island.sock").path()
        let server = SocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        )

        try await server.start()
        defer { Task { await server.stop() } }

        let envelope = BridgeEnvelope(
            id: UUID(),
            provider: .claude,
            eventType: "PostToolUse",
            sessionKey: "claude:socket-state",
            title: "Socket State",
            preview: "Completed tool run",
            cwd: "/tmp/socket-state",
            status: SessionStatus(kind: .active)
        )

        let response = try TestSocketClient.send(envelope: envelope, socketPath: socketPath)

        #expect(response.requestID == envelope.id)
        #expect(response.decision == nil)
        #expect(response.errorMessage == nil)

        try await waitUntil(description: "state-only socket event should be stored") {
            await MainActor.run {
                recorder.sessions.contains(where: { $0.id == "claude:socket-state" && $0.preview == "Completed tool run" })
            }
        }
    }
}

@Test
func socketServerReturnsApprovalDecisionForInteractiveEnvelopes() async throws {
    try await withTemporaryDirectory { directory in
        let recorder = await MainActor.run { SnapshotRecorder() }
        let store = SessionStore { snapshot in
            recorder.snapshot = snapshot
        }
        let coordinator = ApprovalCoordinator()
        let socketPath = directory.appending(path: "island.sock").path()
        let server = SocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        )

        try await server.start()
        defer { Task { await server.stop() } }

        let intervention = InterventionRequest(
            id: UUID(),
            sessionID: "claude:socket-approval",
            kind: .approval,
            title: "Claude needs approval",
            message: "Run tests?"
        )
        let envelope = BridgeEnvelope(
            id: UUID(),
            provider: .claude,
            eventType: "PermissionRequest",
            sessionKey: "claude:socket-approval",
            title: "Approval",
            preview: "Run tests",
            cwd: "/tmp/socket-approval",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: intervention,
            expectsResponse: true
        )

        async let response = Task.detached {
            try TestSocketClient.send(envelope: envelope, socketPath: socketPath)
        }.value

        try await waitUntil(description: "interactive socket event should surface an intervention") {
            await MainActor.run {
                recorder.snapshot.highlightedIntervention?.id == intervention.id
            }
        }

        await coordinator.resolve(requestID: intervention.id, decision: .approve)
        let resolved = try await response

        #expect(resolved.requestID == envelope.id)
        #expect(resolved.decision == .approve)
        #expect(resolved.errorMessage == nil)
    }
}
