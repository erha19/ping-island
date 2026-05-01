import XCTest
@testable import Ping_Island

final class SessionQuestionFormTests: XCTestCase {
    func testQuestionListHeightUsesMinimumPanelHeightBudget() {
        XCTAssertEqual(SessionQuestionForm.questionListMaximumHeight(for: 480), 230)
    }

    func testQuestionListHeightGrowsWithUserPanelHeightSetting() {
        XCTAssertEqual(SessionQuestionForm.questionListMaximumHeight(for: 700), 450)
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
}
