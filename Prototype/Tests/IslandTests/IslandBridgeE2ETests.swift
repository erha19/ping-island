import Darwin
import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func islandBridgeHealthCheckRoundTripsThroughSocketServer() async throws {
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
                arguments: ["--mode", "health-check"],
                environment: bridgeTestEnvironment(["ISLAND_SOCKET_PATH": socketPath])
            )

            let result = process.waitForExit()

            #expect(result.terminationStatus == 0)
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
            #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

@Test
func remoteAgentDefersCodexAutomaticReviewWithoutAllowingIt() async throws {
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
    let control = try RemoteApprovalControlClient(socketPath: controlSocketPath)
    try await control.readHello()
    let hookRequest = Task.detached {
        try TestSocketClient.send(
            envelope: BridgeEnvelope(
                provider: .codex,
                eventType: "PermissionRequest",
                sessionKey: "codex:remote-auto-review",
                title: "Bash",
                preview: "Run tests",
                cwd: "/tmp/remote-auto-review",
                status: SessionStatus(kind: .waitingForApproval),
                expectsResponse: true,
                metadata: [
                    "session_id": "remote-auto-review",
                    "tool_name": "Bash",
                    "permission_mode": "default",
                    "approvals_reviewer": "auto_review"
                ]
            ),
            socketPath: hookSocketPath
        )
    }

    let event = try await control.readHookEvent()
    #expect(event.payload.permissionMode == "default")
    #expect(event.payload.approvalsReviewer == "auto_review")
    try await control.sendDefer(requestID: event.payload.requestID)
    let response = try await hookRequest.value
    #expect(response.decision == nil)
}

@Test
func islandBridgeHealthCheckFailsWhenSocketIsUnavailable() throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: ["--mode", "health-check"],
        environment: bridgeTestEnvironment([
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock"
        ])
    )

    let result = process.waitForExit()

    #expect(result.terminationStatus != 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test
func islandBridgeAllowsStateOnlyEventsWhenAppIsUnavailable() async throws {
    try await withTemporaryDirectory { directory in
        let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
        let debugDirectory = directory.appending(path: "codex-hook-debug", directoryHint: .isDirectory)
        let process = try RunningProcess(
            executableURL: executable,
            arguments: ["--source", "codex"],
            environment: bridgeTestEnvironment([
                "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
                "PING_ISLAND_CODEX_HOOK_DEBUG_DIR": debugDirectory.path(),
                "PWD": "/tmp/codex-demo"
            ]),
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

        let logURL = try #require(
            try FileManager.default.contentsOfDirectory(
                at: debugDirectory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "jsonl" })
        )
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains(#""deliveryOutcome":"connection_failed""#))
        #expect(!log.contains(#""deliveryOutcome":"delivered""#))
    }
}

@Test
func islandBridgePreservesAntigravityPermissionFlowWhenAppIsUnavailable() throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: [
            "--source", "gemini",
            "--client-kind", "antigravity",
            "--event", "PreToolUse",
        ],
        environment: bridgeTestEnvironment([
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
        ]),
        stdin: """
        {
          "conversationId": "antigravity-e2e",
          "workspacePaths": ["/tmp/antigravity-demo"],
          "toolCall": {
            "name": "run_shell_command",
            "args": {
              "command": "swift test"
            }
          }
        }
        """
    )

    let result = process.waitForExit()

    #expect(result.terminationStatus == 0)
    #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let stdoutData = Data(result.stdout.utf8)
    let stdout = try #require(
        JSONSerialization.jsonObject(with: stdoutData) as? [String: String]
    )
    #expect(stdout == ["decision": "ask"])
}

