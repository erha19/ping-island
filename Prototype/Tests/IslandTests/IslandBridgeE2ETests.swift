import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func islandBridgeAllowsStateOnlyEventsWhenAppIsUnavailable() throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
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
func islandBridgeDoesNotWaitForStdinEOFWhenPayloadAlreadyArrived() async throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
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
          "thread_id": "codex-no-eof",
          "tool_name": "Read"
        }
        """,
        closeStdinOnLaunch: false
    )
    defer { process.closeStdin() }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while process.isRunning && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(process.isRunning == false)

    let result = process.waitForExit()

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test
func islandBridgeWaitsForSplitJSONPayloadBeforeContinuing() async throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: ["--source", "codex"],
        environment: [
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
            "PWD": "/tmp/codex-demo"
        ],
        closeStdinOnLaunch: false
    )
    defer { process.closeStdin() }

    process.writeToStdin("""
    {
      "event": "PostToolUse",
    """)
    try await Task.sleep(for: .milliseconds(40))
    #expect(process.isRunning)

    process.writeToStdin("""
      "thread_id": "codex-split",
      "tool_name": "Read"
    }
    """)

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while process.isRunning && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(process.isRunning == false)

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
        try await withRunningSocketServer(
            socketPath: socketPath,
            sessionStore: store,
            approvalCoordinator: coordinator
        ) { _ in
            let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
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
}

@Test
func remoteAgentFailsOpenWhenNoControlClientIsAttached() async throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let socketID = UUID().uuidString.prefix(8)
    let hookSocketPath = "/tmp/pi-\(socketID)-h.sock"
    let controlSocketPath = "/tmp/pi-\(socketID)-c.sock"

    let service = try RunningProcess(
        executableURL: executable,
        arguments: [
            "--mode", "remote-agent-service",
            "--hook-socket", hookSocketPath,
            "--control-socket", controlSocketPath
        ]
    )
    defer {
        service.terminate()
        _ = service.waitForExit()
        try? FileManager.default.removeItem(atPath: hookSocketPath)
        try? FileManager.default.removeItem(atPath: controlSocketPath)
    }

    try await waitUntil(description: "remote agent service should create sockets") {
        FileManager.default.fileExists(atPath: hookSocketPath)
            && FileManager.default.fileExists(atPath: controlSocketPath)
    }

    let response = try TestSocketClient.send(
        envelope: BridgeEnvelope(
            provider: .claude,
            eventType: "PermissionRequest",
            sessionKey: "claude:remote-skip",
            title: "Bash",
            preview: "Bash",
            cwd: "/tmp/remote-skip",
            status: SessionStatus(kind: .waitingForApproval),
            expectsResponse: true,
            metadata: [
                "session_id": "remote-skip",
                "tool_name": "Bash"
            ]
        ),
        socketPath: hookSocketPath
    )

    #expect(response.decision == nil)
    #expect(response.updatedInput == nil)
    #expect(response.reason == nil)
}

@Test
func remoteAgentMapsOpenClawPatchActivityToIdle() async throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let socketID = UUID().uuidString.prefix(8)
    let hookSocketPath = "/tmp/pi-\(socketID)-h.sock"
    let controlSocketPath = "/tmp/pi-\(socketID)-c.sock"

    let service = try RunningProcess(
        executableURL: executable,
        arguments: [
            "--mode", "remote-agent-service",
            "--hook-socket", hookSocketPath,
            "--control-socket", controlSocketPath
        ]
    )
    defer {
        service.terminate()
        _ = service.waitForExit()
        try? FileManager.default.removeItem(atPath: hookSocketPath)
        try? FileManager.default.removeItem(atPath: controlSocketPath)
    }

    try await waitUntil(description: "remote agent service should create sockets") {
        FileManager.default.fileExists(atPath: hookSocketPath)
            && FileManager.default.fileExists(atPath: controlSocketPath)
    }

    let attach = try RunningProcess(
        executableURL: executable,
        arguments: [
            "--mode", "remote-agent-attach",
            "--control-socket", controlSocketPath
        ],
        closeStdinOnLaunch: false
    )
    defer {
        attach.closeStdin()
        attach.terminate()
        _ = attach.waitForExit()
    }

    try await Task.sleep(for: .milliseconds(300))

    _ = try TestSocketClient.send(
        envelope: BridgeEnvelope(
            provider: .claude,
            eventType: "session:patch",
            sessionKey: "claude:openclaw-patch",
            title: "OpenClaw",
            preview: "OpenClaw session patch",
            cwd: "/home/openclaw",
            status: SessionStatus(kind: .active),
            expectsResponse: false,
            metadata: [
                "session_id": "openclaw-patch",
                "client_kind": "openclaw",
                "client_name": "OpenClaw",
                "client_originator": "OpenClaw",
                "thread_source": "openclaw-hooks"
            ]
        ),
        socketPath: hookSocketPath
    )

    try await Task.sleep(for: .milliseconds(300))
    service.terminate()
    _ = service.waitForExit()
    attach.closeStdin()
    let result = attach.waitForExit()

    #expect(result.stdout.contains("\"type\":\"hook_event\""))
    #expect(result.stdout.contains("\"event\":\"session:patch\""))
    #expect(result.stdout.contains("\"status\":\"idle\""))
}
