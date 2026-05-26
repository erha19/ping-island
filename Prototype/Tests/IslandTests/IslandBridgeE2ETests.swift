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
                environment: ["ISLAND_SOCKET_PATH": socketPath]
            )

            let result = process.waitForExit()

            #expect(result.terminationStatus == 0)
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
            #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

@Test
func islandBridgeHealthCheckFailsWhenSocketIsUnavailable() throws {
    let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
    let process = try RunningProcess(
        executableURL: executable,
        arguments: ["--mode", "health-check"],
        environment: [
            "ISLAND_SOCKET_PATH": "/tmp/ping-island-missing-\(UUID().uuidString).sock"
        ]
    )

    let result = process.waitForExit()

    #expect(result.terminationStatus != 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

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
func remoteAgentForwardsCodexAppServerStateUpdates() async throws {
    try await withTemporaryDirectory { directory in
        let executable = try TestRuntime.executableURL(named: "PingIslandBridge")
        let codexHome = directory.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try createCodexStateDatabase(
            at: codexHome.appending(path: "state_5.sqlite"),
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
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
        #expect(event.payload.status == "processing")
        #expect(event.payload.message == "Remote Codex is editing files")
        #expect(event.payload.clientInfo.kind == "codexCLI")
        #expect(event.payload.clientInfo.transport == "ssh")
        #expect(event.payload.clientInfo.sessionFilePath == "/home/dev/.codex/sessions/rollout.jsonl")
    }
}

private func createCodexStateDatabase(at url: URL, updatedAtMs: Int64) throws {
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
          '/home/dev/.codex/sessions/rollout.jsonl',
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
                if let event = try? decoder.decode(TestRemoteHookEventMessage.self, from: line),
                   predicate(event) {
                    return event
                }
            }
        } else {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    throw TestSupportError.timedOut("remote Codex hook event")
}

private struct TestRemoteHookEventMessage: Decodable {
    let type: String
    let payload: TestRemoteHookEventPayload
}

private struct TestRemoteHookEventPayload: Decodable {
    let sessionID: String
    let cwd: String
    let status: String
    let provider: String
    let message: String?
    let clientInfo: TestRemoteHookClientInfoPayload
}

private struct TestRemoteHookClientInfoPayload: Decodable {
    let kind: String
    let transport: String?
    let sessionFilePath: String?
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
