import XCTest
@testable import Ping_Island

final class TOMLHookInstallerTests: XCTestCase {
    func testTOMLHookParserExtractsHooks() {
        let toml = """
        default_model = "kimi-for-coding"
        theme = "dark"

        [[hooks]]
        event = "SessionStart"
        command = "/Users/test/.ping-island/bin/ping-island-bridge --source kimi"
        matcher = ""
        timeout = 30

        [[hooks]]
        event = "PreToolUse"
        command = "/usr/local/bin/safety-check.sh"
        matcher = "Shell"
        timeout = 10
        """

        let segments = TOMLHookConfigParser.parse(toml)
        XCTAssertEqual(segments.count, 3)

        if case .text(let text) = segments[0] {
            XCTAssertTrue(text.contains("default_model"))
        } else {
            XCTFail("Expected text segment")
        }

        if case .hook(let entry) = segments[1] {
            XCTAssertEqual(entry.event, "SessionStart")
            XCTAssertTrue(entry.command.contains("ping-island-bridge"))
            XCTAssertTrue(TOMLHookConfigParser.islandManaged(entry))
        } else {
            XCTFail("Expected hook segment")
        }

        if case .hook(let entry) = segments[2] {
            XCTAssertEqual(entry.event, "PreToolUse")
            XCTAssertEqual(entry.command, "/usr/local/bin/safety-check.sh")
            XCTAssertFalse(TOMLHookConfigParser.islandManaged(entry))
        } else {
            XCTFail("Expected hook segment")
        }
    }

    func testTOMLHookParserHandlesEmptyFile() {
        let segments = TOMLHookConfigParser.parse("")
        XCTAssertEqual(segments.count, 1)
        if case .text(let text) = segments[0] {
            XCTAssertTrue(text.isEmpty)
        } else {
            XCTFail("Expected text segment")
        }
    }

    func testTOMLRebuildRemovesIslandManagedHooks() {
        let toml = """
        default_model = "kimi-for-coding"

        [[hooks]]
        event = "SessionStart"
        command = "/Users/test/.ping-island/bin/ping-island-bridge --source kimi"
        matcher = ""
        timeout = 30

        [[hooks]]
        event = "PreToolUse"
        command = "/usr/local/bin/safety-check.sh"
        matcher = "Shell"
        timeout = 10
        """

        let segments = TOMLHookConfigParser.parse(toml)
        let rebuilt = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [])

