import XCTest
@testable import Ping_Island

final class HermesIntegrationTests: XCTestCase {
    func testHermesManagedProfileUsesPluginDirectoryInstallation() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "hermes-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Hermes")
        XCTAssertEqual(profile?.installationKind, .pluginDirectory)
        XCTAssertEqual(profile?.brand, .hermes)
        XCTAssertNil(profile?.activationConfigurationURL)
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.hermes/plugins/ping_island")
        XCTAssertTrue(profile?.reinstallDescriptionFormat.contains("插件目录") == true)
    }

    func testHermesManagedPluginDirectoryIncludesObservedHookRegistrations() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)
        let pluginYAML = try XCTUnwrap(files["plugin.yaml"])
        let pluginSource = try XCTUnwrap(files["__init__.py"])

        XCTAssertTrue(pluginYAML.contains("name: ping_island"))
        XCTAssertTrue(pluginYAML.contains("provides_hooks:"))
        XCTAssertTrue(pluginYAML.contains("- on_session_finalize"))
        XCTAssertTrue(pluginYAML.contains("- on_session_reset"))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_start\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"pre_llm_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"pre_tool_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"post_tool_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"post_llm_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_end\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_finalize\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_reset\""))
        XCTAssertTrue(pluginSource.contains("BRIDGE_ARGS = json.loads("))
        XCTAssertTrue(pluginSource.contains("hook_event_name=\"UserPromptSubmit\""))
        XCTAssertTrue(pluginSource.contains("hook_event_name=\"Stop\""))
        XCTAssertTrue(pluginSource.contains("hook_event_name=\"SessionEnd\""))
        XCTAssertTrue(pluginSource.contains("\"hermes-plugin\""))
    }

    func testHermesRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "hermes-agent",
            explicitName: "Hermes Agent",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin",
            processName: "hermes"
        )

        XCTAssertEqual(profile?.id, "hermes")
        XCTAssertEqual(profile?.brand, .hermes)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )

        XCTAssertEqual(clientInfo.brand, .hermes)
        XCTAssertTrue(clientInfo.isHermesClient)
        XCTAssertTrue(clientInfo.prefersHookMessageAsLastMessageFallback)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .hermes)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .hermes)
    }

    func testHermesLastMessageFallsBackToHookMessageForPopupPreview() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )
        let session = SessionState(
            sessionId: "hermes-end",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: clientInfo,
            latestHookMessage: "Hermes finished the response and queued the next action summary.",
            phase: .ended
        )

        XCTAssertEqual(
            session.lastMessage,
            "Hermes finished the response and queued the next action summary."
        )
    }

    // MARK: - File Sync Exclusion

    func testHermesStopEventDoesNotTriggerFileSync() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )
        let stopEvent = HookEvent(
            sessionId: "hermes-20260414_172652_beca52a3",
            cwd: "/tmp/project",
            event: "Stop",
            status: "ended",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Hermes reply content"
        )

        XCTAssertFalse(
            stopEvent.shouldSyncFile,
            "Hermes sessions should not trigger Claude JSONL file sync"
        )
    }

    func testHermesNotificationEventDoesNotTriggerFileSync() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )
        let notificationEvent = HookEvent(
            sessionId: "hermes-20260414_172652_beca52a3",
            cwd: "/tmp/project",
            event: "Notification",
            status: "notification",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "assistant_message",
            message: "Hermes reply content"
        )

        XCTAssertFalse(
            notificationEvent.shouldSyncFile,
            "Hermes sessions should not trigger Claude JSONL file sync"
        )
    }

    func testHermesLastMessageNotOverriddenByConversationInfo() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )
        // Simulate a Hermes session where conversationInfo has stale/unrelated data
        var session = SessionState(
            sessionId: "hermes-fsync",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: clientInfo,
            latestHookMessage: "Hermes 的真实回复内容",
            phase: .ended
        )
        // If conversationInfo.lastMessage is nil, lastMessage should use compactHookMessage
        XCTAssertNil(session.conversationInfo.lastMessage)
        XCTAssertEqual(session.lastMessage, "Hermes 的真实回复内容")

        // If conversationInfo.lastMessage is set (e.g. from stale JSONL), it takes priority
        session.conversationInfo = ConversationInfo(
            summary: nil,
            lastMessage: "Unrelated Claude session content",
            lastMessageRole: "assistant",
            lastToolName: nil,
            firstUserMessage: nil,
            lastUserMessageDate: nil
        )
        XCTAssertEqual(
            session.lastMessage,
            "Unrelated Claude session content",
            "conversationInfo.lastMessage takes priority — the fix prevents this from being set for Hermes"
        )
    }

    // MARK: - Plugin Robustness

    func testHermesPluginAlwaysEmitsUserPromptSubmit() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)
        let source = try XCTUnwrap(files["__init__.py"])

        // The plugin should always emit UserPromptSubmit, even when the prompt
        // is not extractable, so Island tracks the session turn.
        XCTAssertTrue(
            source.contains("# Always emit UserPromptSubmit"),
            "Plugin should always emit UserPromptSubmit regardless of prompt extraction"
        )

        // User message extraction should try additional kwargs keys and
        // the official Hermes conversation_history fallback.
        for key in ["prompt", "input", "query", "text", "content", "conversation_history"] {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "_extract_user_message should try kwarg key '\(key)'"
            )
        }

        XCTAssertTrue(source.contains("def _emit_session_start(session_id, platform=None, model=None, message=None, cwd=None):"))
        XCTAssertTrue(source.contains("message=prompt,"))
        XCTAssertTrue(source.contains("cwd=cwd,"))
    }
}
