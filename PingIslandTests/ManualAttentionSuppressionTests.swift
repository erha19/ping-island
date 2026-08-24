import XCTest
@testable import Ping_Island

final class ManualAttentionSuppressionTests: XCTestCase {
    func testFocusedSessionHostSuppressesAttentionPresentationWhenOptedIn() {
        XCTAssertTrue(NotchViewModel.shouldSuppressManualAttentionPresentation(
            suppressionEnabled: true,
            isSessionHostFocused: true,
            islandOwnsBlockingPrompt: false
        ))
    }

    func testUnfocusedSessionHostStillPresentsAttention() {
        XCTAssertFalse(NotchViewModel.shouldSuppressManualAttentionPresentation(
            suppressionEnabled: true,
            isSessionHostFocused: false,
            islandOwnsBlockingPrompt: false
        ))
    }

    func testSuppressionOptedOutAlwaysPresentsAttention() {
        for isSessionHostFocused in [true, false] {
            XCTAssertFalse(
                NotchViewModel.shouldSuppressManualAttentionPresentation(
                    suppressionEnabled: false,
                    isSessionHostFocused: isSessionHostFocused,
                    islandOwnsBlockingPrompt: false
                ),
                "suppression off must never withhold an approval"
            )
        }
    }

    /// The Island must never withhold a prompt it exclusively owns: the bridge is
    /// blocking on that decision, so hiding it stalls the agent with nothing on screen
    /// but a closed-notch indicator.
    func testPromptOwnedOnlyByTheIslandIsNeverWithheld() {
        XCTAssertFalse(
            NotchViewModel.shouldSuppressManualAttentionPresentation(
                suppressionEnabled: true,
                isSessionHostFocused: true,
                islandOwnsBlockingPrompt: true
            ),
            "a blocking prompt with no copy in the host must always surface"
        )
    }

    /// Ownership follows the routing setting: with prompts kept in the terminal the
    /// client renders its own approval, so the Island's copy is informational.
    func testOwnershipTracksPromptRoutingAndBridgeMetadata() {
        var routed = SessionState(sessionId: "routed", cwd: "/tmp/routed")
        routed.intervention = SessionIntervention(
            id: "intervention-approval",
            kind: .approval,
            title: "Claude needs approval",
            message: "Claude wants to run a command.",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )

        XCTAssertTrue(
            routed.islandOwnsBlockingPrompt(routePromptsToTerminal: false),
            "with routing off the Island holds the only copy"
        )
        XCTAssertFalse(
            routed.islandOwnsBlockingPrompt(routePromptsToTerminal: true),
            "with routing on the client shows its own prompt"
        )

        routed.suppressInAppPromptControls = true
        XCTAssertFalse(
            routed.islandOwnsBlockingPrompt(routePromptsToTerminal: false),
            "the bridge marked this envelope as already prompted in the client"
        )
    }

    /// A session with no pending decision owns nothing, so ordinary attention content
    /// stays suppressible.
    func testSessionWithoutAPendingDecisionOwnsNoPrompt() {
        let idle = SessionState(sessionId: "idle", cwd: "/tmp/idle")
        XCTAssertFalse(idle.islandOwnsBlockingPrompt(routePromptsToTerminal: false))
    }

    /// IDE hosts are the case this covers: an agent running in a VS Code-family
    /// terminal already shows its own approval UI, so the registry must treat those
    /// bundles as session hosts for focus resolution to reach the suppression check.
    func testIDEHostBundlesResolveAsSessionHosts() {
        for bundleIdentifier in [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf",
            "com.trae.app",
            "com.qoder.ide",
        ] {
            XCTAssertTrue(
                TerminalAppRegistry.isTerminalBundle(bundleIdentifier),
                "\(bundleIdentifier) should resolve as a session host"
            )
        }
    }

    /// Helper processes are what `NSWorkspace.frontmostApplication` reports for some
    /// IDEs, so they have to fold back onto their host bundle.
    func testIDEHelperBundlesFoldOntoTheirHost() {
        XCTAssertEqual(
            TerminalAppRegistry.normalizedHostBundleIdentifier(for: "com.microsoft.VSCode.helper"),
            "com.microsoft.VSCode"
        )
        XCTAssertTrue(TerminalAppRegistry.isTerminalBundle("com.microsoft.VSCode.helper"))
    }

