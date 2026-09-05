import XCTest
@testable import Ping_Island

final class OmpAskQuestionTests: XCTestCase {
    func testGeneratedOmpAskFallsBackWithoutSendingASecondBlockingRequest() throws {
        let node = ProcessInfo.processInfo.environment["PING_ISLAND_TEST_NODE"] ?? "node"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = [node, "--experimental-strip-types", "-e", ""]
        probe.standardError = Pipe()
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            throw XCTSkip("Node with TypeScript stripping is needed to execute the generated hook")
        }
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "omp-hooks"))
        var source = HookInstaller.managedPluginSource(for: profile)
        let bridgeStart = try XCTUnwrap(source.range(of: "function runBridge("))
        let bridgeEnd = try XCTUnwrap(source.range(of: "function deniedByIsland("))
        source.replaceSubrange(bridgeStart.lowerBound..<bridgeEnd.lowerBound, with: """
        const requests: unknown[] = [];
        async function runBridge(payload: unknown, captureResponse: boolean) {
          requests.push({ payload, captureResponse });
          return null;
        }

        """)
        source += """

        const handlers = new Map();
        pingIslandOmpHook({ on(name, handler) { handlers.set(name, handler); } } as any);
        const event = { toolName: "ask", toolCallId: "call-1", input: {
          questions: [{ id: "topic", question: "Choose", options: [{ label: "A" }] }]
        }};
        const ctx = { hasUI: true, cwd: "/tmp/project", sessionManager: { getSessionId: () => "test" } };
        const result = await handlers.get("tool_call")(event, ctx);
        if (result !== undefined || requests.length !== 1) {
          throw new Error(`Fallback must send one question and return to OMP: ${JSON.stringify(requests)}`);
        }
        requests.length = 0;
        await handlers.get("tool_call")(event, { ...ctx, hasUI: false });
        if (requests.length !== 0) throw new Error("Headless ask must not create an unconsumed request");
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("omp-fallback.mts")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [node, "--experimental-strip-types", script.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }

    func testOmpAskToolCreatesQuestionIntervention() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-1",
            notificationType: nil,
            message: nil,
            bridgeExpectsResponse: true
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertFalse(event.isAnsweredAskUserQuestionEvent)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(event.intervention?.questions.first?.prompt, "先选一个主题")
    }

    func testOmpAskMultiQuestionSetsAllowsMultiple() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "scopes",
                        "question": "需要覆盖哪些范围",
                        "multi": true,
                        "options": [
                            ["label": "核心流程"],
                            ["label": "边界情况"],
                            ["label": "文档"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-2",
            notificationType: nil,
            message: nil,
            bridgeExpectsResponse: true
        )

        let question = event.intervention?.questions.first
        XCTAssertEqual(question?.prompt, "需要覆盖哪些范围")
        XCTAssertTrue(question?.allowsMultiple ?? false)
        XCTAssertEqual(question?.options.count, 3)
    }

    func testOmpAskAnsweredNotificationDoesNotCreateIntervention() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "先选一个主题": "A 方案"
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAnsweredAskUserQuestionEvent)
        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertNil(event.intervention)
    }

    func testNonOmpAskToolIsNotTreatedAsQuestionTool() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-1",
            notificationType: nil,
            message: nil
        )

        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertFalse(event.isAnsweredAskUserQuestionEvent)
        XCTAssertNil(event.intervention)
    }
}