@Test
func islandBridgeDoesNotWaitForStdinEOFWhenPayloadAlreadyArrived() async throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: ["--source", "codex"],
        environment: bridgeTestEnvironment([
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
            "PWD": "/tmp/codex-demo"
        ]),
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
        environment: bridgeTestEnvironment([
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock",
            "PWD": "/tmp/codex-demo"
        ]),
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
                environment: bridgeTestEnvironment([
                    "ISLAND_SOCKET_PATH": socketPath,
                    "PWD": "/tmp/e2e-demo",
                    "TERM_PROGRAM": "iTerm.app",
                    "ITERM_SESSION_ID": "iterm-e2e-1"
                ]),
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
func islandBridgeDeliversClaudeDesktopToolEventsThroughSocketServer() async throws {
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
                environment: bridgeTestEnvironment([
                    "ISLAND_SOCKET_PATH": socketPath,
                    "PWD": "/tmp/claude-desktop-demo",
                    "TERM_PROGRAM": "",
                    "__CFBundleIdentifier": "com.anthropic.claudefordesktop"
                ]),
                stdin: """
                {
                  "hook_event_name": "PreToolUse",
                  "session_id": "claude-desktop-e2e",
                  "tool_name": "Read",
                  "tool_input": {
                    "file_path": "/tmp/claude-desktop-demo/README.md"
                  }
                }
                """
            )

            let result = process.waitForExit()

            #expect(result.terminationStatus == 0)
            #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            try await waitUntil(description: "Claude Desktop tool event should reach the session store") {
                await MainActor.run {
                    recorder.sessions.contains(where: { session in
                        session.id == "claude:claude-desktop-e2e"
                            && session.status.kind == .runningTool
                            && session.terminalContext.terminalBundleID == "com.anthropic.claudefordesktop"
                    })
                }
            }
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

@Test(arguments: ["task_started", "task_complete"])
func remoteAgentForwardsCodexAppServerStateUpdates(latestLifecycleEvent: String) async throws {
    try await withTemporaryDirectory { directory in
        let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
        let codexHome = directory.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let rolloutURL = directory.appending(path: "rollout.jsonl")
        try """
        {"type":"event_msg","payload":{"type":"\(latestLifecycleEvent)"}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        try createCodexStateDatabase(
            at: codexHome.appending(path: "state_5.sqlite"),
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            rolloutPath: rolloutURL.path()
        )

        let socketID = UUID().uuidString.prefix(8)
        let hookSocketPath = "/tmp/pi-\(socketID)-h.sock"
        let controlSocketPath = "/tmp/pi-\(socketID)-c.sock"
        let service = try RunningProcess(
            executableURL: executable,
            arguments: [
                "--mode", "remote-agent-service",
                "--hook-socket", hookSocketPath,
                "--control-socket", controlSocketPath
            ],
            environment: ["HOME": directory.path()]
        )
        defer {
            service.terminate()
            _ = service.waitForExit()
            try? FileManager.default.removeItem(atPath: hookSocketPath)
            try? FileManager.default.removeItem(atPath: controlSocketPath)
            try? FileManager.default.removeItem(atPath: controlSocketPath + ".outbox")
        }

        try await waitUntil(description: "remote agent service should create control socket") {
            FileManager.default.fileExists(atPath: controlSocketPath)
        }

        let event = try await readRemoteHookEvent(
            controlSocketPath: controlSocketPath,
            matching: { $0.payload.sessionID == "remote-codex-thread" }
        )

        #expect(event.type == "hook_event")
        #expect(event.payload.provider == "codex")
        #expect(event.payload.cwd == "/work/project")
        #expect(event.payload.status == "idle")
        #expect(event.payload.message == "Remote Codex is editing files")
        #expect(event.payload.clientInfo.kind == "codexCLI")
        #expect(event.payload.clientInfo.transport == "ssh")
        #expect(event.payload.clientInfo.sessionFilePath == rolloutURL.path())
    }
}

@Test
func remoteAgentForwardsCodexUsageSnapshots() async throws {
    try await withTemporaryDirectory { directory in
        let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
        let rolloutURL = directory
            .appending(path: ".codex/sessions/2026/08/31", directoryHint: .isDirectory)
            .appending(path: "rollout-remote-codex-thread.jsonl")
        try FileManager.default.createDirectory(
            at: rolloutURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {"timestamp":"2026-08-31T12:34:56.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"output_tokens":345,"total_tokens":1545}},"rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":17,"window_minutes":300,"resets_at":1788183296},"secondary":{"used_percent":29,"window_minutes":10080,"resets_at":1788788096}}}}
        """.utf8).write(to: rolloutURL)

        let socketID = UUID().uuidString.prefix(8)
        let hookSocketPath = "/tmp/pi-\(socketID)-h.sock"
        let controlSocketPath = "/tmp/pi-\(socketID)-c.sock"
        let service = try RunningProcess(
            executableURL: executable,
            arguments: [
                "--mode", "remote-agent-service",
                "--hook-socket", hookSocketPath,
                "--control-socket", controlSocketPath
            ],
            environment: ["HOME": directory.path()]
        )
        defer {
            service.terminate()
            _ = service.waitForExit()
            try? FileManager.default.removeItem(atPath: hookSocketPath)
            try? FileManager.default.removeItem(atPath: controlSocketPath)
        }

        try await waitUntil(description: "remote agent service should create control socket") {
            FileManager.default.fileExists(atPath: controlSocketPath)
        }

        let message = try await readRemoteMessage(
            controlSocketPath: controlSocketPath,
            as: TestRemoteCodexUsageMessage.self,
            description: "remote Codex usage message",
            matching: { $0.type == "codex_usage" }
        )

        let resolvedSourcePath = URL(fileURLWithPath: message.payload.sourceFilePath)
            .resolvingSymlinksInPath()
            .path()
        #expect(resolvedSourcePath == rolloutURL.resolvingSymlinksInPath().path())
        #expect(message.payload.planType == "pro")
        #expect(message.payload.limitID == "codex")
        #expect(message.payload.tokenUsage?.totalTokens == 1_545)
        #expect(message.payload.windows.map(\.label) == ["5h", "7d"])
        #expect(message.payload.windows.map(\.usedPercentage) == [17, 29])
    }
}

