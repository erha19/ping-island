import Foundation
import XCTest
@testable import Ping_Island

final class CodexRolloutParserTests: XCTestCase {
    func testAuxiliaryRolloutsUseSourceOrOpeningPromptAcrossIncrementalReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let titlePrompt = "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt. The title you generate will be shown in the UI to represent the prompt."
        let cases: [(source: String?, prompt: String, hidden: Bool)] = [
            ("thread_title", "An inherited user request", true),
            ("thread_title_reconsideration", "An inherited user request", true),
            ("ambient_suggestions", "An inherited user request", true),
            (nil, titlePrompt, true),
            ("user", "Review this template: " + titlePrompt, false),
            ("ambient_suggestion_task", "Return project suggestions as JSON", false),
            ("user", #"{"title":"Project title","suggestions":[],"exclude":[]}"#, false)
        ]

        for (index, testCase) in cases.enumerated() {
            let threadID = "auxiliary-rollout-\(index)"
            let url = directory.appendingPathComponent("rollout-\(threadID).jsonl")
            var metadata: [String: Any] = [
                "id": threadID, "cwd": "/tmp/project", "source": "vscode", "originator": "Codex Desktop"
            ]
            metadata["thread_source"] = testCase.source
            let records: [[String: Any]] = [
                ["type": "session_meta", "payload": metadata],
                ["type": "event_msg", "payload": ["type": "user_message", "message": testCase.prompt]],
                ["type": "event_msg", "payload": ["type": "agent_message", "phase": "final", "message": #"{"title":"Project title","suggestions":[],"exclude":[]}"#]]
            ]
            let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            let client = SessionClientInfo(kind: .codexApp, sessionFilePath: url.path)
            let initial = await CodexRolloutParser.shared.parseThread(threadId: threadID, fallbackCwd: "/tmp/project", clientInfo: client)
            XCTAssertEqual(initial == nil, testCase.hidden, "case \(index)")

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Done\"}}\n".utf8))
            try handle.close()
            let appended = await CodexRolloutParser.shared.parseThread(threadId: threadID, fallbackCwd: "/tmp/project", clientInfo: client)
            XCTAssertEqual(appended == nil, testCase.hidden, "appended case \(index)")
            let metrics = await CodexRolloutParser.shared.debugReadMetrics(forFilePath: url.path)
            XCTAssertEqual(metrics?.fullRebuildCount, 1)
            XCTAssertEqual(metrics?.incrementalReadCount, 1)
        }
    }

