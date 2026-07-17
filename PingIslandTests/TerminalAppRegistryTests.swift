import XCTest
@testable import Ping_Island

final class TerminalAppRegistryTests: XCTestCase {
    func testDoesNotInferCodexProgramAsTerminalHostBundle() {
        XCTAssertNil(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "codex")
        )
        XCTAssertNil(
            TerminalAppRegistry.canonicalDisplayName(
                bundleIdentifier: nil,
                program: "codex"
            )
        )
    }

    func testExplicitCodexBundleStillResolvesCanonicalDisplayName() {
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(
                bundleIdentifier: "com.openai.codex",
                program: nil
            ),
            "Codex"
        )
    }

    func testInfersITermBundleIdentifierFromHelperCommand() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(
                forCommand: "/Users/example/Library/Application Support/iTerm2/iTermServer-3.6.9 socket"
            ),
            "com.googlecode.iterm2"
        )
    }

    func testQoderCNDesktopIsRegisteredAsIDEHost() {
        XCTAssertTrue(TerminalAppRegistry.isIDEBundle("com.aliyun.lingma.ide"))
        XCTAssertEqual(
            TerminalAppRegistry.normalizedHostBundleIdentifier(for: "com.aliyun.lingma.ide.helper"),
            "com.aliyun.lingma.ide"
        )
    }
}