@Test(arguments: [false, true])
func remoteAgentSurvivesDelayedResponseAfterHookSocketCloses(expectsResponse: Bool) async throws {
    try await withTemporaryDirectory { directory in
        let fixture = try RemoteServiceFixture(home: directory)
        defer { fixture.stop() }
        try await fixture.waitForSockets()
        let control = try RemoteTestControl(socketPath: fixture.controlSocketPath)
        try await control.readHello()
        let requestID = UUID()
        let envelope = BridgeEnvelope(
            id: requestID, provider: .claude, eventType: expectsResponse ? "PermissionRequest" : "Stop",
            sessionKey: "claude:closed-hook", cwd: "/work/project", expectsResponse: expectsResponse,
            metadata: ["session_id": "closed-hook", "tool_name": "Bash"]
        )
        try sendRemoteHookAndClose(envelope, socketPath: fixture.hookSocketPath)
        let event = try await control.readHookEvent()
        #expect(event.payload.requestID == requestID)
        try await control.send(requestID: requestID, decision: expectsResponse ? "defer" : nil)
        try await waitUntil(description: "delayed response should retire event") { [outboxURL = fixture.outboxURL] in
            (try? Data(contentsOf: outboxURL).isEmpty) == true
        }
        // Opening a second control connection proves Darwin EPIPE did not kill
        // the service after writing the delayed ACK/decision to the closed hook.
        let nextControl = try RemoteTestControl(socketPath: fixture.controlSocketPath)
        try await nextControl.readHello()
    }
}

private func sendRemoteHookAndClose(_ envelope: BridgeEnvelope, socketPath: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath.utf8CString.map(UInt8.init(bitPattern:))
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    let data = try BridgeCodec.encodeEnvelope(envelope)
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress?.advanced(by: offset), data.count - offset) }
        if count > 0 { offset += count }
        else if count < 0, errno == EINTR { continue }
        else { throw POSIXError(.EIO) }
    }
    shutdown(fd, SHUT_WR)
}

