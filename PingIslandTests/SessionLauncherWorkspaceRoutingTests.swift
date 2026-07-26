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

    func testUsableIDEWorkspacePathRejectsFilesystemRoot() {
        XCTAssertNil(SessionLauncher.usableIDEWorkspacePath("/"))
    }

    func testShouldFallBackToRecentIDEWindowWhenWorkspaceIsClientConfigDirectory() {
        let cursorHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .path

        XCTAssertTrue(
            SessionLauncher.shouldFallBackToRecentIDEWindow(forWorkspacePath: cursorHome)
        )
    }

    func testShouldFallBackToRecentIDEWindowWhenWorkspaceIsFilesystemRoot() {
        XCTAssertTrue(
            SessionLauncher.shouldFallBackToRecentIDEWindow(forWorkspacePath: "/")
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

    func testIDEWorkspaceWindowMatchingRejectsFilesystemRoot() {
        XCTAssertEqual(
            SessionLauncher.ideWorkspaceWindowMatchScore(
                title: "SessionLauncher.swift — /Users/example/ping_island — Cursor",
                document: "file:///Users/example/ping_island/SessionLauncher.swift",
                workspacePath: "/",
                appName: "Cursor"
            ),
            0
        )
    }

    func testUsableIDEWorkspaceLaunchURLRejectsCursorFileRoot() {
        XCTAssertNil(SessionLauncher.usableIDEWorkspaceLaunchURL("cursor://file/"))
        XCTAssertNil(SessionLauncher.usableIDEWorkspaceLaunchURL("cursor://file"))
        XCTAssertNil(SessionLauncher.usableIDEWorkspaceLaunchURL("vscode://file/"))
    }

    func testUsableIDEWorkspaceLaunchURLKeepsOrdinaryProjectFileURL() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let launchURL = "cursor://file\(tempRoot.path)"
        XCTAssertEqual(SessionLauncher.usableIDEWorkspaceLaunchURL(launchURL), launchURL)
    }

    func testAppLaunchURLRejectsFilesystemRootWorkspace() {
        XCTAssertNil(
            SessionClientInfo.appLaunchURL(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                workspacePath: "/"
            )
        )
    }
}
