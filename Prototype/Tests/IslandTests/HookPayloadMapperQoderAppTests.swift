import Foundation
import IslandShared
import Testing

@Suite
struct HookPayloadMapperQoderAppTests {
    @Test
    func appProcessOverridesBothSharedHookProfilesBeforeProductMetadataArrives() throws {
        for hookKind in ["qoder", "qoder-cli"] {
            let envelope = try makeEnvelope(
                hookKind: hookKind,
                extraPayload: ["source_process_name": "/Applications/Qoder.app/Contents/MacOS/Qoder"]
            )
            #expect(envelope.metadata["client_kind"] == "qoder-app")
            #expect(envelope.metadata["hook_client_kind"] == hookKind)
            #expect(envelope.metadata["client_name"] == "Qoder")
            #expect(envelope.metadata["client_origin"] == "app")
            #expect(envelope.metadata["client_bundle_id"] == "com.qoder.app")
            #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
        }
    }

    @Test
    func appBundleAndProductMetadataIdentifyDesktopClients() throws {
        let app = try makeEnvelope(environment: ["__CFBundleIdentifier": "com.qoder.app"])
        #expect(app.metadata["client_kind"] == "qoder-app")

        for hookKind in ["qoder", "qoder-cli", "qoder-cn", "qoder-cn-cli"] {
            let envelope = try makeEnvelope(
                hookKind: hookKind,
                event: "Stop",
                extraPayload: ["parent_business_info": ["product": "app"]]
            )
            let isCN = hookKind.contains("-cn")
            #expect(envelope.metadata["client_kind"] == (isCN ? "qoder-cn-app" : "qoder-app"))
            #expect(envelope.metadata["client_name"] == (isCN ? "Qoder CN" : "Qoder"))
            #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
        }
    }

    @Test
    func appEvidenceDoesNotRebrandOtherAgentsOrCLIProcesses() throws {
        let claude = try makeEnvelope(
            hookKind: "claude-code",
            environment: ["__CFBundleIdentifier": "com.qoder.app"]
        )
        #expect(claude.metadata["client_kind"] == "claude-code")

        for (hookKind, process, bundle) in [
            ("qoder-cli", "/Users/test/.qoder/bin/qodercli/qodercli-1.1.58", "com.qoder.ide"),
            ("qoder-cn-cli", "/Users/test/.local/bin/qoderclicn", "com.aliyun.lingma.ide"),
            ("qoder-cli", "/Users/test/.qoder/bin/qodercli/qodercli-1.1.58", "com.qoder.app")
        ] {
            let envelope = try makeEnvelope(
                hookKind: hookKind,
                event: "PreToolUse",
                extraPayload: questionPayload.merging(["source_process_name": process]) { _, new in new },
                environment: ["__CFBundleIdentifier": bundle, "TTY": "/dev/ttys002"]
            )
            #expect(envelope.metadata["client_kind"] == hookKind)
            #expect(envelope.intervention?.kind == .question)
            #expect(envelope.expectsResponse)
            #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
        }
    }

    @Test
    func explicitCLIProductKeepsBlockingQuestionsInsideIDE() throws {
        let envelope = try makeEnvelope(
            event: "PreToolUse",
            extraPayload: questionPayload.merging(["parent_business_info": ["product": "cli"]]) { _, new in new },
            environment: ["__CFBundleIdentifier": "com.qoder.ide"]
        )
        #expect(envelope.metadata["client_kind"] == "qoder-cli")
        #expect(envelope.intervention?.kind == .question)
        #expect(envelope.expectsResponse)
        #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
    }

