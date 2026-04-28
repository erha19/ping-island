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

    func testCmuxResolvesAsGhosttyBasedTerminal() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forTerminalProgram: "cmux"),
            "com.cmuxterm.app"
        )
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(forCommand: "/Applications/cmux.app/Contents/MacOS/cmux"),
            "com.cmuxterm.app"
        )
        XCTAssertEqual(
            TerminalAppRegistry.canonicalDisplayName(
                bundleIdentifier: "com.cmuxterm.app",
                program: nil
            ),
            "cmux"
        )
    }
}
