import XCTest
@testable import Ping_Island

final class SessionQuestionFormTests: XCTestCase {
    func testQuestionListHeightUsesMinimumPanelHeightBudget() {
        XCTAssertEqual(SessionQuestionForm.questionListMaximumHeight(for: 480), 230)
    }

    func testQuestionListHeightGrowsWithUserPanelHeightSetting() {
        XCTAssertEqual(SessionQuestionForm.questionListMaximumHeight(for: 700), 370)
    }

    func testQuestionListHeightKeepsOuterPanelScrollMargin() {
        XCTAssertEqual(SessionQuestionForm.questionListMaximumHeight(for: 600), 270)
    }

    func testQuestionListHeightCapsOversizedContent() {
        XCTAssertEqual(
            SessionQuestionForm.questionListHeight(
                contentHeight: 900,
                maximumHeight: 320
            ),
            320
        )
    }

    func testQuestionListHeightFitsShortContent() {
        XCTAssertEqual(
            SessionQuestionForm.questionListHeight(
                contentHeight: 180,
                maximumHeight: 320
            ),
            180
        )
    }

    func testQuestionBottomShadowShowsOnlyForScrollableContent() {
        XCTAssertTrue(
            SessionQuestionForm.shouldShowQuestionBottomShadow(
                contentHeight: 360,
                visibleHeight: 320
            )
        )

        XCTAssertFalse(
            SessionQuestionForm.shouldShowQuestionBottomShadow(
                contentHeight: 320,
                visibleHeight: 320
            )
        )
    }

    func testOptionSequenceLabelsUseLetters() {
        XCTAssertEqual(SessionQuestionForm.optionSequenceLabel(for: 0), "A")
        XCTAssertEqual(SessionQuestionForm.optionSequenceLabel(for: 1), "B")
        XCTAssertEqual(SessionQuestionForm.optionSequenceLabel(for: 6), "G")
        XCTAssertEqual(SessionQuestionForm.optionSequenceLabel(for: 26), "AA")
    }

    func testLongOptionTitlesForceSingleColumnLayout() {
        let question = SessionInterventionQuestion(
            id: "deployment",
            header: "部署策略",
            prompt: "请选择回滚策略",
            detail: nil,
            options: [
                .init(
                    id: "safe",
                    title: "保持现有服务在线并逐步切换流量，确认所有检查通过后再下线旧版本",
                    detail: nil
                ),
                .init(id: "fast", title: "直接切换", detail: nil),
            ],
            allowsMultiple: false,
            allowsOther: false,
            isSecret: false
        )

        XCTAssertTrue(SessionQuestionForm.shouldUseSingleColumnOptions(for: question))
    }

    func testShortOptionTitlesKeepAdaptiveColumns() {
        let question = SessionInterventionQuestion(
            id: "plan",
            header: "方案",
            prompt: "请选择方案",
            detail: nil,
            options: [
                .init(id: "a", title: "修复问题", detail: nil),
                .init(id: "b", title: "补测试", detail: nil),
            ],
            allowsMultiple: false,
            allowsOther: false,
            isSecret: false
        )

        XCTAssertFalse(SessionQuestionForm.shouldUseSingleColumnOptions(for: question))
    }

    func testFourOptionsUseTwoColumns() {
        let question = SessionInterventionQuestion(
            id: "task_type",
            header: "Task Type",
            prompt: "What type of task would you like help with?",
            detail: nil,
            options: [
                .init(id: "bug", title: "Bug fix", detail: nil),
                .init(id: "feature", title: "New feature", detail: nil),
                .init(id: "refactor", title: "Refactoring", detail: nil),
                .init(id: "explore", title: "Exploration", detail: nil),
            ],
            allowsMultiple: false,
            allowsOther: false,
            isSecret: false
        )

        XCTAssertEqual(SessionQuestionForm.optionColumns(for: question).count, 2)
    }

    func testNextQuestionRevealPrefersNextUnansweredQuestion() {
        let questions = [
            makeQuestion(id: "scope"),
            makeQuestion(id: "timing"),
            makeQuestion(id: "tests"),
        ]

        XCTAssertEqual(
            SessionQuestionForm.nextQuestionIDToReveal(
                after: "scope",
                in: questions,
                answeredQuestionIDs: ["scope", "timing"]
            ),
            "tests"
        )
    }

    func testNextQuestionRevealFallsBackToPhysicalNextQuestionWhenLaterQuestionsAreAnswered() {
        let questions = [
            makeQuestion(id: "scope"),
            makeQuestion(id: "timing"),
            makeQuestion(id: "tests"),
        ]

        XCTAssertEqual(
            SessionQuestionForm.nextQuestionIDToReveal(
                after: "scope",
                in: questions,
                answeredQuestionIDs: ["scope", "timing", "tests"]
            ),
            "timing"
        )
    }

    func testNextQuestionRevealReturnsNilForLastQuestion() {
        let questions = [
            makeQuestion(id: "scope"),
            makeQuestion(id: "timing"),
        ]

        XCTAssertNil(
            SessionQuestionForm.nextQuestionIDToReveal(
                after: "timing",
                in: questions,
                answeredQuestionIDs: ["timing"]
            )
        )
    }

    func testCustomAnswerProtectsDraftInteraction() {
        let question = makeQuestion(id: "scope", allowsOther: true)

        XCTAssertTrue(
            SessionQuestionForm.protectsDraftInteraction(
                questions: [question],
                answers: [:],
                otherAnswers: ["scope": "Please keep my draft"],
                focusedQuestionID: nil
            )
        )
    }

    func testFocusedEmptyAnswerProtectsDraftInteraction() {
        let question = makeQuestion(id: "scope", allowsOther: true)

        XCTAssertTrue(
            SessionQuestionForm.protectsDraftInteraction(
                questions: [question],
                answers: [:],
                otherAnswers: [:],
                focusedQuestionID: "scope"
            )
        )
    }

    func testCustomAnswerReplacesSingleChoiceOptionInSubmission() {
        let question = makeQuestion(id: "scope", allowsOther: true)

        XCTAssertEqual(
            SessionQuestionForm.finalAnswers(
                for: question,
                answers: ["scope": ["Use the selected option"]],
                otherAnswers: ["scope": "Use the custom draft"]
            ),
            ["Use the custom draft"]
        )
    }

    private func makeQuestion(
        id: String,
        allowsOther: Bool = false
    ) -> SessionInterventionQuestion {
        SessionInterventionQuestion(
            id: id,
            header: id,
            prompt: id,
            detail: nil,
            options: [
                .init(id: "\(id)-yes", title: "是", detail: nil),
                .init(id: "\(id)-no", title: "否", detail: nil),
            ],
            allowsMultiple: false,
            allowsOther: allowsOther,
            isSecret: false
        )
    }
}
