import XCTest
@testable import NotchCode

final class SessionMonitorAskUserQuestionTests: XCTestCase {
    func testUpdatedHookToolInputUsesQuestionTextAsAnswerKey() {
        let rawJSON = """
        {
          "questions": [
            {
              "id": "music",
              "header": "音乐偏好",
              "question": "你喜欢什么类型的音乐？",
              "options": [
                { "label": "流行音乐" },
                { "label": "古典音乐" }
              ],
              "multiSelect": true
            }
          ]
        }
        """

        let updated = SessionMonitor.updatedHookToolInput(
            rawJSON: rawJSON,
            answers: ["music": ["流行音乐", "古典音乐"]]
        )

        let answers = updated?["answers"] as? [String: Any]
        XCTAssertEqual(
            answers?["你喜欢什么类型的音乐？"] as? [String],
            ["流行音乐", "古典音乐"]
        )
        XCTAssertNil(answers?["music"])
    }

    func testUpdatedHookToolInputKeepsLookupAliasesForQoder() {
        let rawJSON = """
        {
          "questions": [
            {
              "id": "topic",
              "header": "主题",
              "question": "先选一个主题",
              "options": [
                { "label": "A 方案" },
                { "label": "B 方案" }
              ]
            }
          ]
        }
        """

        let updated = SessionMonitor.updatedHookToolInput(
            rawJSON: rawJSON,
            answers: ["topic": ["A 方案"]],
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            )
        )

        let answers = updated?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "A 方案")
        XCTAssertEqual(answers?["先选一个主题"] as? String, "A 方案")
    }

    func testUpdatedHookToolInputAddsCodeBuddyCLIQuestionIndexAlias() {
        let rawJSON = """
        {
          "questions": [
            {
              "id": "scope",
              "header": "范围",
              "question": "这次要修哪里？",
              "options": [
                { "label": "SessionStore" },
                { "label": "UI 卡片" }
              ]
            }
          ]
        }
        """

        let updated = SessionMonitor.updatedHookToolInput(
            rawJSON: rawJSON,
            answers: ["scope": ["SessionStore"]],
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "codebuddy-cli",
                name: "CodeBuddy CLI",
                origin: "cli"
            )
        )

        let answers = updated?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["scope"] as? String, "SessionStore")
        XCTAssertEqual(answers?["这次要修哪里？"] as? String, "SessionStore")
        XCTAssertEqual(answers?["0"] as? String, "SessionStore")
        XCTAssertEqual(answers?["q_0"] as? String, "SessionStore")
    }

    func testUpdatedHookToolInputIncludesQoderCLIQuestionAliases() {
        let rawJSON = """
        {
          "questions": [
            {
              "id": "task_intent",
              "header": "Task",
              "question": "Would you like me to help you with a specific coding task?",
              "options": [
                { "label": "Yes" },
                { "label": "No" }
              ],
              "multiSelect": false
            }
          ]
        }
        """

        let updated = SessionMonitor.updatedHookToolInput(
            rawJSON: rawJSON,
            answers: ["task_intent": ["Yes"]],
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli"
            )
        )

        let answers = updated?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Would you like me to help you with a specific coding task?"] as? String, "Yes")
        XCTAssertEqual(answers?["Task"] as? String, "Yes")
        XCTAssertEqual(answers?["task_intent"] as? String, "Yes")
        XCTAssertNil(answers?["0"])
    }

    func testUpdatedHookToolInputUsesQuestionIndexForQwenCode() {
        let rawJSON = """
        {
          "questions": [
            {
              "question": "你最喜欢哪种编程语言？",
              "header": "编程语言",
              "options": [
                { "label": "Python" },
                { "label": "Rust" }
              ],
              "multiSelect": false
            }
          ]
        }
        """

        let updated = SessionMonitor.updatedHookToolInput(
            rawJSON: rawJSON,
            answers: ["你最喜欢哪种编程语言？": ["Python"]],
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "qwen-code",
                name: "Qwen Code",
                origin: "cli",
                originator: "Qwen Code",
                threadSource: "qwen-code-hooks"
            )
        )

        let answers = updated?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["0"] as? String, "Python")
        XCTAssertNil(answers?["你最喜欢哪种编程语言？"])
    }
}
