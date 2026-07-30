import Foundation
import XCTest
@testable import NotchCode

final class SkillVaultWriterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-vault-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testValidateFolderName() {
        XCTAssertNil(SkillVaultWriter.validateFolderName("demo-skill"))
        XCTAssertNil(SkillVaultWriter.validateFolderName("a"))
        XCTAssertNotNil(SkillVaultWriter.validateFolderName(""))
        XCTAssertNotNil(SkillVaultWriter.validateFolderName("Demo"))
        XCTAssertNotNil(SkillVaultWriter.validateFolderName("../x"))
        XCTAssertNotNil(SkillVaultWriter.validateFolderName("has space"))
    }

    func testCreateWritesSkillMarkdownAndCatalogReadsIt() throws {
        let vault = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let path = try SkillVaultWriter.create(
            draft: SkillVaultDraft(
                folder_name: "new-skill",
                name: "New Skill",
                description: "Does a thing",
                body: "Follow these steps."
            ),
            vaultRoot: vault.path
        )

        let markdown = try String(
            contentsOf: URL(fileURLWithPath: path).appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        let frontMatter = LocalSkillCatalog.parseFrontMatter(from: markdown)
        XCTAssertEqual(frontMatter.name, "New Skill")
        XCTAssertEqual(frontMatter.description, "Does a thing")
        XCTAssertEqual(SkillVaultWriter.readBody(fromMarkdown: markdown), "Follow these steps.")

        let entries = SkillVaultCatalog.listEntries(
            vaultRoot: vault.path,
            manualRoots: [],
            profiles: [],
            homeDirectory: tempRoot,
            useCounts: ["new-skill": 4]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "New Skill")
        XCTAssertEqual(entries[0].body, "Follow these steps.")
        XCTAssertEqual(entries[0].use_count, 4)
        XCTAssertFalse(entries[0].is_symlink)
    }

    func testCreateFailsWhenAlreadyExists() throws {
        let vault = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let existing = vault.appendingPathComponent("dup-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SkillVaultWriter.create(
                draft: SkillVaultDraft(folder_name: "dup-skill", name: "Dup"),
                vaultRoot: vault.path
            )
        ) { error in
            XCTAssertEqual(
                error as? SkillVaultWriterError,
                .alreadyExists(existing.path)
            )
        }
    }

    func testUpdateRewritesOwnedSkillAndRefusesSymlink() throws {
        let vault = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let owned = vault.appendingPathComponent("owned-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try "# old\n".write(to: owned.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        try SkillVaultWriter.update(
            path: owned.path,
            name: "Owned",
            description: "Updated",
            body: "New body"
        )
        let markdown = try String(
            contentsOf: owned.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        XCTAssertEqual(LocalSkillCatalog.parseFrontMatter(from: markdown).name, "Owned")
        XCTAssertEqual(SkillVaultWriter.readBody(fromMarkdown: markdown), "New body")

        let external = tempRoot.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let hub = vault.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(atPath: hub.path, withDestinationPath: external.path)

        XCTAssertThrowsError(
            try SkillVaultWriter.update(
                path: hub.path,
                name: "Nope",
                description: "",
                body: ""
            )
        ) { error in
            XCTAssertEqual(error as? SkillVaultWriterError, .symlinkNotEditable(hub.path))
        }
    }
}
