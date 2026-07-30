import Foundation
import XCTest
@testable import NotchCode

final class SkillRemoteInstallTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-remote-skill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testSkillSummariesParsesTreeUnderSkillsRoot() throws {
        let catalog = try XCTUnwrap(SkillRemoteCatalog.definition(id: "anthropic-skills"))
        let tree = GitTreeResponse(
            sha: "abc",
            truncated: false,
            tree: [
                GitTreeEntry(path: "skills/pdf/SKILL.md", type: "blob"),
                GitTreeEntry(path: "skills/pdf/forms.md", type: "blob"),
                GitTreeEntry(path: "skills/docx/SKILL.md", type: "blob"),
                GitTreeEntry(path: "template/SKILL.md", type: "blob"),
                GitTreeEntry(path: "README.md", type: "blob"),
            ]
        )

        let summaries = SkillRemoteCatalogClient.skillSummaries(from: tree, catalog: catalog)
        let folders = Set(summaries.map(\.folder_name))
        XCTAssertEqual(folders, ["pdf", "docx"])
        XCTAssertEqual(Set(summaries.map(\.remote_path)), ["skills/pdf", "skills/docx"])
    }

    func testAllowlistRejectsForeignCatalog() async {
        let foreign = SkillRemoteCatalogDefinition(
            id: "evil",
            title: "Evil",
            owner: "evil",
            repo: "skills",
            default_ref: "main",
            skills_roots: ["skills"]
        )
        do {
            _ = try await SkillRemoteCatalogClient.listSkills(
                catalog: foreign,
                includeMetadata: false,
                fetcher: StubRemoteFetcher(responses: [:])
            )
            XCTFail("expected allowlist error")
        } catch {
            XCTAssertEqual(error as? SkillRemoteCatalogError, .catalogNotAllowlisted)
        }
    }

    func testInstallWritesFilesAndRefusesOverwrite() async throws {
        let catalog = try XCTUnwrap(SkillRemoteCatalog.definition(id: "anthropic-skills"))
        let vault = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let treeJSON = """
        {
          "sha": "t",
          "truncated": false,
          "tree": [
            {"path":"skills/pdf/SKILL.md","type":"blob"},
            {"path":"skills/pdf/forms.md","type":"blob"}
          ]
        }
        """.data(using: .utf8)!

        let skillMarkdown = """
        ---
        name: PDF
        description: PDF helper
        ---
        body
        """.data(using: .utf8)!
        let forms = "# forms\n".data(using: .utf8)!

        let treeURL = URL(string:
            "https://api.github.com/repos/anthropics/skills/git/trees/main?recursive=1"
        )!
        let skillURL = URL(string:
            "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md"
        )!
        let formsURL = URL(string:
            "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/forms.md"
        )!

        let fetcher = StubRemoteFetcher(responses: [
            treeURL.absoluteString: treeJSON,
            skillURL.absoluteString: skillMarkdown,
            formsURL.absoluteString: forms,
        ])

        let summary = SkillRemoteSkillSummary(
            catalog_id: catalog.id,
            folder_name: "pdf",
            remote_path: "skills/pdf",
            name: "PDF",
            description: "PDF helper"
        )

        let installed = try await SkillRemoteInstallService.install(
            summary: summary,
            vaultRoot: vault.path,
            fetcher: fetcher
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed + "/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed + "/forms.md"))

        do {
            _ = try await SkillRemoteInstallService.install(
                summary: summary,
                vaultRoot: vault.path,
                fetcher: fetcher
            )
            XCTFail("expected already exists")
        } catch {
            XCTAssertEqual(error as? SkillRemoteInstallError, .alreadyExists(installed))
        }
    }
}

private struct StubRemoteFetcher: SkillRemoteHTTPFetching {
    let responses: [String: Data]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let key = request.url?.absoluteString ?? ""
        guard let data = responses[key], let url = request.url else {
            throw SkillRemoteCatalogError.invalidResponse("missing stub for \(key)")
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
