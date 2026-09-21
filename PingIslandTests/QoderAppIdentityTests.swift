import XCTest
@testable import Ping_Island

final class QoderAppIdentityTests: XCTestCase {
    func testConcreteAppEvidenceOverridesSharedCLIHookLabels() throws {
        for evidence in ["bundle", "terminal-bundle", "process"] {
            let stale = SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                bundleIdentifier: evidence == "bundle" ? "com.qoder.app" : nil,
                launchURL: "qoder://file/tmp/example-project",
                origin: "cli",
                originator: "Qoder",
                terminalBundleIdentifier: evidence == "terminal-bundle" ? "com.qoder.app" : nil,
                processName: evidence == "process" ? "/Applications/Qoder.app/Contents/MacOS/Qoder" : nil
            )

            XCTAssertTrue(stale.isQoderDesktopAppClient, evidence)
            XCTAssertFalse(stale.isQoderCLIClient, evidence)
            XCTAssertEqual(stale.badgeLabel(for: .claude), "Qoder", evidence)
            let normalized = stale.normalizedForClaudeRouting()
            XCTAssertEqual(normalized.profileID, "qoder-app", evidence)
            XCTAssertEqual(normalized.name, "Qoder", evidence)
            XCTAssertEqual(normalized.bundleIdentifier, "com.qoder.app", evidence)
            XCTAssertEqual(normalized.origin, "desktop", evidence)
            XCTAssertNil(normalized.launchURL, evidence)
            XCTAssertEqual(normalized.normalizedForClaudeRouting(), normalized, evidence)

            let profile = ClientProfileRegistry.matchRuntimeProfile(
                provider: .claude,
                explicitKind: stale.profileID,
                explicitName: stale.name,
                explicitBundleIdentifier: stale.bundleIdentifier,
                terminalBundleIdentifier: stale.terminalBundleIdentifier,
                origin: stale.origin,
                originator: stale.originator,
                threadSource: "qoder-cli-hooks",
                processName: stale.processName
            )
            XCTAssertEqual(try XCTUnwrap(profile).id, "qoder-app", evidence)
        }
    }

    func testDesktopProductsUseTheirNameAndApplicationRouting() {
        for (profileID, name, bundle) in [
            ("qoder-app", "Qoder", "com.qoder.app"),
            ("qoder-cn-app", "Qoder CN", "com.aliyun.lingma.ide")
        ] {
            let client = SessionClientInfo(
                kind: .qoder, profileID: profileID, name: "Qoder CLI", origin: "cli",
                terminalBundleIdentifier: bundle
            )
            XCTAssertEqual(client.badgeLabel(for: .claude), name)
            XCTAssertEqual(client.assistantLabel(for: .claude), name)
            XCTAssertEqual(client.interactionLabel(for: .claude), name)
            XCTAssertNil(client.ideHostProfile)
            XCTAssertNil(client.ideHostBadgeLabel(for: .claude))
            XCTAssertNil(client.terminalSourceDisplayName)
            XCTAssertFalse(client.isHostedInIDE)
            XCTAssertFalse(client.isQoderCLIClient)
            XCTAssertFalse(client.isQoderNotifyOnlyIDEClient)
            XCTAssertTrue(client.supportsCustomAskUserQuestionInput)
            XCTAssertTrue(client.prefersAnsweredQuestionFollowupAction)
            XCTAssertTrue(client.prefersAppNavigation)
            XCTAssertTrue(SessionLauncher.shouldPrioritizeClientApplicationFallback(for: client))
            XCTAssertEqual(SessionLauncher.clientApplicationBundleIdentifiers(for: client), [bundle])
            XCTAssertTrue(SessionLauncher.allowsAppFallback(provider: .claude, clientInfo: client))
            XCTAssertFalse(SessionLauncher.isTerminalHostedQoderCLISession(provider: .claude, clientInfo: client))
            XCTAssertFalse(SessionLauncher.isQoderCLIHostedInIDE(provider: .claude, clientInfo: client))
        }
        XCTAssertNil(ClientProfileRegistry.ideExtensionProfile(bundleIdentifier: "com.qoder.app", appName: "Qoder"))
    }

    func testCNBundleAloneDoesNotInventBlockingAppIdentity() {
        let ide = SessionClientInfo(
            kind: .qoder, profileID: "qoder-cn", name: "Qoder CN IDE",
            terminalBundleIdentifier: "com.aliyun.lingma.ide",
            processName: "/Applications/Qoder CN.app/Contents/MacOS/Electron"
        ).normalizedForClaudeRouting()
        XCTAssertEqual(ide.profileID, "qoder-cn")
        XCTAssertEqual(ide.badgeLabel(for: .claude), "Qoder CN")
        XCTAssertFalse(ide.isQoderDesktopAppClient)
        XCTAssertTrue(ide.isQoderNotifyOnlyIDEClient)
        XCTAssertEqual(ide.ideHostProfile?.id, "qoder-cn-extension")
    }

    func testActualCLIInTerminalOrIDEPreservesCLIIdentity() {
        for (profileID, name, bundle, process) in [
            ("qoder-cli", "Qoder CLI", "com.googlecode.iterm2", "/tmp/example-home/.qoder/bin/qodercli/qodercli-1.1.58"),
            ("qoder-cli", "Qoder CLI", "com.qoder.ide", "/tmp/example-home/.local/bin/qodercli"),
            ("qoder-cn-cli", "Qoder CN CLI", "com.aliyun.lingma.ide", "/tmp/example-home/.local/bin/qoderclicn")
        ] {
            let client = SessionClientInfo(
                kind: .qoder, profileID: profileID, name: name, origin: "cli",
                terminalBundleIdentifier: bundle, terminalTTY: "/dev/ttys099", processName: process
            ).normalizedForClaudeRouting()
            XCTAssertEqual(client.profileID, profileID)
            XCTAssertEqual(client.badgeLabel(for: .claude), name)
            XCTAssertFalse(client.isQoderDesktopAppClient)
            XCTAssertTrue(client.isQoderCLIClient)
            XCTAssertFalse(client.isQoderNotifyOnlyIDEClient)
            XCTAssertFalse(SessionLauncher.shouldPrioritizeClientApplicationFallback(for: client))
            XCTAssertTrue(SessionLauncher.isTerminalHostedQoderCLISession(provider: .claude, clientInfo: client))
            XCTAssertFalse(SessionLauncher.allowsAppFallback(provider: .claude, clientInfo: client))
        }
    }

    func testConcreteCLIProcessOutranksInheritedAppBundleAndCachedProfile() {
        for (process, expectedProfile, expectedName) in [
            ("/tmp/example-home/.qoder/bin/qodercli/qodercli-1.1.58", "qoder-cli", "Qoder CLI"),
            ("/tmp/example-home/.local/bin/qoderclicn", "qoder-cn-cli", "Qoder CN CLI")
        ] {
            let client = SessionClientInfo(
                kind: .qoder, profileID: "qoder-app", name: "Qoder",
                bundleIdentifier: "com.qoder.app", terminalBundleIdentifier: "com.qoder.app",
                processName: process
            )
            XCTAssertFalse(client.isQoderDesktopAppClient)
            XCTAssertTrue(client.isQoderCLIClient)
            XCTAssertFalse(SessionLauncher.allowsAppFallback(provider: .claude, clientInfo: client))
            let profile = ClientProfileRegistry.matchRuntimeProfile(
                provider: .claude, explicitKind: client.profileID, explicitName: client.name,
                explicitBundleIdentifier: client.bundleIdentifier,
                terminalBundleIdentifier: client.terminalBundleIdentifier,
                origin: client.origin, originator: client.originator, threadSource: nil,
                processName: client.processName
            )
            XCTAssertEqual(profile?.id, expectedProfile)
            let normalized = client.normalizedForClaudeRouting()
            XCTAssertEqual(normalized.profileID, expectedProfile)
            XCTAssertEqual(normalized.badgeLabel(for: .claude), expectedName)
            XCTAssertNil(normalized.bundleIdentifier)
            XCTAssertNil(normalized.terminalBundleIdentifier)
            XCTAssertFalse(normalized.isQoderDesktopAppClient)
        }
    }
}
