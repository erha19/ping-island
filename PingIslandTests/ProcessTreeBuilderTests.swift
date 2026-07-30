import XCTest
@testable import NotchCode

final class ProcessTreeBuilderTests: XCTestCase {
    func testFindInteractiveSSHCarrierMatchesRemoteHostHint() {
        let tree: [Int: NotchCode.ProcessInfo] = [
            100: NotchCode.ProcessInfo(pid: 100, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys001"),
            110: NotchCode.ProcessInfo(pid: 110, ppid: 100, command: "/bin/zsh -l", tty: "ttys001"),
            120: NotchCode.ProcessInfo(pid: 120, ppid: 110, command: "/usr/bin/ssh devbox", tty: "ttys001"),
            200: NotchCode.ProcessInfo(pid: 200, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys002"),
            210: NotchCode.ProcessInfo(pid: 210, ppid: 200, command: "/bin/zsh -l", tty: "ttys002"),
            220: NotchCode.ProcessInfo(pid: 220, ppid: 210, command: "/usr/bin/ssh otherbox", tty: "ttys002")
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
        let tree: [Int: NotchCode.ProcessInfo] = [
            100: NotchCode.ProcessInfo(pid: 100, ppid: 1, command: "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", tty: "ttys001"),
            110: NotchCode.ProcessInfo(pid: 110, ppid: 100, command: "/usr/bin/ssh devbox", tty: "ttys001"),
            200: NotchCode.ProcessInfo(pid: 200, ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: "ttys002"),
            210: NotchCode.ProcessInfo(pid: 210, ppid: 200, command: "/usr/bin/ssh user@devbox", tty: "ttys002")
        ]

        let match = ProcessTreeBuilder.shared.findInteractiveSSHCarrier(
            remoteHostHint: "devbox",
            tree: tree
        )

        XCTAssertNil(match)
    }

    func testInteractiveSSHCarriersIgnoreXcodeSSHHelper() {
        let tree: [Int: NotchCode.ProcessInfo] = [
            100: NotchCode.ProcessInfo(
                pid: 100,
                ppid: 1,
                command: "/Applications/Xcode.app/Contents/SharedFrameworks/DVTSourceControl.framework/Versions/A/XPCServices/com.apple.dt.Xcode.sourcecontrol.SSHHelper.xpc/Contents/MacOS/com.apple.dt.Xcode.sourcecontrol.SSHHelper",
                tty: nil
            ),
            200: NotchCode.ProcessInfo(
                pid: 200,
                ppid: 1,
                command: "/Users/example/Library/Application Support/iTerm2/iTermServer-3.6.9 socket",
                tty: "ttys003"
            ),
            210: NotchCode.ProcessInfo(
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
}
