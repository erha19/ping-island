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
        try await withRunningSocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        ) { _ in
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
}

/// Relaunch overlap: a newer instance claims the shared socket path by unlinking whatever
/// is already there, and the previous instance then exits. Its `stop()` used to unlink that
/// path unconditionally, which left the live instance listening on an unlinked socket, so
/// every later bridge delivery failed with `connection_failed` until the app was relaunched.
@Test
func supersededSocketServerStopKeepsTheLiveSocketPath() async throws {
    try await withTemporaryDirectory { directory in
        let socketPath = directory.appending(path: "island.sock").path()
        let store = SessionStore { _ in }
        let coordinator = ApprovalCoordinator()

        let superseded = SocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        )
        try await superseded.start()

        let live = SocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        )
        try await live.start()

        await superseded.stop()

        #expect(FileManager.default.fileExists(atPath: socketPath))

        let envelope = BridgeEnvelope(
            id: UUID(),
            provider: .claude,
            eventType: "PostToolUse",
            sessionKey: "claude:socket-ownership",
            title: "Socket Ownership",
            preview: "Superseded server stopped",
            cwd: "/tmp/socket-ownership",
            status: SessionStatus(kind: .active)
        )

        let response = try TestSocketClient.send(envelope: envelope, socketPath: socketPath)

        #expect(response.requestID == envelope.id)
        #expect(response.errorMessage == nil)

        await live.stop()

        #expect(!FileManager.default.fileExists(atPath: socketPath))
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
        try await withRunningSocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        ) { _ in
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
}
