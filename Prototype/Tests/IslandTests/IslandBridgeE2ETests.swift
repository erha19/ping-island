import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func islandBridgeAllowsStateOnlyEventsWhenAppIsUnavailable() throws {
    let executable = try TestRuntime.executableURL(named: "IslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: ["--source", "codex"],
        environment: [
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
            "PWD": "/tmp/codex-demo"
        ],
        stdin: """
        {
          "event": "PostToolUse",
          "thread_id": "codex-e2e",
          "tool_name": "Read"
        }
        """
    )

    let result = process.waitForExit()

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test
func islandBridgeRoundTripsApprovalRequestsThroughSocketServer() async throws {
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

        let executable = try TestRuntime.executableURL(named: "IslandBridge")
        let process = try RunningProcess(
            executableURL: executable,
            arguments: ["--source", "claude"],
            environment: [
                "ISLAND_SOCKET_PATH": socketPath,
                "PWD": "/tmp/e2e-demo",
                "TERM_PROGRAM": "iTerm.app",
                "ITERM_SESSION_ID": "iterm-e2e-1"
            ],
            stdin: """
            {
              "hook_event_name": "PermissionRequest",
              "tool_name": "Bash",
              "reason": "Needs to run tests",
              "session_id": "e2e-approval"
            }
            """
        )

        try await waitUntil(description: "bridge process should deliver an approval session to the server") {
            await MainActor.run {
                recorder.sessions.contains(where: { session in
                    session.id == "claude:e2e-approval"
                        && session.status.kind == .waitingForApproval
                        && session.terminalContext.iTermSessionID == "iterm-e2e-1"
                })
            }
        }

        let intervention = try await MainActor.run {
            try #require(recorder.snapshot.highlightedIntervention)
        }
        await coordinator.resolve(requestID: intervention.id, decision: .approve)

        let result = process.waitForExit()

        #expect(result.terminationStatus == 0)
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.stdout.contains("\"hookSpecificOutput\""))
        #expect(result.stdout.contains("\"behavior\":\"allow\""))

        let session = try await MainActor.run {
            try #require(recorder.sessions.first(where: { $0.id == "claude:e2e-approval" }))
        }
        #expect(session.title == "Bash")
        #expect(session.preview == "Bash")
        #expect(session.cwd == "/tmp/e2e-demo")
    }
}
