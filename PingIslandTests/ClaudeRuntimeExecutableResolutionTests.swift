import XCTest
@testable import NotchCode

final class ClaudeRuntimeExecutableResolutionTests: XCTestCase {
    func testResolveClaudeExecutablePrefersExplicitEnvironmentPath() {
        let resolved = ClaudeRuntime.resolveClaudeExecutable(
            environment: [
                "PING_CLAUDE_PATH": "/custom/bin/claude",
                "PATH": "/usr/bin:/bin"
            ],
            isExecutable: { path in
                path == "/custom/bin/claude" || path == "/usr/bin/claude"
            },
            shellResolver: { _ in
                XCTFail("shell resolver should not run when explicit path is executable")
                return nil
            }
        )

        XCTAssertEqual(resolved, "/custom/bin/claude")
    }

    func testResolveClaudeExecutableFindsClaudeInEnvironmentPath() {
        let resolved = ClaudeRuntime.resolveClaudeExecutable(
            environment: ["PATH": "/usr/bin:/opt/tools/bin"],
            isExecutable: { path in
                path == "/opt/tools/bin/claude"
            },
            shellResolver: { _ in
                XCTFail("shell resolver should not run when PATH already resolves claude")
                return nil
            }
        )

        XCTAssertEqual(resolved, "/opt/tools/bin/claude")
    }

    func testResolveClaudeExecutableFallsBackToShellProbe() {
        let resolved = ClaudeRuntime.resolveClaudeExecutable(
            environment: ["PATH": "/usr/bin:/bin"],
            isExecutable: { path in
                path == "/Users/test/.nvm/versions/node/v22/bin/claude"
            },
            shellResolver: { _ in
                "/Users/test/.nvm/versions/node/v22/bin/claude"
            }
        )

        XCTAssertEqual(resolved, "/Users/test/.nvm/versions/node/v22/bin/claude")
    }

    func testResolveClaudeExecutableRejectsNonExecutableShellResult() {
        let resolved = ClaudeRuntime.resolveClaudeExecutable(
            environment: ["PATH": "/usr/bin:/bin"],
            isExecutable: { _ in false },
            shellResolver: { _ in
                "/Users/test/.nvm/versions/node/v22/bin/claude"
            }
        )

        XCTAssertNil(resolved)
    }
}
