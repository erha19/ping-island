import XCTest
@testable import Ping_Island

final class KimiIntegrationTests: XCTestCase {
    func testKimiManagedProfileUsesBundledOfficialLogo() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "kimi-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Kimi CLI")
        XCTAssertEqual(profile?.brand, .kimi)
        XCTAssertEqual(profile?.logoAssetName, "KimiLogo")
        XCTAssertEqual(profile?.prefersBundledLogoOverAppIcon, true)
        XCTAssertEqual(
            profile?.configurationRelativePaths,
            [".kimi-code/config.toml", ".kimi/config.toml"]
        )
        XCTAssertEqual(
            profile?.primaryConfigurationURL.path,
            NSHomeDirectory() + "/.kimi-code/config.toml"
        )
        XCTAssertEqual(profile?.installationKind, .tomlHooks)
    }

    func testKimiRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .kimi,
            explicitKind: "kimi",
            explicitName: "Kimi CLI",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Kimi CLI",
            threadSource: "kimi-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "kimi")
        XCTAssertEqual(profile?.brand, .kimi)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "kimi",
            name: "Kimi CLI",
            origin: "cli",
            originator: "Kimi CLI",
            threadSource: "kimi-hooks"
        )

        XCTAssertEqual(clientInfo.brand, .kimi)
        XCTAssertTrue(clientInfo.isKimiClient)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .kimi), .kimi)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .kimi), .kimi)
        XCTAssertEqual(clientInfo.badgeLabel(for: .kimi), "Kimi CLI")
    }

    func testKimiProviderDisplayName() {
        XCTAssertEqual(SessionProvider.kimi.displayName, "Kimi")
    }

    func testKimiDefaultClientInfo() {
        let info = SessionClientInfo.default(for: .kimi)
        XCTAssertEqual(info.name, "Kimi CLI")
        XCTAssertEqual(info.origin, "cli")
        XCTAssertEqual(info.profileID, "kimi")
    }

    // MARK: - Kimi desktop app

    func testKimiAppManagedProfileTargetsBundledKernelConfig() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "kimi-app-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Kimi App")
        XCTAssertEqual(profile?.brand, .kimi)
        XCTAssertEqual(profile?.installationKind, .tomlHooks)
        XCTAssertEqual(profile?.bridgeSource, "kimi")
        XCTAssertEqual(
            profile?.configurationRelativePaths,
            [KimiAppHookPaths.kernelConfigurationRelativePath]
        )
        XCTAssertEqual(
            profile?.primaryConfigurationURL.path,
            NSHomeDirectory()
                + "/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/config.toml"
        )
        // Gated on Kimi.app being installed rather than always listed, unlike the CLI target.
        XCTAssertEqual(profile?.alwaysVisibleInSettings, false)
        XCTAssertEqual(profile?.localAppBundleIdentifiers, ["com.moonshot.kimichat"])
    }

    func testKimiAppProfileCoversSameEventsAsCLIProfile() {
        let cli = ClientProfileRegistry.managedHookProfile(id: "kimi-hooks")
        let app = ClientProfileRegistry.managedHookProfile(id: "kimi-app-hooks")

        XCTAssertEqual(
            app?.events.map(\.name),
            cli?.events.map(\.name)
        )
    }

    func testKimiAppProfileUsesDistinctConfigurationFromCLIProfile() {
        let cli = ClientProfileRegistry.managedHookProfile(id: "kimi-hooks")
        let app = ClientProfileRegistry.managedHookProfile(id: "kimi-app-hooks")

        XCTAssertNotEqual(cli?.primaryConfigurationURL, app?.primaryConfigurationURL)
        XCTAssertNotEqual(cli?.bridgeExtraArguments, app?.bridgeExtraArguments)
    }

    func testKimiAppRuntimeProfileOutranksCLIProfile() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .kimi,
            explicitKind: "kimi-app",
            explicitName: "Kimi App",
            explicitBundleIdentifier: "com.moonshot.kimichat",
            terminalBundleIdentifier: nil,
            origin: "desktop",
            originator: "Kimi App",
            threadSource: "kimi-app-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "kimi-app")
        XCTAssertEqual(profile?.brand, .kimi)
        XCTAssertEqual(profile?.displayName, "Kimi App")
    }

    func testKimiCLIRuntimeProfileStillWinsForTerminalSessions() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .kimi,
            explicitKind: "kimi",
            explicitName: "Kimi CLI",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Kimi CLI",
            threadSource: "kimi-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "kimi")
    }

    func testKimiAppSessionRendersDesktopBadge() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "kimi-app",
            name: "Kimi App",
            origin: "desktop",
            originator: "Kimi App",
            threadSource: "kimi-app-hooks"
        )

        XCTAssertEqual(clientInfo.brand, .kimi)
        XCTAssertTrue(clientInfo.isKimiClient)
        XCTAssertEqual(clientInfo.badgeLabel(for: .kimi), "Kimi App")
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .kimi), .kimi)
    }

    func testKimiAppHookGuardBacksOffWhenDormantAndVerifiesAfterRepair() {
        XCTAssertEqual(KimiAppHookGuard.interval(for: .dormant), .seconds(120))
        XCTAssertEqual(KimiAppHookGuard.interval(for: .intact), .seconds(30))
        XCTAssertEqual(KimiAppHookGuard.interval(for: .repaired), .seconds(5))
    }

    // MARK: - Kimi desktop app auxiliary sessions and titles

    func testKimiTitleGenerationSessionsAreFilteredOut() {
        // Kimi names the throwaway title-generation session `ctitle-`, real ones `conv-`.
        XCTAssertTrue(
            KimiAuxiliaryHookFilter.isTitleGenerationSession(
                provider: .kimi,
                sessionId: "ctitle-01a05576-66de-7905-a2ca-5041e733576d"
            )
        )
        XCTAssertFalse(
            KimiAuxiliaryHookFilter.isTitleGenerationSession(
                provider: .kimi,
                sessionId: "conv-f2f3305fde511e8fa7dcb4d8"
            )
        )
        // The CLI's own session ids must stay visible.
        XCTAssertFalse(
            KimiAuxiliaryHookFilter.isTitleGenerationSession(
                provider: .kimi,
                sessionId: "session_d4880dfd-aeb8-453e-ab5c-877d3b5d2c92"
            )
        )
    }

    func testTitleGenerationFilterIsScopedToKimi() {
        // Other providers must not be filtered by a Kimi-specific naming convention.
        XCTAssertFalse(
            KimiAuxiliaryHookFilter.isTitleGenerationSession(
                provider: .claude,
                sessionId: "ctitle-01a05576-66de-7905-a2ca-5041e733576d"
            )
        )
        XCTAssertFalse(
            KimiAuxiliaryHookFilter.isTitleGenerationSession(
                provider: .codex,
                sessionId: "ctitle-01a05576-66de-7905-a2ca-5041e733576d"
            )
        )
    }

    func testKimiPromptPayloadDecodesToPlainText() {
        XCTAssertEqual(
            HookSocketServer.plainTextFromPromptPayload(
                #"[{"text":"这个项目里面有啥东西啊？","type":"text"}]"#
            ),
            "这个项目里面有啥东西啊？"
        )
        // Multiple blocks join rather than dropping everything after the first.
        XCTAssertEqual(
            HookSocketServer.plainTextFromPromptPayload(
                #"[{"type":"text","text":"first"},{"type":"text","text":"second"}]"#
            ),
            "first\nsecond"
        )
        // An unexpected shape degrades to the raw string instead of vanishing.
        XCTAssertEqual(HookSocketServer.plainTextFromPromptPayload("plain prompt"), "plain prompt")
        XCTAssertNil(HookSocketServer.plainTextFromPromptPayload(nil))
        XCTAssertNil(HookSocketServer.plainTextFromPromptPayload(""))
    }

    func testKimiUserPromptSubmitResolvesMessageFromPromptMetadata() {
        let metadata = ["prompt": #"[{"text":"给我说说 open vibe island 是什么","type":"text"}]"#]

        XCTAssertEqual(
            HookSocketServer.resolvedBridgeMessage(
                eventType: "UserPromptSubmit",
                metadata: metadata,
                preview: nil,
                provider: .kimi
            ),
            "给我说说 open vibe island 是什么"
        )

        // Other providers keep their existing resolution order untouched.
        XCTAssertNil(
            HookSocketServer.resolvedBridgeMessage(
                eventType: "UserPromptSubmit",
                metadata: metadata,
                preview: nil,
                provider: .claude
            )
        )
    }

    // MARK: - Kimi desktop app session lifecycle

    private func kimiAppClientInfo(sessionFilePath: String? = nil) -> SessionClientInfo {
        SessionClientInfo(
            kind: .custom,
            profileID: "kimi-app",
            name: "Kimi App",
            origin: "desktop",
            originator: "Kimi App",
            threadSource: "kimi-app-hooks",
            sessionFilePath: sessionFilePath
        )
    }

    private func kimiCLIClientInfo() -> SessionClientInfo {
        SessionClientInfo(
            kind: .custom,
            profileID: "kimi",
            name: "Kimi CLI",
            origin: "cli",
            originator: "Kimi CLI",
            threadSource: "kimi-hooks"
        )
    }

    private func kimiHookEvent(
        sessionId: String,
        event: String,
        status: String,
        clientInfo: SessionClientInfo,
        message: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/Users/tester/Documents/kimi/tasks/2026-08-31/01-10-52-c34eee5f",
            event: event,
            status: status,
            provider: .kimi,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: message
        )
    }

    func testKimiAppClientIsDistinguishedFromTheCLI() {
        XCTAssertTrue(kimiAppClientInfo().isKimiAppClient)
        XCTAssertFalse(kimiCLIClientInfo().isKimiAppClient)
        // Both still share the kernel-level quirks flag.
        XCTAssertTrue(kimiAppClientInfo().isKimiClient)
        XCTAssertTrue(kimiCLIClientInfo().isKimiClient)
    }

    /// The app replays SessionStart for every conversation its kernel restores at
    /// launch. Read as `waitingForInput`, each replay marked a conversation as
    /// needing attention, which exempted it from the idle auto-archive forever.
    func testKimiAppSessionStartIsIdleRatherThanWaitingForInput() {
        let event = kimiHookEvent(
            sessionId: "conv-8d6",
            event: "SessionStart",
            status: "waiting_for_input",
            clientInfo: kimiAppClientInfo()
        )

        XCTAssertEqual(event.determinePhase(), .idle)
        XCTAssertFalse(event.determinePhase().needsAttention)
    }

    func testKimiAppStopStillWaitsForInput() {
        let event = kimiHookEvent(
            sessionId: "conv-8d6",
            event: "Stop",
            status: "waiting_for_input",
            clientInfo: kimiAppClientInfo()
        )

        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testKimiCLISessionStartKeepsWaitingForInput() {
        let event = kimiHookEvent(
            sessionId: "session_d4880dfd",
            event: "SessionStart",
            status: "waiting_for_input",
            clientInfo: kimiCLIClientInfo()
        )

        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testRestoredKimiAppConversationHidesFromPrimaryUI() {
        let session = SessionState(
            sessionId: "conv-8d6",
            cwd: "/Users/tester/Documents/kimi/tasks/2026-08-31/01-10-52-c34eee5f",
            provider: .kimi,
            clientInfo: kimiAppClientInfo(),
            ingress: .hookBridge,
            phase: .idle,
            lastActivity: Date()
        )

        XCTAssertTrue(session.isLikelyEmptyKimiAppHookSessionForUI)
        XCTAssertTrue(session.isLikelyEmptyRestoredHookSessionForUI)
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
    }

    /// Kimi ships no transcript, so `UserPromptSubmit` filling in `firstUserMessage`
    /// is the only evidence a conversation was ever used. That has to be enough to
    /// keep the row visible once the turn ends.
    func testPromptedKimiAppConversationStaysVisibleAfterItsTurnEnds() {
        let session = SessionState(
            sessionId: "conv-f2f",
            cwd: "/Users/tester/Documents/kimi/tasks/2026-08-31/01-36-57-ce394fd7",
            provider: .kimi,
            clientInfo: kimiAppClientInfo(),
            ingress: .hookBridge,
            phase: .waitingForInput,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "给我说说 open vibe island 是什么",
                lastUserMessageDate: Date()
            ),
            lastActivity: Date()
        )

        XCTAssertFalse(session.isLikelyEmptyKimiAppHookSessionForUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    /// A `Stop` is proof a turn ran, whatever the row ended up holding. Kimi ships no
    /// transcript, so the row can legitimately be textless - the phase, not the text,
    /// is what says the conversation was used.
    func testKimiAppConversationThatRanATurnStaysVisibleEvenWithoutRowText() {
        let session = SessionState(
            sessionId: "conv-9c0",
            cwd: "/Users/tester/Documents/kimi/tasks/2026-08-31/01-36-57-ce394fd7",
            provider: .kimi,
            clientInfo: kimiAppClientInfo(),
            ingress: .hookBridge,
            phase: .waitingForInput,
            lastActivity: Date()
        )

        XCTAssertFalse(session.isLikelyEmptyKimiAppHookSessionForUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    func testKimiCLISessionIsNotTreatedAsARestoredAppRow() {
        let session = SessionState(
            sessionId: "session_d4880dfd",
            cwd: "/Users/tester/Coding Project/demo",
            provider: .kimi,
            clientInfo: kimiCLIClientInfo(),
            ingress: .hookBridge,
            phase: .waitingForInput,
            lastActivity: Date()
        )

        XCTAssertFalse(session.isLikelyEmptyKimiAppHookSessionForUI)
        XCTAssertFalse(session.isLikelyEmptyRestoredHookSessionForUI)
    }

    func testKimiDesktopAwarenessTagIsStrippedFromDisplayText() {
        let raw = "<meta awareness=\"low\" timestamp=\"2026-08-31 03:36\" />\n给我说说open vibe island是什么"

        XCTAssertEqual(
            SessionTextSanitizer.sanitizedDisplayText(raw),
            "给我说说open vibe island是什么"
        )
        // A meta tag that is not a leading injected prefix stays put.
        XCTAssertEqual(
            SessionTextSanitizer.sanitizedDisplayText("compare <meta a=\"1\" /> tags"),
            "compare <meta a=\"1\" /> tags"
        )
    }
}
