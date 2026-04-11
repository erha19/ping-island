import XCTest
@testable import Ping_Island

final class RuntimeSessionRegistryTests: XCTestCase {
    func testUpsertPersistsAndReloadsRecords() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDirectory.appendingPathComponent("runtime-sessions.json", isDirectory: false)

        let registry = RuntimeSessionRegistry(fileURL: fileURL)
        let handle = SessionRuntimeHandle(
            sessionID: "ses_test_1",
            provider: .claude,
            cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 1234),
            resumeToken: "resume-1",
            runtimeIdentifier: "native-claude",
            sessionFilePath: "/tmp/project/session.jsonl"
        )

        await registry.upsert(handle: handle, updatedAt: Date(timeIntervalSince1970: 5678))

        let reloadedRegistry = RuntimeSessionRegistry(fileURL: fileURL)
        let record = await reloadedRegistry.record(for: "ses_test_1")

        XCTAssertEqual(record?.sessionID, "ses_test_1")
        XCTAssertEqual(record?.provider, .claude)
        XCTAssertEqual(record?.cwd, "/tmp/project")
        XCTAssertEqual(record?.resumeToken, "resume-1")
        XCTAssertEqual(record?.runtimeIdentifier, "native-claude")
    }

    func testRemoveDeletesPersistedRecord() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDirectory.appendingPathComponent("runtime-sessions.json", isDirectory: false)

        let registry = RuntimeSessionRegistry(fileURL: fileURL)
        let handle = SessionRuntimeHandle(
            sessionID: "ses_test_2",
            provider: .codex,
            cwd: "/tmp/project",
            createdAt: Date(),
            resumeToken: nil,
            runtimeIdentifier: "native-codex",
            sessionFilePath: nil
        )

        await registry.upsert(handle: handle)
        await registry.remove(sessionID: "ses_test_2")

        let reloadedRegistry = RuntimeSessionRegistry(fileURL: fileURL)
        let record = await reloadedRegistry.record(for: "ses_test_2")

        XCTAssertNil(record)
    }
}
