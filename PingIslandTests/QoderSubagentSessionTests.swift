import Foundation
import XCTest
@testable import NotchCode

final class QoderSubagentSessionTests: XCTestCase {
    func testQoderChildSessionUsesParentAgentTitleOnlyPresentation() async {
        let store = SessionStore.shared
        let suffix = UUID().uuidString
        let cwd = "/tmp/qoder-subagent-\(suffix)"
        let parentId = "qoder-parent-\(suffix)"
        let childId = "qoder-child-\(suffix)"

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: parentId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Agent",
            toolUseId: "agent-tool-\(suffix)",
            toolInput: [
                "description": AnyCodable("读取README文件")
            ]
        )))

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ]
        )))

        let child = await store.session(for: childId)
        XCTAssertEqual(child?.linkedParentSessionId, parentId)
        XCTAssertTrue(child?.usesTitleOnlySubagentPresentation ?? false)
        XCTAssertEqual(child?.titleOnlySubagentDisplayTitle, "Agent · 读取README文件")

        await store.process(.sessionArchived(sessionId: childId))
        await store.process(.sessionArchived(sessionId: parentId))
    }

    func testQoderChildSessionFollowsParentEndedStateWithoutOwnStopHook() async {
        let store = SessionStore.shared
        let suffix = UUID().uuidString
        let cwd = "/tmp/qoder-subagent-end-\(suffix)"
        let parentId = "qoder-parent-end-\(suffix)"
        let childId = "qoder-child-end-\(suffix)"

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: parentId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Agent",
            toolUseId: "agent-tool-\(suffix)",
            toolInput: [
                "description": AnyCodable("读取README文件")
            ]
        )))

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ]
        )))

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PostToolUse",
            status: "processing",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ],
            message: "/Users/ping-island/Island/README.md"
        )))

        let childBeforeParentStop = await store.session(for: childId)
        XCTAssertEqual(childBeforeParentStop?.phase, .processing)

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: parentId,
            cwd: cwd,
            event: "Stop",
            status: "ended",
            message: "完成"
        )))

        let parent = await store.session(for: parentId)
        let child = await store.session(for: childId)
        XCTAssertEqual(parent?.phase, .ended)
        XCTAssertEqual(child?.linkedParentSessionId, parentId)
        XCTAssertEqual(child?.phase, .ended)

        await store.process(.sessionArchived(sessionId: childId))
        await store.process(.sessionArchived(sessionId: parentId))
    }

    func testArchivingQoderParentAlsoRemovesLinkedChildSession() async {
        let store = SessionStore.shared
        let suffix = UUID().uuidString
        let cwd = "/tmp/qoder-subagent-archive-\(suffix)"
        let parentId = "qoder-parent-archive-\(suffix)"
        let childId = "qoder-child-archive-\(suffix)"

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: parentId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Agent",
            toolUseId: "agent-tool-\(suffix)",
            toolInput: [
                "description": AnyCodable("读取README文件")
            ]
        )))

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ]
        )))

        let childBeforeArchive = await store.session(for: childId)
        XCTAssertNotNil(childBeforeArchive)

        await store.process(.sessionArchived(sessionId: parentId))

        let parentAfterArchive = await store.session(for: parentId)
        let childAfterArchive = await store.session(for: childId)
        XCTAssertNil(parentAfterArchive)
        XCTAssertNil(childAfterArchive)
    }

    func testDiagnosticsSnapshotIncludesQoderLinkedSubagentPresentationFields() async {
        let store = SessionStore.shared
        let suffix = UUID().uuidString
        let cwd = "/tmp/qoder-subagent-diagnostics-\(suffix)"
        let parentId = "qoder-parent-diagnostics-\(suffix)"
        let childId = "qoder-child-diagnostics-\(suffix)"

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: parentId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Agent",
            toolUseId: "agent-tool-\(suffix)",
            toolInput: [
                "description": AnyCodable("读取README文件")
            ]
        )))

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ]
        )))

        let child = await store.session(for: childId)
        let snapshot = await store.diagnosticsSnapshot()
            .first { $0.sessionId == childId }

        XCTAssertEqual(snapshot?.displayTitle, child?.displayTitle)
        XCTAssertEqual(snapshot?.effectiveDisplayTitle, child?.titleOnlySubagentDisplayTitle)
        XCTAssertEqual(snapshot?.presentationMode, "titleOnlySubagent")
        XCTAssertEqual(snapshot?.linkedParentSessionId, parentId)
        XCTAssertEqual(snapshot?.linkedSubagentDisplayTitle, child?.linkedSubagentDisplayTitle)
        XCTAssertEqual(snapshot?.usesTitleOnlySubagentPresentation, child?.usesTitleOnlySubagentPresentation)
        XCTAssertNil(snapshot?.codexSubagentLevel)
        XCTAssertNil(snapshot?.codexSubagentLabel)

        await store.process(.sessionArchived(sessionId: childId))
        await store.process(.sessionArchived(sessionId: parentId))
    }

    func testQoderFallbackSubagentTranscriptUsesTitleOnlyPresentationWithoutParentLink() async throws {
        let store = SessionStore.shared
        let parser = ConversationParser.shared
        let suffix = UUID().uuidString
        let cwd = "/tmp/qoder-subagent-fallback-\(suffix)"
        let childId = "qoder-child-fallback-\(suffix)"
        let transcriptURL = try makeQoderFallbackTranscript(sessionId: childId)

        await store.process(.hookReceived(makeQoderEvent(
            sessionId: childId,
            cwd: cwd,
            event: "PreToolUse",
            status: "running_tool",
            tool: "read_file",
            toolUseId: "read-file-\(suffix)",
            toolInput: [
                "file_path": AnyCodable("/Users/ping-island/Island/README.md")
            ],
            sessionFilePath: transcriptURL.path
        )))

        let incremental = await parser.parseIncremental(
            sessionId: childId,
            cwd: cwd,
            explicitFilePath: transcriptURL.path
        )
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: childId,
            cwd: cwd,
            messages: incremental.newMessages,
            isIncremental: true,
            completedToolIds: incremental.completedToolIds,
            toolResults: incremental.toolResults,
            structuredResults: incremental.structuredResults
        )))

        let child = await store.session(for: childId)
        XCTAssertNil(child?.linkedParentSessionId)
        XCTAssertTrue(child?.usesTitleOnlySubagentPresentation ?? false)
        XCTAssertEqual(child?.titleOnlySubagentDisplayTitle, "Agent · Read File README.md")

        await store.process(.sessionArchived(sessionId: childId))
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    private func makeQoderEvent(
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        message: String? = nil,
        sessionFilePath: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide",
                sessionFilePath: sessionFilePath
            ),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: nil,
            message: message
        )
    }

    private func makeQoderFallbackTranscript(sessionId: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-subagent-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let transcriptURL = directoryURL.appendingPathComponent("\(sessionId).jsonl")
        let lines = [
            """
            {"type":"assistant","sessionId":"\(sessionId)","uuid":"assistant-\(sessionId)","timestamp":"2026-04-18T17:46:13.261253Z","cwd":"/tmp/project","message":{"role":"assistant","content":[{"id":"call-\(sessionId)","input":{"file_path":"/Users/ping-island/Island/README.md"},"name":"read_file","type":"tool_use"}]}}
            """,
            """
            {"type":"user","sessionId":"\(sessionId)","uuid":"user-\(sessionId)","timestamp":"2026-04-18T17:46:13.605588Z","cwd":"/tmp/project","message":{"role":"user","content":[{"content":"Contents of /Users/ping-island/Island/README.md, from line 1-10"}]}}
            """
        ]

        try lines.joined(separator: "\n").appending("\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }
}