    @Test
    func desktopQuestionsAndApprovalsRetainBlockingResponseChannels() throws {
        for hookKind in ["qoder-cli", "qoder-cn-cli"] {
            for event in ["PreToolUse", "PermissionRequest"] {
                let envelope = try makeEnvelope(
                    hookKind: hookKind,
                    event: event,
                    extraPayload: questionPayload.merging(["parent_business_info": ["product": "app"]]) { _, new in new }
                )
                #expect(envelope.intervention?.kind == .question)
                #expect(envelope.intervention?.title == (hookKind.contains("-cn") ? "Qoder CN needs input" : "Qoder needs input"))
                #expect(envelope.expectsResponse)
                #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
            }
            let approval = try makeEnvelope(
                hookKind: hookKind,
                event: "PermissionRequest",
                extraPayload: ["parent_business_info": ["product": "app"], "tool_name": "Bash", "tool_input": ["command": "pwd"]]
            )
            #expect(approval.intervention?.kind == .approval)
            #expect(approval.expectsResponse)
            #expect(HookPayloadMapper.shouldDeliverEnvelope(approval))
        }
    }

    @Test
    func appAnswersPreserveQoderUpdatedInputProtocol() throws {
        for clientKind in ["qoder-app", "qoder-cn-app"] {
            for event in ["PreToolUse", "PermissionRequest"] {
                let response = BridgeResponse(
                    requestID: UUID(),
                    decision: .answer(["Which option?": "One"]),
                    updatedInput: ["answers": .object(["Which option?": .string("One")])]
                )
                let output = HookPayloadMapper.stdoutPayload(
                    for: .claude,
                    response: response,
                    eventType: event,
                    metadata: ["client_kind": clientKind, "tool_name": "AskUserQuestion"]
                )
                let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
                #expect(specific["hookEventName"] as? String == event)
                #expect(specific["permissionDecision"] as? String == "allow")
                let updated = try #require(specific["updatedInput"] as? [String: Any])
                #expect(updated["answers"] as? [String: String] == ["Which option?": "One"])
                let decision = try #require(specific["decision"] as? [String: Any])
                #expect(decision["updatedInput"] != nil)
            }
        }
    }

