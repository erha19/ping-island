import XCTest
@testable import Ping_Island

final class GeminiIntegrationTests: XCTestCase {
    func testGeminiManagedProfileUsesBundledOfficialLogo() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "gemini-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Gemini CLI")
        XCTAssertEqual(profile?.brand, .gemini)
        XCTAssertEqual(profile?.logoAssetName, "GeminiLogo")
        XCTAssertEqual(profile?.prefersBundledLogoOverAppIcon, true)
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.gemini/settings.json")
    }

    func testGeminiRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .gemini,
            explicitKind: "gemini",
            explicitName: "Gemini CLI",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Gemini CLI",
            threadSource: "gemini-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "gemini")
        XCTAssertEqual(profile?.brand, .gemini)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "gemini",
            name: "Gemini CLI",
            origin: "cli",
            originator: "Gemini CLI",
            threadSource: "gemini-hooks"
        )

        XCTAssertEqual(clientInfo.brand, .gemini)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .gemini), .gemini)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .gemini), .gemini)
        XCTAssertEqual(clientInfo.badgeLabel(for: .gemini), "Gemini CLI")
    }
}
