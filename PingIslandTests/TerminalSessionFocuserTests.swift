import XCTest
@testable import Ping_Island

final class TerminalSessionFocuserTests: XCTestCase {
    func testITermSelectionScriptUsesSessionIdentifierAlongsideTTY() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: "ttys194",
            sessionIdentifier: "w6t0p0:AF9E91C7-A845-4A30-8A18-54C51B61B1B4"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set sessionTTY to tty of theSession"))
        XCTAssertTrue(script.contains("ttys194"))
        XCTAssertTrue(script.contains("AF9E91C7-A845-4A30-8A18-54C51B61B1B4"))
        XCTAssertLessThan(
            script.range(of: "AF9E91C7-A845-4A30-8A18-54C51B61B1B4")!.lowerBound,
            script.range(of: "set sessionTTY to tty of theSession")!.lowerBound
        )
    }

    func testITermSelectionScriptFallsBackToSessionIdentifierWhenTTYMissing() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: nil,
            sessionIdentifier: "w6t0p0:AF9E91C7-A845-4A30-8A18-54C51B61B1B4"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("set sessionTTY to tty of theSession"))
        XCTAssertTrue(script.contains("AF9E91C7-A845-4A30-8A18-54C51B61B1B4"))
    }

    func testITermSelectionScriptCanUniquelyMatchRemoteHostTitleHint() {
        let lines = TerminalSessionFocuser.iTermSelectionScriptLinesForTesting(
            tty: nil,
            sessionIdentifier: nil,
            titleHint: "devbox"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetHint to \"devbox\""))
        XCTAssertTrue(script.contains("set matchingSessionIDs to {}"))
        XCTAssertTrue(script.contains("if (count of matchingSessionIDs) is not 1 then"))
    }

    func testGhosttySelectionScriptOnlyUsesUnambiguousWorkspaceMatches() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("if (count of exactMatches) is 1 then"))
        XCTAssertTrue(script.contains("if (count of pathMatches) is 1 then"))
        XCTAssertTrue(script.contains("if (count of nameMatches) is 1 then"))
    }

    func testGhosttySelectionScriptFallsBackToRemoteHostTitleHint() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: nil,
            titleHint: "devbox"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set remoteTitleHint to \"devbox\""))
        XCTAssertTrue(script.contains("set titleMatches to every terminal whose name contains remoteTitleHint"))
    }

    func testGhosttySelectionScriptCanTargetCmuxBundle() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            workspacePath: "/tmp/demo",
            bundleIdentifier: "com.cmuxterm.app"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertEqual(lines.first, "tell application id \"com.cmuxterm.app\"")
        XCTAssertFalse(script.contains("tell application id \"com.mitchellh.ghostty\""))
    }

    func testGhosttyFrontmostTerminalSnapshotScriptTargetsFocusedTerminal() {
        let lines = TerminalSessionFocuser.ghosttyFrontmostTerminalSnapshotScriptLines()
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetWindow to front window"))
        XCTAssertTrue(script.contains("set targetTab to selected tab of targetWindow"))
        XCTAssertTrue(script.contains("set targetTerminal to focused terminal of targetTab"))
        XCTAssertTrue(script.contains("return targetTerminalID & linefeed & targetWorkingDirectory & linefeed & targetTerminalName"))
    }

    func testGhosttyFrontmostTerminalSnapshotScriptCanTargetCmuxBundle() {
        let lines = TerminalSessionFocuser.ghosttyFrontmostTerminalSnapshotScriptLines(
            bundleIdentifier: "com.cmuxterm.app"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertEqual(lines.first, "tell application id \"com.cmuxterm.app\"")
        XCTAssertTrue(script.contains("set targetTerminal to focused terminal of targetTab"))
        XCTAssertFalse(script.contains("tell application id \"com.mitchellh.ghostty\""))
    }

    func testParseGhosttyTerminalSnapshotReadsIdentifierWorkingDirectoryAndTitle() {
        let snapshot = TerminalSessionFocuser.parseGhosttyTerminalSnapshot(
            "ABC-123\n/Users/example/project\nclaude session"
        )

        XCTAssertEqual(
            snapshot,
            TerminalSessionFocuser.GhosttyTerminalSnapshot(
                terminalSessionIdentifier: "ABC-123",
                workingDirectory: "/Users/example/project",
                title: "claude session"
            )
        )
    }

    func testGhosttyWorkingDirectoryMatchesStandardizedPathsAndSubdirectories() {
        XCTAssertTrue(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/project/subdir",
                workspacePath: "/Users/example/project"
            )
        )
        XCTAssertTrue(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/project/../project",
                workspacePath: "/Users/example/project"
            )
        )
        XCTAssertFalse(
            TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                snapshotWorkingDirectory: "/Users/example/other",
                workspacePath: "/Users/example/project"
            )
        )
    }

    func testNormalizedGhosttyTerminalIdentifierAcceptsUUIDAndUppercasesIt() {
        XCTAssertEqual(
            TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(
                "65a2028f-a93c-48e0-b46a-3f4c20c94b81"
            ),
            "65A2028F-A93C-48E0-B46A-3F4C20C94B81"
        )
    }

    func testNormalizedGhosttyTerminalIdentifierRejectsGenericTermSessionID() {
        XCTAssertNil(
            TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier("ghostty-terminal-1")
        )
    }
}