        XCTAssertFalse(rebuilt.contains("ping-island-bridge"))
        XCTAssertTrue(rebuilt.contains("safety-check.sh"))
        XCTAssertTrue(rebuilt.contains("default_model"))
    }

    func testTOMLRebuildAppendsNewHooks() {
        let toml = """
        default_model = "kimi-for-coding"
        """

        let segments = TOMLHookConfigParser.parse(toml)
        let newHook = TOMLHookConfigParser.TOMLHookEntry(
            event: "SessionStart",
            command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi",
            matcher: "",
            timeout: 30
        )
        let rebuilt = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [newHook])

        XCTAssertTrue(rebuilt.contains("[[hooks]]"))
        XCTAssertTrue(rebuilt.contains("event = \"SessionStart\""))
        XCTAssertTrue(rebuilt.contains("ping-island-bridge"))
        XCTAssertTrue(rebuilt.contains("default_model"))
    }

    func testTOMLRebuildReplacesOldIslandHooks() {
        let toml = """
        [[hooks]]
        event = "SessionStart"
        command = "/Users/test/.ping-island/bin/ping-island-bridge --source kimi"
        matcher = ""
        timeout = 30
        """

        let segments = TOMLHookConfigParser.parse(toml)
        let newHook = TOMLHookConfigParser.TOMLHookEntry(
            event: "SessionStart",
            command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi --client-name \"Kimi CLI\"",
            matcher: "",
            timeout: 86400
        )
        let rebuilt = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [newHook])

        // Should contain exactly one SessionStart hook with the new command
        let sessionStartMatches = rebuilt.components(separatedBy: "event = \"SessionStart\"").count - 1
        XCTAssertEqual(sessionStartMatches, 1)
        XCTAssertTrue(rebuilt.contains("timeout = 86400"))
        XCTAssertFalse(rebuilt.contains("timeout = 30"))
    }

    func testTOMLHookParserStripsInlineComments() {
        let toml = """
        [[hooks]]
        event = "SessionStart" # start hook
        command = "/Users/test/.ping-island/bin/ping-island-bridge"
        timeout = 30 # seconds
        """

        let segments = TOMLHookConfigParser.parse(toml)
        if case .hook(let entry) = segments.first(where: { if case .hook = $0 { return true } else { return false } }) {
            XCTAssertEqual(entry.event, "SessionStart")
            XCTAssertEqual(entry.command, "/Users/test/.ping-island/bin/ping-island-bridge")
            XCTAssertEqual(entry.timeout, 30)
        } else {
            XCTFail("Expected hook segment")
        }
    }

    func testTOMLHookParserPreservesNonHookContent() {
        let toml = """
        # User settings
        default_model = "kimi-for-coding"

        [providers.kimi]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.ping-island/bin/ping-island-bridge --source kimi"
        matcher = ""
        timeout = 30
        """

        let segments = TOMLHookConfigParser.parse(toml)
        let rebuilt = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [])

        XCTAssertTrue(rebuilt.contains("# User settings"))
        XCTAssertTrue(rebuilt.contains("[providers.kimi]"))
        XCTAssertTrue(rebuilt.contains("base_url"))
        XCTAssertFalse(rebuilt.contains("ping-island-bridge"))
    }

    /// Kimi's desktop app keeps provider credentials and model definitions in the same
    /// config.toml Island writes hooks into, so the merge must be strictly additive.
    func testTOMLRebuildPreservesKimiAppKernelConfiguration() {
        let existing = """
        default_model = "k2d6-agent"
        extra_skill_dirs = [ "/Users/test/Library/Application Support/kimi-desktop/daimon-share/daimon/skills" ]

        [thinking]
        enabled = true
        effort = "max"

        [loop_control]
        max_steps_per_turn = 100

        [providers.daimon-kimi-code]
        type = "kimi"
        api_key = "kernel-credential"
        base_url = "https://agent-gw.kimi.com/coding/v1"

        [models.k2d6-agent]
        provider = "daimon-kimi-code"
        model = "k2d6-agent"
        max_context_size = 262144
        capabilities = [ "thinking", "image_in", "video_in" ]
        """

        let managedHooks = [
            TOMLHookConfigParser.TOMLHookEntry(
                event: "Stop",
                command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi --client-kind kimi-app",
                matcher: "",
                timeout: nil
            )
        ]

        let rebuilt = TOMLHookConfigParser.rebuild(
            segments: TOMLHookConfigParser.parse(existing),
            newHooks: managedHooks
        )

        // Every kernel setting the app owns survives the merge.
        XCTAssertTrue(rebuilt.contains("default_model = \"k2d6-agent\""))
        XCTAssertTrue(rebuilt.contains("api_key = \"kernel-credential\""))
        XCTAssertTrue(rebuilt.contains("base_url = \"https://agent-gw.kimi.com/coding/v1\""))
        XCTAssertTrue(rebuilt.contains("[models.k2d6-agent]"))
        XCTAssertTrue(rebuilt.contains("max_steps_per_turn = 100"))
        XCTAssertTrue(rebuilt.contains("capabilities = [ \"thinking\", \"image_in\", \"video_in\" ]"))
        XCTAssertTrue(TOMLHookConfigParser.containsManagedHooks(rebuilt))
    }

    /// The guard reinstalls after every Kimi rewrite, so repeated installs must not
    /// stack duplicate managed blocks on top of each other.
    func testTOMLRebuildIsIdempotentForRepeatedManagedInstalls() {
        let managedHooks = [
            TOMLHookConfigParser.TOMLHookEntry(
                event: "Stop",
                command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi --client-kind kimi-app",
                matcher: "",
                timeout: nil
            ),
            TOMLHookConfigParser.TOMLHookEntry(
                event: "SessionStart",
                command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi --client-kind kimi-app",
                matcher: "",
                timeout: nil
            )
        ]

        var content = "default_model = \"k2d6-agent\"\n"
        for _ in 0..<3 {
            content = TOMLHookConfigParser.rebuild(
                segments: TOMLHookConfigParser.parse(content),
                newHooks: managedHooks
            )
        }

        XCTAssertEqual(content.components(separatedBy: "[[hooks]]").count - 1, managedHooks.count)
        XCTAssertTrue(content.contains("default_model = \"k2d6-agent\""))
    }

    /// A hook the user added by hand must outlive an Island install.
    func testTOMLRebuildKeepsUserAuthoredHooks() {
        let existing = """
        [[hooks]]
        event = "PreToolUse"
        command = "/usr/local/bin/safety-check.sh"
        matcher = "Shell"
        """

        let rebuilt = TOMLHookConfigParser.rebuild(
            segments: TOMLHookConfigParser.parse(existing),
            newHooks: [
                TOMLHookConfigParser.TOMLHookEntry(
                    event: "Stop",
                    command: "/Users/test/.ping-island/bin/ping-island-bridge --source kimi",
                    matcher: "",
                    timeout: nil
                )
            ]
        )

        XCTAssertTrue(rebuilt.contains("/usr/local/bin/safety-check.sh"))
        XCTAssertTrue(TOMLHookConfigParser.containsManagedHooks(rebuilt))
    }
}