    @Test
    func cnAppEvidenceSurvivesHooksWithoutProductOnlyForTheSameSession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "__CFBundleIdentifier": "com.aliyun.lingma.ide"]
        _ = try makeEnvelope(hookKind: "qoder-cn-cli", event: "Stop", extraPayload: [
            "parent_business_info": ["product": "app"]
        ], environment: environment)
        let cache = home.appendingPathComponent(".ping-island/qoder-cn-app-sessions.json")
        let originalEvidence = try Data(contentsOf: cache)

        for event in ["PreToolUse", "PermissionRequest"] {
            let question = try makeEnvelope(hookKind: "qoder-cn-cli", event: event, extraPayload: questionPayload, environment: environment)
            #expect(question.metadata["client_kind"] == "qoder-cn-app")
            #expect(question.intervention?.kind == .question)
            #expect(question.expectsResponse)
            #expect(HookPayloadMapper.shouldDeliverEnvelope(question))
        }
        let approval = try makeEnvelope(hookKind: "qoder-cn-cli", event: "PermissionRequest", extraPayload: [
            "tool_name": "Bash", "tool_input": ["command": "pwd"]
        ], environment: environment)
        #expect(approval.metadata["client_kind"] == "qoder-cn-app")
        #expect(approval.intervention?.kind == .approval)
        #expect(approval.expectsResponse)
        #expect(HookPayloadMapper.shouldDeliverEnvelope(approval))
        #expect(try Data(contentsOf: cache) == originalEvidence)

        let other = try makeEnvelope(hookKind: "qoder-cn-cli", extraPayload: ["session_id": "another-session"], environment: environment)
        #expect(other.metadata["client_kind"] == "qoder-cn-cli")
        let ideProduct = try makeEnvelope(hookKind: "qoder-cn-cli", extraPayload: ["parent_business_info": ["product": "ide"]], environment: environment)
        #expect(ideProduct.metadata["client_kind"] == "qoder-cn-cli")
        _ = try makeEnvelope(hookKind: "qoder-cn-cli", event: "SessionEnd", environment: environment)
        let ended = try makeEnvelope(hookKind: "qoder-cn-cli", environment: environment)
        #expect(ended.metadata["client_kind"] == "qoder-cn-cli")
        _ = try makeEnvelope(hookKind: "qoder-cn-cli", event: "SessionEnd", extraPayload: ["parent_business_info": ["product": "app"]], environment: environment)
        let endedWithProduct = try makeEnvelope(hookKind: "qoder-cn-cli", environment: environment)
        #expect(endedWithProduct.metadata["client_kind"] == "qoder-cn-cli")
    }

    @Test
    func cliEvidenceInvalidatesRememberedCNAppIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "__CFBundleIdentifier": "com.aliyun.lingma.ide"]
        for cliEvidence: [String: Any] in [
            ["parent_business_info": ["product": "cli"]],
            ["source_process_name": "/Users/test/.local/bin/qoderclicn"],
            ["parent_business_info": ["product": "app"], "source_process_name": "/Users/test/.local/bin/qoderclicn"]
        ] {
            _ = try makeEnvelope(hookKind: "qoder-cn-cli", event: "Stop", extraPayload: ["parent_business_info": ["product": "app"]], environment: environment)
            for hookKind in ["qoder-cn-cli", "qoder-cn-app"] {
                let cli = try makeEnvelope(hookKind: hookKind, extraPayload: cliEvidence, environment: environment)
                #expect(cli.metadata["client_kind"] == "qoder-cn-cli")
            }
            let following = try makeEnvelope(hookKind: "qoder-cn-cli", environment: environment)
            #expect(following.metadata["client_kind"] == "qoder-cn-cli")
        }
    }

    @Test
    func rememberedCNAppEvidenceExpiresAndStaysBounded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ping-island")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("qoder-cn-app-sessions.json")
        let now = Date().timeIntervalSince1970
        var entries = Dictionary(uniqueKeysWithValues: (0..<260).map { ("session-\($0)", now - Double($0 + 1)) })
        entries["qoder-app-test"] = now - 86_401
        entries["future"] = now + 3_600
        try JSONEncoder().encode(entries).write(to: cache)
        let expired = try makeEnvelope(hookKind: "qoder-cn-cli", environment: ["HOME": home.path])
        #expect(expired.metadata["client_kind"] == "qoder-cn-cli")
        _ = try makeEnvelope(hookKind: "qoder-cn-cli", event: "Stop", extraPayload: ["parent_business_info": ["product": "app"]], environment: ["HOME": home.path])
        let retained = try JSONDecoder().decode([String: TimeInterval].self, from: Data(contentsOf: cache))
        #expect(retained.count == 256)
        #expect(retained["qoder-app-test"] != nil)
        #expect(retained["future"] == nil)
        #expect(retained["session-259"] == nil)
    }

    @Test
    func cnAppCacheRequiresExplicitProductSessionAndWritableHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        _ = try makeEnvelope(hookKind: "qoder-cn-app", environment: environment)
        _ = try makeEnvelope(hookKind: "qoder-cn-cli", extraPayload: ["session_id": NSNull(), "parent_business_info": ["product": "app"]], environment: environment)
        #expect(!FileManager.default.fileExists(atPath: home.path))

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".ping-island"))
        let explicit = try makeEnvelope(hookKind: "qoder-cn-cli", extraPayload: ["parent_business_info": ["product": "app"]], environment: environment)
        #expect(explicit.metadata["client_kind"] == "qoder-cn-app")
        let following = try makeEnvelope(hookKind: "qoder-cn-cli", environment: environment)
        #expect(following.metadata["client_kind"] == "qoder-cn-cli")
    }

    @Test
    func sharedSettingsChooseOneAppDeliveryOwnerOnlyWhenMatchingCLIHookExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("ping-island-bridge")
        let quotedExecutable = home.appendingPathComponent("bridge folder").appendingPathComponent("PingIslandBridge")
        let nonExecutable = home.appendingPathComponent("not-executable").appendingPathComponent("ping-island-bridge")
        for file in [executable, quotedExecutable, nonExecutable] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: file == nonExecutable ? 0o644 : 0o755], ofItemAtPath: file.path)
        }
        for (desktopKind, cliKind, config) in [
            ("qoder", "qoder-cli", ".qoder"),
            ("qoder-cn", "qoder-cn-cli", ".qoder-cn")
        ] {
            let settings = home.appendingPathComponent(config).appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = questionPayload.merging(["parent_business_info": ["product": "app"]]) { _, new in new }
            for (matcher, event, command, expectsDuplicate) in [
                ("*", "PreToolUse", "\(executable.path) --source claude --client-kind \(cliKind)", true),
                ("AskUserQuestion", "PreToolUse", "'\(quotedExecutable.path)' --source claude --client-kind '\(cliKind)'", true),
                ("AskUserQuestion", "PreToolUse", "\"\(quotedExecutable.path)\" --source claude --client-kind \"\(cliKind)\"", true),
                ("Bash", "PreToolUse", "\(executable.path) --source claude --client-kind \(cliKind)", false),
                ("*", "Stop", "\(executable.path) --source claude --client-kind \(cliKind)", false),
                ("*", "PreToolUse", "\(home.path)/missing/ping-island-bridge --source claude --client-kind \(cliKind)", false),
                ("*", "PreToolUse", "\(nonExecutable.path) --source claude --client-kind \(cliKind)", false),
                ("*", "PreToolUse", "/bin/sh \(executable.path) --source claude --client-kind \(cliKind)", false),
                ("*", "PreToolUse", "ping-island-bridge --source claude --client-kind \(cliKind)", false),
                ("*", "PreToolUse", "/tmp/other-hook --client-kind \(cliKind)", false)
            ] {
                let document: [String: Any] = ["hooks": [event: [["matcher": matcher, "hooks": [["type": "command", "command": command]]]]]]
                try JSONSerialization.data(withJSONObject: document).write(to: settings)
                let desktop = try makeEnvelope(hookKind: desktopKind, event: "PreToolUse", extraPayload: payload, environment: ["HOME": home.path])
                let cli = try makeEnvelope(hookKind: cliKind, event: "PreToolUse", extraPayload: payload, environment: ["HOME": home.path])
                #expect(HookPayloadMapper.shouldDeliverEnvelope(desktop) == !expectsDuplicate)
                #expect(HookPayloadMapper.shouldDeliverEnvelope(cli))
                #expect(desktop.metadata["client_kind"] == cli.metadata["client_kind"])
            }
            try FileManager.default.removeItem(at: settings)
            let single = try makeEnvelope(hookKind: desktopKind, event: "PreToolUse", extraPayload: payload, environment: ["HOME": home.path])
            #expect(HookPayloadMapper.shouldDeliverEnvelope(single))
        }
    }

    private var questionPayload: [String: Any] {
        ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which option?", "options": [["label": "One"], ["label": "Two"]]]]]]
    }

    private func makeEnvelope(
        hookKind: String = "qoder-cli",
        event: String = "SessionStart",
        extraPayload: [String: Any] = [:],
        environment: [String: String] = [:]
    ) throws -> BridgeEnvelope {
        let payload: [String: Any] = ["hook_event_name": event, "session_id": "qoder-app-test"]
            .merging(extraPayload) { _, new in new }
        return HookPayloadMapper.makeEnvelope(
            source: .claude,
            arguments: ["ping-island-bridge", "--source", "claude", "--client-kind", hookKind, "--client-name", "Qoder CLI", "--client-origin", "cli"],
            environment: environment,
            stdinData: try JSONSerialization.data(withJSONObject: payload)
        )
    }
}
