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
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.kimi/config.toml")
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
}