    private func makeSession(clientInfo: SessionClientInfo) -> SessionState {
        var session = SessionState(sessionId: "suppression-session", cwd: "/tmp/suppression-session")
        session.clientInfo = clientInfo
        return session
    }

    func testUnrelatedAppIsNotTreatedAsASessionHost() {
        XCTAssertFalse(TerminalAppRegistry.isTerminalBundle("com.apple.Safari"))
        XCTAssertFalse(TerminalAppRegistry.isTerminalBundle("com.spotify.client"))
    }

    /// The case that matters most in practice: an agent running as an IDE extension
    /// reports no pid, so the host has to be recognised from the bundle identifier the
    /// session already carries.
    func testRecordedIDEHostMatchesFrontmostWithoutAPid() {
        XCTAssertTrue(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.microsoft.VSCode",
            frontmostBundleIdentifier: "com.microsoft.VSCode"
        ))
    }

    func testHostMatchIsCaseInsensitiveAndTrimmed() {
        XCTAssertTrue(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "  com.microsoft.vscode  ",
            frontmostBundleIdentifier: "com.microsoft.VSCode"
        ))
    }

    /// Some IDEs report a helper process as frontmost, so helpers must fold onto their
    /// host before the comparison.
    func testFrontmostHelperBundleMatchesRecordedHost() {
        XCTAssertTrue(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.microsoft.VSCode",
            frontmostBundleIdentifier: "com.microsoft.VSCode.helper"
        ))
    }

    func testDifferentHostDoesNotMatch() {
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.microsoft.VSCode",
            frontmostBundleIdentifier: "com.mitchellh.ghostty"
        ))
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.microsoft.VSCode",
            frontmostBundleIdentifier: "com.apple.Safari"
        ))
    }

    /// App-server clients record `bundleIdentifier` rather than
    /// `terminalBundleIdentifier`, so host resolution has to read both.
    func testHostFallsBackToBundleIdentifierWhenNoTerminalIsRecorded() {
        var info = SessionClientInfo(kind: .claudeCode)
        info.bundleIdentifier = "com.openai.codex"
        XCTAssertEqual(info.hostBundleIdentifier, "com.openai.codex")

        info.terminalBundleIdentifier = "com.microsoft.VSCode"
        XCTAssertEqual(
            info.hostBundleIdentifier,
            "com.microsoft.VSCode",
            "a recorded terminal host wins over the client bundle"
        )
    }

    /// If the Island itself is frontmost the user is looking at the Island, which is when
    /// an approval must be shown rather than withheld.
    func testIslandsOwnBundleIsNeverASessionHost() {
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.wudanwu.PingIsland",
            frontmostBundleIdentifier: "com.wudanwu.PingIsland"
        ))
    }

    /// An unrecognised app must not qualify as a host even when it is frontmost.
    func testUnrecognisedHostNeverMatchesEvenWhenFrontmost() {
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.apple.Safari",
            frontmostBundleIdentifier: "com.apple.Safari"
        ))
    }

    /// Completion panels are the fourth surface governed by the same setting, and they
    /// have their own presentability gate rather than sharing the attention path.
    func testCompletionNotificationIsSuppressedOnlyWhenSettingIsOnAndHostRecorded() {
        var hosted = SessionClientInfo(kind: .claudeCode)
        hosted.terminalBundleIdentifier = "com.microsoft.VSCode"

        var unhosted = SessionClientInfo(kind: .claudeCode)
        unhosted.terminalBundleIdentifier = nil

        /// Setting off must never withhold a completion panel, whatever the host is.
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldSuppressForFocusedHost(
            session: makeSession(clientInfo: hosted),
            suppressionEnabled: false
        ))

        /// A session with no recorded host cannot be judged focused, so it still shows.
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldSuppressForFocusedHost(
            session: makeSession(clientInfo: unhosted),
            suppressionEnabled: true
        ))
    }

    /// A session with no recorded host must not be treated as focused, so an approval is
    /// surfaced rather than silently withheld.
    func testMissingOrEmptyIdentifiersNeverMatch() {
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: nil,
            frontmostBundleIdentifier: "com.microsoft.VSCode"
        ))
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "com.microsoft.VSCode",
            frontmostBundleIdentifier: nil
        ))
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: "   ",
            frontmostBundleIdentifier: "com.microsoft.VSCode"
        ))
        XCTAssertFalse(TerminalVisibilityDetector.hostBundleMatchesFrontmost(
            hostBundleIdentifier: nil,
            frontmostBundleIdentifier: nil
        ))
    }
}