    func testDesktopRolloutRepairsCachedQoderIdentityUnlessActualTerminalEvidenceExists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for terminalTTY in [nil, "/dev/ttys321"] as [String?] {
            let threadID = UUID().uuidString
            let url = directory.appendingPathComponent("rollout-\(threadID).jsonl")
            let rollout = """
            {"type":"session_meta","payload":{"id":"\(threadID)","cwd":"/tmp/project","originator":"Codex Desktop","source":"vscode","thread_source":"user"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"Fix session routing"}}
            """
            try rollout.write(to: url, atomically: true, encoding: .utf8)
            let snapshot = await CodexRolloutParser.shared.parseThread(
                threadId: threadID, fallbackCwd: "/tmp/project",
                clientInfo: SessionClientInfo(
                    kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI",
                    bundleIdentifier: "com.aliyun.lingma.ide", launchURL: "qoder-cn://open?session=\(threadID)",
                    origin: "cli", originator: "Qoder CN", threadSource: "cli", sessionFilePath: url.path,
                    terminalBundleIdentifier: "com.aliyun.lingma.ide", terminalTTY: terminalTTY
                )
            )
            let client = try XCTUnwrap(snapshot?.clientInfo)
            XCTAssertEqual(client.threadSource, "user")
            if terminalTTY == nil {
                XCTAssertEqual(client.kind, .codexApp)
                XCTAssertEqual(client.bundleIdentifier, "com.openai.codex")
                XCTAssertNil(client.terminalBundleIdentifier)
                XCTAssertFalse(client.launchURL?.hasPrefix("qoder-cn:") == true)
            } else {
                XCTAssertEqual(client.kind, .codexCLI)
                XCTAssertEqual(client.terminalBundleIdentifier, "com.aliyun.lingma.ide")
                XCTAssertEqual(client.terminalTTY, terminalTTY)
            }
        }
    }

    func testRolloutParserIgnoresCodexMemoryMaintenanceThread() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019f098a-04fe-7402-9a6d-21108754533d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-06-27T14:44:29Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/ping-island-home/.codex/memories","title":"memories","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-06-27T14:44:30Z","type":"event_msg","payload":{"type":"user_message","message":"update memory"}}
        {"timestamp":"2026-06-27T14:46:25Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"Created MEMORY.md and memory_summary.md from the new inputs."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-home/.codex/memories",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot)
    }

    func testRolloutParserIgnoresAmbientSuggestionsAcrossIncrementalAppends() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019f098a-04fe-7402-9a6d-21108754533d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-06-27T14:44:29Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/project","title":"project","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-06-27T14:44:30Z","type":"event_msg","payload":{"type":"user_message","message":"# Overview\\n\\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"}}
        {"timestamp":"2026-06-27T14:46:25Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"No suggestions available."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot)
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Done\"}}\n".utf8))
        try handle.close()
        let appended = await CodexRolloutParser.shared.parseThread(
            threadId: threadId, fallbackCwd: "/tmp/project",
            clientInfo: SessionClientInfo(kind: .codexApp, sessionFilePath: rolloutURL.path))
        XCTAssertNil(appended)
    }

    func testRolloutParserPreservesTerminalHostedCodexCLIContext() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d77a9-b7e4-76d3-996a-adadefcf7a56"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T13:51:51Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/claude-island","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T13:51:52Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}
        {"timestamp":"2026-04-10T13:51:57Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"Hi. What do you need help with in this repo?"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/claude-island",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                origin: "cli",
                threadSource: "cli",
                sessionFilePath: rolloutURL.path,
                terminalBundleIdentifier: "com.googlecode.iterm2",
                terminalProgram: "iTerm.app",
                terminalSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                iTermSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                processName: "/Users/ping-island/.nvm/versions/node/v22.21.1/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
            )
        )

        let clientInfo = try XCTUnwrap(snapshot?.clientInfo)
        XCTAssertEqual(clientInfo.kind, .codexCLI)
        XCTAssertEqual(clientInfo.origin, "cli")
        XCTAssertEqual(clientInfo.threadSource, "cli")
        XCTAssertEqual(clientInfo.terminalBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(clientInfo.iTermSessionIdentifier, "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556")
        XCTAssertNil(clientInfo.bundleIdentifier)
        XCTAssertNil(clientInfo.launchURL)
    }

    func testRolloutOriginatorDoesNotReplaceCodexClientIdentity() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "codex-thread-with-ide-originator"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-09-07T10:00:00Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/project","originator":"Qoder CN IDE","source":"desktop"}}
        {"timestamp":"2026-09-07T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"inspect the project"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Qoder CN IDE",
                bundleIdentifier: "com.aliyun.lingma.ide",
                sessionFilePath: rolloutURL.path
            )
        )

        let clientInfo = try XCTUnwrap(snapshot?.clientInfo)
        XCTAssertEqual(clientInfo.profileID, "codex-app")
        XCTAssertEqual(clientInfo.name, "Codex App")
        XCTAssertEqual(clientInfo.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(clientInfo.originator, "Qoder CN IDE")
        XCTAssertNil(clientInfo.ideHostProfile)
        XCTAssertNil(clientInfo.ideHostBadgeLabel(for: .codex))
    }

    func testRolloutParserInfersPendingMCPApprovalFromUnresolvedToolCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.139Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"仓库根目录里有 `README.md` 和 `README.zh-CN.md` 两个文件；按你的单数表述，我先删除主 README，也就是根目录的 `README.md`。先核对当前状态，再直接改。"}],"phase":"commentary"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .waitingForInput)
        XCTAssertEqual(snapshot?.intervention?.title, "MCP Tool Approval Needed")
        XCTAssertEqual(snapshot?.intervention?.metadata["server"], "omx_state")
        XCTAssertEqual(snapshot?.intervention?.metadata["toolName"], "state_get_status")
    }

    func testRolloutParserDoesNotInferPendingMCPApprovalForCodexApp() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.phase, .processing)
    }

    func testRolloutParserSurfacesPendingRequestUserInputCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb0"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-24T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"build a small TodoList sample"}}
        {"timestamp":"2026-04-24T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question_1","arguments":"{\\"questions\\":[{\\"header\\":\\"Data\\",\\"id\\":\\"todo_data\\",\\"question\\":\\"TodoList 示例的数据要怎么处理？\\",\\"options\\":[{\\"label\\":\\"内存状态（推荐）\\",\\"description\\":\\"最适合作为简洁示例，刷新或重启后数据丢失。\\"},{\\"label\\":\\"UserDefaults 持久化\\",\\"description\\":\\"更接近可用小功能，但会多出存储和测试细节。\\"}]}]}"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .waitingForInput)
        XCTAssertEqual(snapshot?.intervention?.kind, .question)
        XCTAssertEqual(snapshot?.intervention?.metadata["source"], "codex_rollout_request_user_input")
        XCTAssertEqual(snapshot?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertEqual(snapshot?.intervention?.resolvedQuestions.first?.prompt, "TodoList 示例的数据要怎么处理？")
        XCTAssertEqual(snapshot?.intervention?.resolvedQuestions.first?.options.map(\.title), ["内存状态（推荐）", "UserDefaults 持久化"])
        XCTAssertTrue(snapshot?.intervention?.resolvedQuestions.first?.allowsOther ?? false)
    }

    func testRolloutParserClearsRequestUserInputAfterOutput() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb1"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-24T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"build a small TodoList sample"}}
        {"timestamp":"2026-04-24T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question_1","arguments":"{\\"questions\\":[{\\"id\\":\\"todo_data\\",\\"question\\":\\"TodoList 示例的数据要怎么处理？\\",\\"options\\":[{\\"label\\":\\"内存状态（推荐)\\"}]}]}"}}
        {"timestamp":"2026-04-24T17:59:40Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_question_1","output":"{\\"answers\\":{\\"todo_data\\":[\\"内存状态（推荐)\\"]}}"}}
        {"timestamp":"2026-04-24T17:59:45Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"我会用内存状态实现这个示例。"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.phase, .idle)
        XCTAssertEqual(snapshot?.latestResponseText, "我会用内存状态实现这个示例。")
    }

    func testRolloutParserMarksRunningToolInterruptedAfterTurnAbort() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb2"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-24T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"run tests"}}
        {"timestamp":"2026-04-24T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_tests","arguments":"{\\"command\\":\\"xcodebuild test\\"}"}}
        {"timestamp":"2026-04-24T17:59:40Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .idle)
        XCTAssertEqual(snapshot?.isTurnInterrupted, true)
        guard case .toolCall(let tool) = snapshot?.historyItems.last?.type else {
            return XCTFail("Expected interrupted tool call")
        }
        XCTAssertEqual(tool.status, .interrupted)
    }

    func testRolloutParserExtractsCodexSubagentMetadataFromSessionMeta() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentThreadId = "019da119-db3a-7532-8355-5ba0ecf56640"
        let threadId = "019da11a-353a-79e3-8a52-5f051d2e00a9"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-18T14:59:02Z","type":"session_meta","payload":{"id":"\(threadId)","forked_from_id":"\(parentThreadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentThreadId)","depth":1,"agent_nickname":"Kierkegaard","agent_role":"explorer"}}},"agent_nickname":"Kierkegaard","agent_role":"explorer"}}
        {"timestamp":"2026-04-18T14:59:03Z","type":"event_msg","payload":{"type":"user_message","message":"inspect the repo"}}
        {"timestamp":"2026-04-18T14:59:05Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"I checked the repo entrypoints."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.parentThreadId, parentThreadId)
        XCTAssertEqual(snapshot?.subagentDepth, 1)
        XCTAssertEqual(snapshot?.subagentNickname, "Kierkegaard")
        XCTAssertEqual(snapshot?.subagentRole, "explorer")
        XCTAssertEqual(snapshot?.isSubagent, true)
    }

    func testRolloutParserKeepsUserForkAsRegularThread() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentThreadId = "019da119-db3a-7532-8355-5ba0ecf56640"
        let threadId = "019da11a-353a-79e3-8a52-5f051d2e00b0"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-08-04T10:00:00Z","type":"session_meta","payload":{"id":"\(threadId)","forked_from_id":"\(parentThreadId)","cwd":"/tmp/ping-island-project","originator":"Codex Desktop","source":"vscode","thread_source":"user","title":"User fork"}}
        {"timestamp":"2026-08-04T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"continue from here"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-project",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.name, "User fork")
        XCTAssertNil(snapshot?.parentThreadId)
        XCTAssertNil(snapshot?.subagentDepth)
        XCTAssertFalse(snapshot?.isSubagent ?? true)
    }

    func testRolloutParserReadsOnlyAppendedBytesAndRebuildsAfterTruncation() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019fdd31-9f64-7533-8f52-7ac4ed96f001"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let initialRollout = """
        {"timestamp":"2026-08-11T08:00:00Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/ping-island-project","source":"desktop"}}
        {"timestamp":"2026-08-11T08:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"first request"}}

        """
        let initialData = try XCTUnwrap(initialRollout.data(using: .utf8))
        try initialData.write(to: rolloutURL)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let initialSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-project",
            clientInfo: clientInfo
        )
        let initialMetrics = await CodexRolloutParser.shared.debugReadMetrics(forFilePath: rolloutURL.path)

        XCTAssertEqual(initialSnapshot?.latestUserText, "first request")
        XCTAssertEqual(initialMetrics?.fullRebuildCount, 1)
        XCTAssertEqual(initialMetrics?.incrementalReadCount, 0)
        XCTAssertEqual(initialMetrics?.lastReadByteCount, initialData.count)

        let appendedRollout = """
        {"timestamp":"2026-08-11T08:00:02Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"first response"}}

        """
        let appendedData = try XCTUnwrap(appendedRollout.data(using: .utf8))
        let appendHandle = try FileHandle(forWritingTo: rolloutURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: appendedData)
        try appendHandle.close()

        let appendedSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-project",
            clientInfo: clientInfo
        )
        let appendedMetrics = await CodexRolloutParser.shared.debugReadMetrics(forFilePath: rolloutURL.path)

        XCTAssertEqual(appendedSnapshot?.latestResponseText, "first response")
        XCTAssertEqual(appendedSnapshot?.historyItems.count, 2)
        XCTAssertEqual(appendedMetrics?.fullRebuildCount, 1)
        XCTAssertEqual(appendedMetrics?.incrementalReadCount, 1)
        XCTAssertEqual(appendedMetrics?.lastReadByteCount, appendedData.count)

        let replacementRollout = """
        {"timestamp":"2026-08-11T09:00:00Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/new-project"}}
        {"timestamp":"2026-08-11T09:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"replacement"}}

        """
        let replacementData = try XCTUnwrap(replacementRollout.data(using: .utf8))
        let replacementHandle = try FileHandle(forWritingTo: rolloutURL)
        try replacementHandle.truncate(atOffset: 0)
        try replacementHandle.write(contentsOf: replacementData)
        try replacementHandle.close()

        let replacementSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-project",
            clientInfo: clientInfo
        )
        let replacementMetrics = await CodexRolloutParser.shared.debugReadMetrics(forFilePath: rolloutURL.path)

        XCTAssertEqual(replacementSnapshot?.cwd, "/tmp/new-project")
        XCTAssertEqual(replacementSnapshot?.latestUserText, "replacement")
        XCTAssertNil(replacementSnapshot?.latestResponseText)
        XCTAssertEqual(replacementSnapshot?.historyItems.count, 1)
        XCTAssertEqual(replacementMetrics?.fullRebuildCount, 2)
        XCTAssertEqual(replacementMetrics?.incrementalReadCount, 1)
        XCTAssertEqual(replacementMetrics?.lastReadByteCount, replacementData.count)
    }

    func testUnnamedRolloutIncrementalRecoveryToleratesDuplicateEmptyToolCallIds() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019fdd31-9f64-7533-8f52-7ac4ed96f003"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let initialRollout = """
        {"timestamp":"2026-08-18T08:00:00Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/tmp/unnamed-codex-thread","source":"desktop"}}
        {"timestamp":"2026-08-18T08:00:01Z","type":"response_item","payload":{"type":"function_call","name":"first_tool","call_id":"","arguments":"{}"}}
        {"timestamp":"2026-08-18T08:00:02Z","type":"response_item","payload":{"type":"function_call","name":"second_tool","call_id":"","arguments":"{}"}}

        """
        try initialRollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let initialSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/unnamed-codex-thread",
            clientInfo: clientInfo
        )
        XCTAssertNil(initialSnapshot?.name)
        XCTAssertEqual(initialSnapshot?.historyItems.count, 2)

        let appendedRollout = """
        {"timestamp":"2026-08-18T08:00:03Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"Recovered without crashing."}}

        """
        let appendHandle = try FileHandle(forWritingTo: rolloutURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: XCTUnwrap(appendedRollout.data(using: .utf8)))
        try appendHandle.close()

        let recoveredSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/unnamed-codex-thread",
            clientInfo: clientInfo
        )
        let recoveredMetrics = await CodexRolloutParser.shared.debugReadMetrics(forFilePath: rolloutURL.path)

        XCTAssertNil(recoveredSnapshot?.name)
        XCTAssertEqual(recoveredSnapshot?.historyItems.count, 3)
        XCTAssertEqual(recoveredSnapshot?.latestResponseText, "Recovered without crashing.")
        XCTAssertEqual(recoveredMetrics?.fullRebuildCount, 1)
        XCTAssertEqual(recoveredMetrics?.incrementalReadCount, 1)
    }

    func testRolloutParserBoundsRetainedHistoryWhilePreservingLatestState() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019fdd31-9f64-7533-8f52-7ac4ed96f002"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        var lines = [
            "{\"timestamp\":\"2026-08-11T08:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadId)\",\"cwd\":\"/tmp/ping-island-project\",\"source\":\"desktop\"}}"
        ]
        lines.append(contentsOf: (0..<650).map { index in
            "{\"timestamp\":\"2026-08-11T08:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"request \(index)\"}}"
        })
        try (lines.joined(separator: "\n") + "\n").write(
            to: rolloutURL,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/tmp/ping-island-project",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.historyItems.count, CodexRolloutParser.maximumRetainedHistoryItems)
        XCTAssertEqual(snapshot?.conversationInfo.firstUserMessage, "request 0")
        XCTAssertEqual(snapshot?.latestUserText, "request 649")
        guard case .user(let oldestRetainedText) = snapshot?.historyItems.first?.type else {
            return XCTFail("Expected retained user history")
        }
        XCTAssertEqual(oldestRetainedText, "request 150")
    }
}
