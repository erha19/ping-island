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
}