@Test
func remoteAgentReplaysUnacknowledgedEventAfterReconnectAndServiceRestart() async throws {
    try await withTemporaryDirectory { directory in
        let fixture = try RemoteServiceFixture(home: directory)
        defer { fixture.stop() }
        try await fixture.waitForSockets()
        let requestID = UUID()
        _ = try TestSocketClient.send(envelope: BridgeEnvelope(
            id: requestID, provider: .claude, eventType: "Stop", sessionKey: "claude:remote-replay",
            preview: "finished remotely", cwd: "/work/project", status: SessionStatus(kind: .completed),
            expectsResponse: false, metadata: ["session_id": "remote-replay"]
        ), socketPath: fixture.hookSocketPath)
        #expect(try Data(contentsOf: fixture.outboxURL).isEmpty == false)
        for _ in 0..<2 {
            let control = try RemoteTestControl(socketPath: fixture.controlSocketPath)
            try await control.readHello()
            let event = try await control.readHookEvent()
            #expect(event.payload.requestID == requestID)
            control.closeConnection() // No ACK: the same event must replay.
        }
        try fixture.restart()
        try await fixture.waitForSockets()
        let control = try RemoteTestControl(socketPath: fixture.controlSocketPath)
        try await control.readHello()
        let replay = try await control.readHookEvent()
        #expect(replay.payload.requestID == requestID)
        #expect(replay.payload.sessionID == "remote-replay")
        try await control.send(requestID: requestID)
        try await waitUntil(description: "processed ACK should clear durable replay") { [outboxURL = fixture.outboxURL] in
            (try? Data(contentsOf: outboxURL).isEmpty) == true
        }
    }
}

@Test
func remoteAgentDeliversLargeFramesAndAcknowledgesOnlyProcessedEvents() async throws {
    try await withTemporaryDirectory { directory in
        let fixture = try RemoteServiceFixture(home: directory)
        defer { fixture.stop() }
        try await fixture.waitForSockets()
        let control = try RemoteTestControl(socketPath: fixture.controlSocketPath)
        try await control.readHello()
        let requestID = UUID()
        let text = String(repeating: "remote result ", count: 40_000)
        let hookSocketPath = fixture.hookSocketPath
        let request = Task.detached {
            try TestSocketClient.send(envelope: BridgeEnvelope(
                id: requestID, provider: .claude, eventType: "Stop", sessionKey: "claude:large-frame",
                preview: text, cwd: "/work/project", status: SessionStatus(kind: .completed),
                expectsResponse: false, metadata: ["session_id": "large-frame"]
            ), socketPath: hookSocketPath)
        }
        let event = try await control.readHookEvent()
        #expect(event.payload.message == text)
        #expect(try Data(contentsOf: fixture.outboxURL).isEmpty == false)
        // Receipt alone is insufficient; an app processed-event ACK retires it.
        try await control.send(requestID: requestID)
        let response = try await request.value
        #expect(response.requestID == requestID)
        #expect(response.decision == nil)
        try await waitUntil(description: "large frame should be retired after ACK") { [outboxURL = fixture.outboxURL] in
            (try? Data(contentsOf: outboxURL).isEmpty) == true
        }
    }
}

@Test
func remoteAgentOutboxRecoveryBoundsRecordsBytesAndDropsStaleApprovals() async throws {
    try await withTemporaryDirectory { directory in
        func record(message: String, expectsResponse: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "hook_event", "payload": [
                    "requestID": UUID().uuidString, "sessionID": "bounded-replay", "cwd": "/work/project",
                    "event": "Stop", "status": "idle", "provider": "claude", "message": message,
                    "expectsResponse": expectsResponse, "clientInfo": ["kind": "claudeCode"]
                ]
            ]) + Data("\n".utf8)
        }
        var manyRecords = Data()
        for index in 0..<4_100 { manyRecords.append(try record(message: "event-\(index)")) }
        manyRecords.append(try record(message: "orphaned approval", expectsResponse: true))
        let countFixture = try RemoteServiceFixture(home: directory, seedOutbox: manyRecords)
        defer { countFixture.stop() }
        try await countFixture.waitForSockets()
        let recovered = try Data(contentsOf: countFixture.outboxURL)
        #expect(recovered.split(separator: 0x0A).count == 4_096)
        #expect(String(decoding: recovered, as: UTF8.self).contains("orphaned approval") == false)
        let attributes = try FileManager.default.attributesOfItem(atPath: countFixture.outboxURL.path())
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        var largeRecords = Data()
        for _ in 0..<18 { largeRecords.append(try record(message: String(repeating: "x", count: 1_024 * 1_024))) }
        let byteFixture = try RemoteServiceFixture(home: directory, seedOutbox: largeRecords)
        defer { byteFixture.stop() }
        try await byteFixture.waitForSockets()
        let bounded = try Data(contentsOf: byteFixture.outboxURL)
        #expect(bounded.count <= 16 * 1_024 * 1_024)
        #expect(bounded.isEmpty == false)
    }
}

