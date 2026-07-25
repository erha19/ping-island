import XCTest
@testable import Ping_Island

final class SessionLauncherWorkspaceRoutingTests: XCTestCase {
    func testUsableIDEWorkspacePathRejectsTopLevelCursorConfigDirectory() {
        let cursorHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .path

        XCTAssertNil(SessionLauncher.usableIDEWorkspacePath(cursorHome))
    }

    func testUsableIDEWorkspacePathRejectsTopLevelClaudeConfigDirectory() {
        let claudeHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .path

        XCTAssertNil(SessionLauncher.usableIDEWorkspacePath(claudeHome))
    }

    func testUsableIDEWorkspacePathKeepsOrdinaryProjectDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.path
        XCTAssertEqual(SessionLauncher.usableIDEWorkspacePath(path), path)
    }

    func testShouldFallBackToRecentIDEWindowWhenWorkspaceIsClientConfigDirectory() {
        let cursorHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .path

        XCTAssertTrue(
            SessionLauncher.shouldFallBackToRecentIDEWindow(forWorkspacePath: cursorHome)
        )
    }

    func testShouldNotFallBackToRecentIDEWindowForOrdinaryProjectDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertFalse(
            SessionLauncher.shouldFallBackToRecentIDEWindow(forWorkspacePath: tempRoot.path)
        )
    }
}
