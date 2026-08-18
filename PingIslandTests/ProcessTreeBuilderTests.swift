import XCTest
@testable import Ping_Island

final class ProcessTreeBuilderTests: XCTestCase {
    func testFindInteractiveSSHCarrierMatchesRemoteHostHint() {
        let tree: [Int: Ping_Island.ProcessInfo] = [
            100: Ping_Island.ProcessInfo(pid: 100, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys001"),
            110: Ping_Island.ProcessInfo(pid: 110, ppid: 100, command: "/bin/zsh -l", tty: "ttys001"),
            120: Ping_Island.ProcessInfo(pid: 120, ppid: 110, command: "/usr/bin/ssh devbox", tty: "ttys001"),
            200: Ping_Island.ProcessInfo(pid: 200, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys002"),
            210: Ping_Island.ProcessInfo(pid: 210, ppid: 200, command: "/bin/zsh -l", tty: "ttys002"),
            220: Ping_Island.ProcessInfo(pid: 220, ppid: 210, command: "/usr/bin/ssh otherbox", tty: "ttys002")
        ]

        let match = ProcessTreeBuilder.shared.findInteractiveSSHCarrier(
            remoteHostHint: "devbox.local",
            tree: tree
        )

        XCTAssertEqual(match?.sshPid, 120)
        XCTAssertEqual(match?.terminalPid, 100)
        XCTAssertEqual(match?.tty, "ttys001")
    }

    func testFindInteractiveSSHCarrierReturnsNilWhenHostMatchIsAmbiguous() {
        let tree: [Int: Ping_Island.ProcessInfo] = [
            100: Ping_Island.ProcessInfo(pid: 100, ppid: 1, command: "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", tty: "ttys001"),
            110: Ping_Island.ProcessInfo(pid: 110, ppid: 100, command: "/usr/bin/ssh devbox", tty: "ttys001"),
            200: Ping_Island.ProcessInfo(pid: 200, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys002"),
            210: Ping_Island.ProcessInfo(pid: 210, ppid: 200, command: "/usr/bin/ssh user@devbox", tty: "ttys002")
        ]

        let match = ProcessTreeBuilder.shared.findInteractiveSSHCarrier(
            remoteHostHint: "devbox",
            tree: tree
        )

        XCTAssertNil(match)
    }

    func testInteractiveSSHCarriersIgnoreXcodeSSHHelper() {
        let tree: [Int: Ping_Island.ProcessInfo] = [
            100: Ping_Island.ProcessInfo(
                pid: 100,
                ppid: 1,
                command: "/Applications/Xcode.app/Contents/SharedFrameworks/DVTSourceControl.framework/Versions/A/XPCServices/com.apple.dt.Xcode.sourcecontrol.SSHHelper.xpc/Contents/MacOS/com.apple.dt.Xcode.sourcecontrol.SSHHelper",
                tty: nil
            ),
            200: Ping_Island.ProcessInfo(
                pid: 200,
                ppid: 1,
                command: "/Users/example/Library/Application Support/iTerm2/iTermServer-3.6.9 socket",
                tty: "ttys003"
            ),
            210: Ping_Island.ProcessInfo(
                pid: 210,
                ppid: 200,
                command: "/usr/bin/ssh devbox",
                tty: "ttys003"
            )
        ]

        let carriers = ProcessTreeBuilder.shared.interactiveSSHCarriers(tree: tree)

        XCTAssertEqual(carriers.count, 1)
        XCTAssertEqual(carriers.first?.sshPid, 210)
    }

    /// Mirrors a Claude Code session in a VS Code integrated terminal, where the agent
    /// binary is installed inside the IDE's own extension directory.
    private var ideHostedTree: [Int: Ping_Island.ProcessInfo] {
        [
            853: Ping_Island.ProcessInfo(
                pid: 853,
                ppid: 1,
                command: "/Applications/Visual Studio Code.app/Contents/MacOS/Code",
                tty: nil
            ),
            67736: Ping_Island.ProcessInfo(
                pid: 67736,
                ppid: 853,
                command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                tty: nil
            ),
            68873: Ping_Island.ProcessInfo(
                pid: 68873,
                ppid: 67736,
                command: "/Users/u/.vscode/extensions/anthropic.claude-code-2.1.233-darwin-arm64/resources/native-binary/claude",
                tty: "ttys004"
            ),
            78391: Ping_Island.ProcessInfo(pid: 78391, ppid: 68873, command: "/bin/zsh", tty: "ttys004")
        ]
    }

    func testIDEApplicationIsAnAncestorOfItsHostedAgentSession() {
        XCTAssertTrue(ProcessTreeBuilder.shared.isAncestor(853, of: 68873, tree: ideHostedTree))
        XCTAssertTrue(ProcessTreeBuilder.shared.isAncestor(853, of: 78391, tree: ideHostedTree))
        XCTAssertTrue(ProcessTreeBuilder.shared.isAncestor(67736, of: 68873, tree: ideHostedTree))
    }

    /// Documents why ancestry is used instead of name matching: the agent's own path
    /// contains the IDE's name, so `findTerminalPid` stops on the agent process and
    /// never reaches the application pid that `NSWorkspace` reports as frontmost.
    func testNameBasedTerminalResolutionStopsShortOfTheIDEApplication() {
        let resolved = ProcessTreeBuilder.shared.findTerminalPid(forProcess: 68873, tree: ideHostedTree)

        XCTAssertEqual(resolved, 68873, "name matching resolves the agent itself")
        XCTAssertNotEqual(resolved, 853, "which is why it cannot be compared against the frontmost app pid")
    }

    func testTerminalApplicationIsAnAncestorOfItsShellSession() {
        let tree: [Int: Ping_Island.ProcessInfo] = [
            100: Ping_Island.ProcessInfo(
                pid: 100,
                ppid: 1,
                command: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                tty: nil
            ),
            110: Ping_Island.ProcessInfo(pid: 110, ppid: 100, command: "/bin/zsh -l", tty: "ttys001"),
            120: Ping_Island.ProcessInfo(pid: 120, ppid: 110, command: "/opt/homebrew/bin/claude", tty: "ttys001")
        ]

        XCTAssertTrue(ProcessTreeBuilder.shared.isAncestor(100, of: 120, tree: tree))
    }

    func testUnrelatedApplicationIsNotAnAncestor() {
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(999, of: 68873, tree: ideHostedTree))
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(68873, of: 853, tree: ideHostedTree), "ancestry is directional")
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(68873, of: 68873, tree: ideHostedTree), "a process is not its own ancestor")
    }

    func testAncestorWalkStopsOnBrokenAndCyclicChains() {
        let orphan: [Int: Ping_Island.ProcessInfo] = [
            500: Ping_Island.ProcessInfo(pid: 500, ppid: 499, command: "/bin/zsh", tty: nil)
        ]
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(853, of: 500, tree: orphan))

        let cycle: [Int: Ping_Island.ProcessInfo] = [
            600: Ping_Island.ProcessInfo(pid: 600, ppid: 601, command: "/bin/zsh", tty: nil),
            601: Ping_Island.ProcessInfo(pid: 601, ppid: 600, command: "/bin/zsh", tty: nil)
        ]
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(853, of: 600, tree: cycle))
    }

    func testRootPidsAreNeverTreatedAsAncestors() {
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(1, of: 68873, tree: ideHostedTree))
        XCTAssertFalse(ProcessTreeBuilder.shared.isAncestor(0, of: 68873, tree: ideHostedTree))
    }
}