private final class RemoteServiceFixture {
    let hookSocketPath: String
    let controlSocketPath: String
    let outboxURL: URL
    private let executable: URL
    private let environment: [String: String]
    private let arguments: [String]
    private var service: RunningProcess

    init(home: URL, seedOutbox: Data? = nil) throws {
        let id = UUID().uuidString.prefix(8)
        hookSocketPath = "/tmp/pi-\(id)-h.sock"
        controlSocketPath = "/tmp/pi-\(id)-c.sock"
        outboxURL = URL(fileURLWithPath: controlSocketPath + ".outbox")
        executable = try TestRuntime.executableURL(named: "PingIslandBridge")
        environment = bridgeTestEnvironment(["HOME": home.path()])
        arguments = ["--mode", "remote-agent-service", "--hook-socket", hookSocketPath, "--control-socket", controlSocketPath]
        if let seedOutbox { try seedOutbox.write(to: outboxURL) }
        service = try RunningProcess(executableURL: executable, arguments: arguments, environment: environment)
    }

    func waitForSockets() async throws {
        try await waitUntil(timeout: .seconds(5), description: "remote replay fixture should create sockets") {
            [hookSocketPath, controlSocketPath] in
            FileManager.default.fileExists(atPath: hookSocketPath)
                && FileManager.default.fileExists(atPath: controlSocketPath)
        }
    }

    func restart() throws {
        service.terminate()
        _ = service.waitForExit()
        try? FileManager.default.removeItem(atPath: hookSocketPath)
        try? FileManager.default.removeItem(atPath: controlSocketPath)
        service = try RunningProcess(executableURL: executable, arguments: arguments, environment: environment)
    }

    func stop() {
        service.terminate()
        _ = service.waitForExit()
        try? FileManager.default.removeItem(atPath: hookSocketPath)
        try? FileManager.default.removeItem(atPath: controlSocketPath)
        try? FileManager.default.removeItem(at: outboxURL)
    }
}

private final class RemoteTestControl {
    private var fd: Int32
    private var buffer = Data()

    init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd); throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    deinit { closeConnection() }
    func closeConnection() { if fd >= 0 { close(fd); fd = -1 } }

    private struct Hello: Decodable { let type: String; let hostname: String }
    func readHello() async throws { _ = try await next(Hello.self) }
    func readHookEvent() async throws -> TestRemoteHookEventMessage { try await next(TestRemoteHookEventMessage.self) }

    private func next<T: Decodable>(_ type: T.Type) async throws -> T {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let deadline = ContinuousClock().now + .seconds(8)
        while ContinuousClock().now < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let value = try? JSONDecoder().decode(type, from: line) { return value }
            }
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(bytes, count: count) }
            else if count == 0 { throw POSIXError(.ECONNRESET) }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw POSIXError(.EIO) }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }
        throw TestSupportError.timedOut("remote control message")
    }

    func send(requestID: UUID, decision: String? = nil) async throws {
        var object: [String: Any] = ["type": decision == nil ? "ack" : "decision", "requestID": requestID.uuidString]
        if let decision { object["decision"] = decision }
        let data = try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress?.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                try await Task.sleep(for: .milliseconds(5))
            } else { throw POSIXError(.EIO) }
        }
    }
}

private func bridgeTestEnvironment(_ values: [String: String] = [:]) -> [String: String] {
    var environment = values
    environment[BridgeRuntimeConfig.configPathEnvironmentKey] =
        "/tmp/ping-island-test-bridge-config-\(UUID().uuidString).json"
    return environment
}

private func createCodexStateDatabase(
    at url: URL,
    updatedAtMs: Int64,
    rolloutPath: String
) throws {
    try runSQLite(
        databaseURL: url,
        sql: """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT,
          created_at INTEGER,
          updated_at INTEGER,
          source TEXT,
          model_provider TEXT,
          cwd TEXT,
          title TEXT,
          archived INTEGER,
          created_at_ms INTEGER,
          updated_at_ms INTEGER,
          thread_source TEXT,
          preview TEXT
        );
        INSERT INTO threads VALUES (
          'remote-codex-thread',
          '\(rolloutPath)',
          1,
          1,
          'vscode',
          'codex',
          '/work/project',
          'Remote Codex',
          0,
          \(updatedAtMs),
          \(updatedAtMs),
          'vscode',
          'Remote Codex is editing files'
        );
        """
    )
}

