import XCTest
@testable import Ping_Island

final class ClientProfileIconTests: XCTestCase {
    func testManagedHookProfilesUseBundledLogosForSettings() throws {
        let expectedAssets = [
            "claude-hooks": "ClaudeLogo",
            "codex-hooks": "CodexLogo",
            "gemini-hooks": "GeminiLogo",
            "codebuddy-hooks": "CodeBuddyLogo",
            "cursor-hooks": "CursorLogo",
            "qoder-hooks": "QoderLogo",
            "qoderwork-hooks": "QoderLogo",
            "copilot-hooks": "CopilotLogo",
            "opencode-hooks": "OpenCodeLogo",
        ]

        for (profileID, assetName) in expectedAssets {
            let profile = try XCTUnwrap(
                ClientProfileRegistry.managedHookProfile(id: profileID),
                "Missing managed hook profile \(profileID)"
            )
            XCTAssertEqual(profile.logoAssetName, assetName)
            XCTAssertTrue(profile.prefersBundledLogoOverAppIcon)
        }
    }

    func testIDEExtensionProfilesUseBundledLogosForSettings() throws {
        let expectedAssets = [
            "vscode-extension": "VSCodeLogo",
            "cursor-extension": "CursorLogo",
            "codebuddy-extension": "CodeBuddyLogo",
            "qoder-extension": "QoderLogo",
            "qoderwork-extension": "QoderLogo",
        ]

        for (profileID, assetName) in expectedAssets {
            let profile = try XCTUnwrap(
                ClientProfileRegistry.ideExtensionProfile(id: profileID),
                "Missing IDE extension profile \(profileID)"
            )
            XCTAssertEqual(profile.logoAssetName, assetName)
            XCTAssertTrue(profile.prefersBundledLogoOverAppIcon)
        }
    }
}
