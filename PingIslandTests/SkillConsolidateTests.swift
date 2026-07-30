import Foundation
import XCTest
@testable import NotchCode

final class SkillConsolidateTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-consolidate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testPriorityPrefersManualThenClaudeThenCodex() {
        let manualRoot = tempRoot.appendingPathComponent("manual", isDirectory: true).path
        let manual = LocalSkill(
            id: "\(manualRoot)/code-review",
            name: "code-review",
            description: nil,
            directoryPath: "\(manualRoot)/code-review",
            skillMarkdownPath: "\(manualRoot)/code-review/SKILL.md",
            sourceLabel: "manual"
        )
        let claude = LocalSkill(
            id: "/tmp/home/.claude/skills/code-review",
            name: "code-review",
            description: nil,
            directoryPath: "/tmp/home/.claude/skills/code-review",
            skillMarkdownPath: "/tmp/home/.claude/skills/code-review/SKILL.md",
            sourceLabel: ".claude/skills"
        )
        let codex = LocalSkill(
            id: "/tmp/home/.codex/skills/code-review",
            name: "code-review",
            description: nil,
            directoryPath: "/tmp/home/.codex/skills/code-review",
            skillMarkdownPath: "/tmp/home/.codex/skills/code-review/SKILL.md",
            sourceLabel: ".codex/skills"
        )
        let manualRoots: Set<String> = [(manualRoot as NSString).standardizingPath]
        XCTAssertEqual(SkillConsolidatePlanner.priorityScore(for: manual, manualRoots: manualRoots), 0)
        XCTAssertEqual(SkillConsolidatePlanner.priorityScore(for: claude, manualRoots: manualRoots), 1)
        XCTAssertEqual(SkillConsolidatePlanner.priorityScore(for: codex, manualRoots: manualRoots), 2)
        XCTAssertLessThan(
            SkillConsolidatePlanner.priorityScore(for: claude, manualRoots: manualRoots),
            SkillConsolidatePlanner.priorityScore(for: codex, manualRoots: manualRoots)
        )
    }

    func testPlanMovesClaudeWinnerAndRelinksCodexDuplicate() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let claudeSkill = home.appendingPathComponent(".claude/skills/demo-skill", isDirectory: true)
        let codexSkill = home.appendingPathComponent(".codex/skills/demo-skill", isDirectory: true)
        let vault = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkill, withIntermediateDirectories: true)
        try "# claude\n".write(to: claudeSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# codex\n".write(to: codexSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = [
            LocalSkill(
                id: claudeSkill.path,
                name: "demo-skill",
                description: nil,
                directoryPath: claudeSkill.path,
                skillMarkdownPath: claudeSkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: ".claude/skills"
            ),
            LocalSkill(
                id: codexSkill.path,
                name: "demo-skill",
                description: nil,
                directoryPath: codexSkill.path,
                skillMarkdownPath: codexSkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: ".codex/skills"
            ),
        ]

        let plan = SkillConsolidatePlanner.plan(
            skills: skills,
            vaultRoot: vault.path,
            manualRoots: []
        )
        XCTAssertEqual(plan.moveCount, 1)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].action, .moveThenRelink)
        XCTAssertEqual(
            (plan.groups[0].winner_path as NSString?)?.standardizingPath,
            (claudeSkill.path as NSString).standardizingPath
        )
        XCTAssertTrue(plan.groups[0].relink_paths.contains { ($0 as NSString).standardizingPath == (codexSkill.path as NSString).standardizingPath })

        let result = SkillConsolidator.execute(plan)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.conflicts.isEmpty)

        let destination = vault.appendingPathComponent("demo-skill", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
        let claudeDest = try FileManager.default.destinationOfSymbolicLink(atPath: claudeSkill.path)
        let codexDest = try FileManager.default.destinationOfSymbolicLink(atPath: codexSkill.path)
        XCTAssertEqual((claudeDest as NSString).standardizingPath, (destination.path as NSString).standardizingPath)
        XCTAssertEqual((codexDest as NSString).standardizingPath, (destination.path as NSString).standardizingPath)
        let body = try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(body.contains("claude"))
    }

    func testPlanRelinksOnlyWhenVaultAlreadyHasSkill() throws {
        let home = tempRoot.appendingPathComponent("home2", isDirectory: true)
        let vaultSkill = home.appendingPathComponent(".agents/skills/shared", isDirectory: true)
        let claudeSkill = home.appendingPathComponent(".claude/skills/shared", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSkill, withIntermediateDirectories: true)
        try "# vault\n".write(to: vaultSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# claude\n".write(to: claudeSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = [
            LocalSkill(
                id: vaultSkill.path,
                name: "shared",
                description: nil,
                directoryPath: vaultSkill.path,
                skillMarkdownPath: vaultSkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: ".agents/skills"
            ),
            LocalSkill(
                id: claudeSkill.path,
                name: "shared",
                description: nil,
                directoryPath: claudeSkill.path,
                skillMarkdownPath: claudeSkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: ".claude/skills"
            ),
        ]

        let plan = SkillConsolidatePlanner.plan(
            skills: skills,
            vaultRoot: home.appendingPathComponent(".agents/skills").path,
            manualRoots: []
        )
        XCTAssertEqual(plan.groups[0].action, .relinkOnly)
        XCTAssertEqual(plan.moveCount, 0)

        let result = SkillConsolidator.execute(plan)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertFalse(result.relinked.isEmpty)
        let body = try String(contentsOf: vaultSkill.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(body.contains("vault"))
        let linked = try FileManager.default.destinationOfSymbolicLink(atPath: claudeSkill.path)
        XCTAssertEqual((linked as NSString).standardizingPath, (vaultSkill.path as NSString).standardizingPath)
    }

    func testPlanAdoptsExternalSymlinksIntoVault() throws {
        let home = tempRoot.appendingPathComponent("home3", isDirectory: true)
        let external = home.appendingPathComponent("wiki/skills/wiki-cli", isDirectory: true)
        let claudeSkill = home.appendingPathComponent(".claude/skills/wiki-cli", isDirectory: true)
        let workbuddySkill = home.appendingPathComponent(".workbuddy/skills/wiki-cli", isDirectory: true)
        let vault = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: claudeSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workbuddySkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# wiki-cli\n".write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: claudeSkill, withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: workbuddySkill, withDestinationURL: external)

        let skills = [
            LocalSkill(
                id: claudeSkill.path,
                name: "wiki-cli",
                description: nil,
                directoryPath: claudeSkill.path,
                skillMarkdownPath: claudeSkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: ".claude/skills"
            ),
            LocalSkill(
                id: workbuddySkill.path,
                name: "wiki-cli",
                description: nil,
                directoryPath: workbuddySkill.path,
                skillMarkdownPath: workbuddySkill.appendingPathComponent("SKILL.md").path,
                sourceLabel: "WorkBuddy"
            ),
        ]

        let plan = SkillConsolidatePlanner.plan(
            skills: skills,
            vaultRoot: vault.path,
            manualRoots: []
        )
        XCTAssertEqual(plan.adoptCount, 1)
        guard case .adoptExternalThenRelink(let target) = plan.groups[0].action else {
            return XCTFail("Expected adoptExternalThenRelink")
        }
        XCTAssertEqual((target as NSString).standardizingPath, (external.path as NSString).standardizingPath)

        let result = SkillConsolidator.execute(plan)
        XCTAssertEqual(result.adopted.count, 1)
        XCTAssertTrue(result.conflicts.isEmpty)

        let vaultSkill = vault.appendingPathComponent("wiki-cli")
        let vaultTarget = try FileManager.default.destinationOfSymbolicLink(atPath: vaultSkill.path)
        XCTAssertEqual((vaultTarget as NSString).standardizingPath, (external.path as NSString).standardizingPath)
        let claudeTarget = try FileManager.default.destinationOfSymbolicLink(atPath: claudeSkill.path)
        XCTAssertEqual((claudeTarget as NSString).standardizingPath, (vaultSkill.path as NSString).standardizingPath)
    }
}