private func readRemoteHookEvent(
    controlSocketPath: String,
    matching predicate: @escaping (TestRemoteHookEventMessage) -> Bool
) async throws -> TestRemoteHookEventMessage {
    try await readRemoteMessage(
        controlSocketPath: controlSocketPath,
        as: TestRemoteHookEventMessage.self,
        description: "remote Codex hook event",
        matching: predicate
    )
}

private func readRemoteMessage<Message: Decodable>(
    controlSocketPath: String,
    as type: Message.Type,
    description: String,
    matching predicate: @escaping (Message) -> Bool
) async throws -> Message {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let utf8 = controlSocketPath.utf8CString.map(UInt8.init(bitPattern:))
    guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: utf8)
    }
    let connectResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { throw POSIXError(.ECONNREFUSED) }

    let decoder = JSONDecoder()
    var buffer = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    let deadline = ContinuousClock().now + .seconds(4)
    while ContinuousClock().now < deadline {
        let count = read(fd, &bytes, bytes.count)
        if count > 0 {
            buffer.append(bytes, count: count)
            while let newline = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: 0..<newline.lowerBound)
                buffer.removeSubrange(0...newline.lowerBound)
                if let message = try? decoder.decode(type, from: line),
                   predicate(message) {
                    return message
                }
            }
        } else {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    throw TestSupportError.timedOut(description)
}

private struct TestRemoteHookEventMessage: Decodable {
    let type: String
    let payload: TestRemoteHookEventPayload
}

private struct TestRemoteHookEventPayload: Decodable {
    let requestID: UUID
    let sessionID: String
    let cwd: String
    let status: String
    let provider: String
    let permissionMode: String?
    let message: String?
    let approvalsReviewer: String?
    let clientInfo: TestRemoteHookClientInfoPayload
}

private final class RemoteApprovalControlClient {
    private let fd: Int32
    private var buffer = Data()

    init(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd); throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        self.fd = fd
    }

    deinit { close(fd) }

    private struct Hello: Decodable { let type: String }
    func readHello() async throws { _ = try await next(Hello.self) }
    func readHookEvent() async throws -> TestRemoteHookEventMessage {
        try await next(TestRemoteHookEventMessage.self)
    }

    private func next<T: Decodable>(_ type: T.Type) async throws -> T {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let deadline = ContinuousClock().now + .seconds(8)
        while ContinuousClock().now < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let value = try? JSONDecoder().decode(type, from: line) { return value }
            }
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(bytes, count: count) }
            else if count == 0 { throw POSIXError(.ECONNRESET) }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw POSIXError(.EIO) }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }
        throw TestSupportError.timedOut("remote control message")
    }

    func sendDefer(requestID: UUID) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "decision", "requestID": requestID.uuidString, "decision": "defer"
        ]) + Data("\n".utf8)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress?.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                try await Task.sleep(for: .milliseconds(5))
            } else { throw POSIXError(.EIO) }
        }
    }
}

private struct TestRemoteHookClientInfoPayload: Decodable {
    let kind: String
    let transport: String?
    let sessionFilePath: String?
}

private struct TestRemoteCodexUsageMessage: Decodable {
    let type: String
    let payload: TestRemoteCodexUsageSnapshot
}

private struct TestRemoteCodexUsageSnapshot: Decodable {
    let sourceFilePath: String
    let planType: String?
    let limitID: String?
    let tokenUsage: TestRemoteCodexTokenUsage?
    let windows: [TestRemoteCodexUsageWindow]
}

private struct TestRemoteCodexTokenUsage: Decodable {
    let totalTokens: Int
}

private struct TestRemoteCodexUsageWindow: Decodable {
    let label: String
    let usedPercentage: Double
}

private func runSQLite(databaseURL: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["sqlite3", databaseURL.path(), sql]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "IslandBridgeE2ETests", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
