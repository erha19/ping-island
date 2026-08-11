import Foundation
import XCTest
@testable import Ping_Island

final class CodexRolloutParserTests: XCTestCase {
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
