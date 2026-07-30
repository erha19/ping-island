import Foundation
import XCTest
@testable import NotchCode

final class SkillVaultLifecycleTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-vault-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testListEntriesReadsVaultSkillsAndInboundLinks() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let vault = home.appendingPathComponent(".agents/skills", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let skill = vault.appendingPathComponent("demo-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try """
        ---
        name: Demo Skill
        description: A test skill
        ---
        body
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let link = claudeSkills.appendingPathComponent("demo-skill")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: skill.path
        )

        let entries = SkillVaultCatalog.listEntries(
            vaultRoot: vault.path,
            manualRoots: [],
            profiles: [],
            homeDirectory: home
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].folder_name, "demo-skill")
        XCTAssertEqual(entries[0].name, "Demo Skill")
        XCTAssertEqual(entries[0].description, "A test skill")
        XCTAssertFalse(entries[0].is_symlink)
        XCTAssertEqual(entries[0].inbound_link_paths, [link.path])
    }

    func testUninstallRemovesVaultDirectoryAndInboundSymlinksButKeepsExternalTarget() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let vault = home.appendingPathComponent(".agents/skills", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let external = home.appendingPathComponent("wiki/external-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try "# external\n".write(
            to: external.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let vaultHub = vault.appendingPathComponent("external-skill")
        try FileManager.default.createSymbolicLink(
            atPath: vaultHub.path,
            withDestinationPath: external.path
        )
        let agentLink = claudeSkills.appendingPathComponent("external-skill")
        try FileManager.default.createSymbolicLink(
            atPath: agentLink.path,
            withDestinationPath: vaultHub.path
        )

        let entry = SkillVaultEntry(
            folder_name: "external-skill",
            name: "external-skill",
            description: nil,
            body: "",
            path: vaultHub.path,
            is_symlink: true,
            external_target: external.path,
            inbound_link_paths: [agentLink.path],
            use_count: 0
        )
        var registry = SkillRouteRegistrySnapshot(
            routes: [
                vaultHub.path: SkillRouteOverride(linked_profile_ids: ["claude-hooks"]),
                agentLink.path: SkillRouteOverride(launch_profile_id: "claude-hooks"),
            ]
        )

        let result = SkillVaultUninstaller.uninstall(entry: entry, registry: &registry)

        XCTAssertTrue(result.removed_vault_entry)
        XCTAssertEqual(result.removed_inbound_links, 1)
        XCTAssertEqual(Set(result.removed_route_keys), Set([vaultHub.path, agentLink.path]))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultHub.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(registry.routes.isEmpty)
    }

    func testUninstallRemovesOwnedVaultDirectory() throws {
        let vault = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let skill = vault.appendingPathComponent("owned-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# owned\n".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let entry = SkillVaultEntry(
            folder_name: "owned-skill",
            name: "owned-skill",
            description: nil,
            body: "",
            path: skill.path,
            is_symlink: false,
            external_target: nil,
            inbound_link_paths: [],
            use_count: 0
        )
        var registry = SkillRouteRegistrySnapshot()
        let result = SkillVaultUninstaller.uninstall(entry: entry, registry: &registry)

        XCTAssertTrue(result.removed_vault_entry)
        XCTAssertEqual(result.removed_inbound_links, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
    }
}
