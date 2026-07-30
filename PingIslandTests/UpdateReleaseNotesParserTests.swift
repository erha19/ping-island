import XCTest
@testable import NotchCode

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

    func testMarkdownBlockParserGroupsBulletItemsIntoSingleListBlock() {
        let blocks = UpdateReleaseNotesMarkdownParser.blocks(
            from: """
            - First improvement
            - Second improvement
            - Third improvement
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .unorderedList([
                    "First improvement",
                    "Second improvement",
                    "Third improvement"
                ])
            ]
        )
    }

    func testMarkdownBlockParserKeepsParagraphListAndCodeBlockSeparated() {
        let blocks = UpdateReleaseNotesMarkdownParser.blocks(
            from: """
            Intro paragraph.

            1. Step one
            2. Step two

            ```swift
            print("Ping Island")
            ```
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .paragraph("Intro paragraph."),
                .orderedList([
                    "Step one",
                    "Step two"
                ]),
                .codeBlock(language: "swift", code: #"print("Ping Island")"#)
            ]
        )
    }

    func testMarkdownBlockParserMergesIndentedListContinuationLines() {
        let blocks = UpdateReleaseNotesMarkdownParser.blocks(
            from: """
            - Primary bullet
              with more details
            - Secondary bullet
            """
        )

        XCTAssertEqual(
            blocks,
            [
                .unorderedList([
                    "Primary bullet\nwith more details",
                    "Secondary bullet"
                ])
            ]
        )
    }

    func testSectionIconMappingUsesDifferentSymbolsPerSectionType() {
        XCTAssertEqual(
            UpdateReleaseNotesSection(id: "1", title: "亮点", markdown: "").iconSymbolName,
            "sparkles"
        )
        XCTAssertEqual(
            UpdateReleaseNotesSection(id: "2", title: "修复", markdown: "").iconSymbolName,
            "wrench.and.screwdriver"
        )
        XCTAssertEqual(
            UpdateReleaseNotesSection(id: "3", title: "说明", markdown: "").iconSymbolName,
            "info.circle"
        )
        XCTAssertEqual(
            UpdateReleaseNotesSection(id: "4", title: "关联 PR", markdown: "").iconSymbolName,
            "arrow.triangle.branch"
        )
    }
}
