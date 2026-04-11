import XCTest
@testable import Ping_Island

final class UpdateReleaseNotesParserTests: XCTestCase {
    func testParserSplitsSecondLevelHeadingsIntoSections() {
        let markdown = """
        ## 改进
        - 更稳了

        ## 修复
        - 修了闪烁
        """

        let sections = UpdateReleaseNotesParser.sections(from: markdown)

        XCTAssertEqual(sections.map(\.title), ["改进", "修复"])
        XCTAssertEqual(sections.first?.markdown, "- 更稳了")
        XCTAssertEqual(sections.last?.markdown, "- 修了闪烁")
    }

    func testParserFallsBackToSingleSectionWithoutHeadings() {
        let markdown = """
        - 第一条
        - 第二条
        """

        let sections = UpdateReleaseNotesParser.sections(from: markdown)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "更新内容")
        XCTAssertTrue(sections[0].markdown.contains("第一条"))
    }

    func testParserPrefersChineseLocalizedBlockForChineseLocale() {
        let markdown = """
        <!-- zh-Hans -->
        ## 亮点
        - 中文内容

        <!-- en -->
        ## Highlights
        - English content
        """

        let sections = UpdateReleaseNotesParser.sections(
            from: markdown,
            locale: Locale(identifier: "zh-Hans")
        )

        XCTAssertEqual(sections.map(\.title), ["亮点"])
        XCTAssertEqual(sections.first?.markdown, "- 中文内容")
    }

    func testParserPrefersEnglishLocalizedBlockForEnglishLocale() {
        let markdown = """
        <!-- zh-Hans -->
        ## 亮点
        - 中文内容

        <!-- en -->
        ## Highlights
        - English content
        """

        let sections = UpdateReleaseNotesParser.sections(
            from: markdown,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(sections.map(\.title), ["Highlights"])
        XCTAssertEqual(sections.first?.markdown, "- English content")
    }

    func testParserFallsBackToEnglishBlockWhenChineseBlockIsMissing() {
        let markdown = """
        <!-- en -->
        ## Highlights
        - English only
        """

        let sections = UpdateReleaseNotesParser.sections(
            from: markdown,
            locale: Locale(identifier: "zh-Hans")
        )

        XCTAssertEqual(sections.map(\.title), ["Highlights"])
        XCTAssertEqual(sections.first?.markdown, "- English only")
    }
}
