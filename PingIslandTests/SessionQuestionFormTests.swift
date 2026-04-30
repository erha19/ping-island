import XCTest
@testable import Ping_Island

final class SessionQuestionFormTests: XCTestCase {
    func testScrollableQuestionListEnabledForThreeOptionQuestion() {
        let questions = [
            SessionInterventionQuestion(
                id: "plan",
                header: "方案",
                prompt: "请选择一个方案",
                detail: nil,
                options: [
                    .init(id: "a", title: "A", detail: nil),
                    .init(id: "b", title: "B", detail: nil),
                    .init(id: "c", title: "C", detail: nil),
                ],
                allowsMultiple: false,
                allowsOther: false,
                isSecret: false
            )
        ]

        XCTAssertTrue(SessionQuestionForm.shouldUseScrollableQuestionList(for: questions))
    }

    func testScrollableQuestionListDisabledForTwoSimpleOptions() {
        let questions = [
            SessionInterventionQuestion(
                id: "plan",
                header: "方案",
                prompt: "请选择一个方案",
                detail: nil,
                options: [
                    .init(id: "a", title: "A", detail: nil),
                    .init(id: "b", title: "B", detail: nil),
                ],
                allowsMultiple: false,
                allowsOther: false,
                isSecret: false
            )
        ]

        XCTAssertFalse(SessionQuestionForm.shouldUseScrollableQuestionList(for: questions))
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
