import Foundation
import XCTest
@testable import NotchCode

final class LocalSkillManagerTests: XCTestCase {
    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaultsSuiteName = "ping.island.skill.manager.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testParseFrontMatterReadsNameAndDescription() {
        let markdown = """
        ---
        name: Demo Skill
        description: Does a demo thing
        ---

        # Body
        """
        let parsed = LocalSkillCatalog.parseFrontMatter(from: markdown)
        XCTAssertEqual(parsed.name, "Demo Skill")
        XCTAssertEqual(parsed.description, "Does a demo thing")
    }

    func testDiscoverScansManualRootForSkillMarkdown() throws {
        let skillDir = tempRoot.appendingPathComponent("demo-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: Demo Skill
        description: Hello
        ---
        """
        try markdown.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let skills = LocalSkillCatalog.discover(
            manualRoots: [tempRoot.path],
            profiles: [],
            homeDirectory: tempRoot.appendingPathComponent("empty-home", isDirectory: true)
        )

        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "Demo Skill")
        XCTAssertEqual(skills[0].description, "Hello")
        XCTAssertEqual(skills[0].sourceLabel, "manual")
    }

    func testLaunchResolutionPrefersSkillOverrideOverGlobal() {
        let skillID = "/tmp/skills/demo"
        var snapshot = SkillRouteRegistrySnapshot(
            global_launch_profile_id: "codex-hooks",
            manual_roots: [],
            routes: [
                skillID: SkillRouteOverride(launch_profile_id: "workbuddy-hooks", linked_profile_ids: [])
            ]
        )
        XCTAssertEqual(
            SkillRouteRegistry.resolvedLaunchProfileID(for: skillID, snapshot: snapshot),
            "workbuddy-hooks"
        )

        snapshot.routes.removeValue(forKey: skillID)
        XCTAssertEqual(
            SkillRouteRegistry.resolvedLaunchProfileID(for: skillID, snapshot: snapshot),
            "codex-hooks"
        )
    }

    func testRegistryMigratesLegacyAICOSLaunchTarget() {
        AICOSLaunchTargetResolver.setStoredProfileID("codex-hooks", defaults: defaults)
        let loaded = SkillRouteRegistry.load(defaults: defaults)
        XCTAssertEqual(loaded.global_launch_profile_id, "codex-hooks")
    }

    func testPasteBuilderIncludesNameAndPath() {
        let skill = LocalSkill(
            id: "/tmp/skills/demo",
            name: "Demo",
            description: "Desc",
            directoryPath: "/tmp/skills/demo",
            skillMarkdownPath: "/tmp/skills/demo/SKILL.md",
            sourceLabel: "manual"
        )
        let zh = SkillPasteBuilder.buildPrompt(for: skill, languageCode: "zh-Hans")
        XCTAssertTrue(zh.contains("Demo"))
        XCTAssertTrue(zh.contains("/tmp/skills/demo"))
        XCTAssertTrue(zh.contains("SKILL.md"))

        let en = SkillPasteBuilder.buildPrompt(for: skill, languageCode: "en")
        XCTAssertTrue(en.contains("Please use the following local skill"))
        XCTAssertTrue(en.contains("Demo"))
    }

    func testSymlinkLinkerCreatesAndReportsConflict() throws {
        let skillDir = tempRoot.appendingPathComponent("shared-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# skill\n".write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let skill = LocalSkill(
            id: skillDir.path,
            name: "shared-skill",
            description: nil,
            directoryPath: skillDir.standardizedFileURL.path,
            skillMarkdownPath: skillDir.appendingPathComponent("SKILL.md").path,
            sourceLabel: "manual"
        )

        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let profile = ManagedHookClientProfile(
            id: "test-hooks",
            title: "Test",
            subtitle: "test",
            localAppBundleIdentifiers: [],
            iconSymbolName: "hammer",
            configurationRelativePath: ".testclient/settings.json",
            bridgeSource: "test",
            bridgeExtraArguments: [],
            defaultEnabled: true,
            brand: .claude,
            events: []
        )

        let linked = SkillSymlinkLinker.ensureLink(
            skill: skill,
            profile: profile,
            homeDirectory: home
        )
        XCTAssertEqual(linked, .linked)

        let status = SkillSymlinkLinker.linkStatus(
            skill: skill,
            profile: profile,
            homeDirectory: home
        )
        XCTAssertEqual(status, .linked)

        // Replace symlink with a real directory to force conflict.
        let linkURL = SkillAgentSkillsPath
            .skillsDirectory(for: profile, homeDirectory: home)
            .appendingPathComponent(skill.folderName, isDirectory: true)
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createDirectory(at: linkURL, withIntermediateDirectories: true)
        try "nope".write(
            to: linkURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let conflict = SkillSymlinkLinker.ensureLink(
            skill: skill,
            profile: profile,
            homeDirectory: home
        )
        guard case .conflict = conflict else {
            return XCTFail("Expected conflict, got \(conflict)")
        }
    }
}
