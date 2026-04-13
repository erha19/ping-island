import XCTest
@testable import Ping_Island

final class QwenCodeIntegrationTests: XCTestCase {
    func testQwenCodeManagedProfileUsesOfficialHooksSettings() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "qwen-code-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Qwen Code")
        XCTAssertEqual(profile?.brand, .qwen)
        XCTAssertNil(profile?.logoAssetName)
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.qwen/settings.json")
        XCTAssertTrue(profile?.alwaysVisibleInSettings == true)
    }

    func testQwenCodeRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "qwen-code",
            explicitName: "Qwen Code",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "qwen-code")
        XCTAssertEqual(profile?.brand, .qwen)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        XCTAssertEqual(clientInfo.brand, .qwen)
        XCTAssertTrue(clientInfo.isQwenCodeClient)
        XCTAssertTrue(clientInfo.prefersHookMessageAsLastMessageFallback)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .qwen)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .qwen)
    }

    func testQwenCodeLastMessageFallsBackToHookMessageForPopupPreview() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )
        let session = SessionState(
            sessionId: "qwen-stop",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: clientInfo,
            latestHookMessage: "Qwen Code finished the task and is ready for your next prompt.",
            phase: .ended
        )

        XCTAssertEqual(
            session.lastMessage,
            "Qwen Code finished the task and is ready for your next prompt."
        )
    }
}
