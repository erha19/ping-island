import XCTest
@testable import Ping_Island

final class SessionTextSanitizerTests: XCTestCase {
    func testMessageFormattingSurvivesBoilerplateRemoval() {
        let body = "    if ready:\n        run()"
        let wrappedMessages = [
            body,
            "\r\n \r\n\(body)\r\n\t",
            "Conversation info (untrusted metadata):\n```json\n{\"id\":\"synthetic\"}\n```\n\n\(body)",
            "Sender (untrusted metadata):\n```json\n{\"name\":\"synthetic\"}\n```\n\n\(body)",
            "Conversation info (untrusted metadata):\n```json\n{}\n```\n\nSender (untrusted metadata):\n```json\n{}\n```\n\nSystem: [synthetic] Node: test client\n\n<meta awareness=\"low\" />\n\(body)",
            "System: [synthetic] Node: test client\n\n\(body)",
            "<meta awareness=\"low\" timestamp=\"synthetic\" />\n\(body)",
            "\(body)\n<system-reminder>Client context</system-reminder>",
            "\(body)\n<system-reminder>Incomplete client context"
        ]

        for message in wrappedMessages {
            XCTAssertEqual(SessionTextSanitizer.sanitizedMessageText(message), body)
            XCTAssertEqual(
                SessionTextSanitizer.sanitizedDisplayText(message),
                "if ready: run()"
            )
        }
    }

    func testEmptyOrBoilerplateOnlyMessagesRemainAbsent() {
        let messages: [String?] = [nil, "", " \n\t", "\u{200B}", "<system-reminder>Client context</system-reminder>"]
        for message in messages {
            XCTAssertNil(SessionTextSanitizer.sanitizedMessageText(message))
            XCTAssertNil(SessionTextSanitizer.sanitizedDisplayText(message))
        }
    }

    func testZeroWidthCharactersInContentArePreserved() {
        let body = "\u{200B}\n    result\n\u{200B}"
        XCTAssertEqual(SessionTextSanitizer.sanitizedMessageText("\n\(body)\n"), body)
    }

    func testLongInteriorWhitespacePreservesFormattingWithoutStalling() {
        let body = "    begin" + String(repeating: "\n ", count: 32_768) + "end  "
        let message = "\r\n\t\r\n\(body)\r\n \t"

        let start = ContinuousClock.now
        let cleaned = SessionTextSanitizer.sanitizedMessageText(message)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(cleaned, body)
        // Leave ample headroom while detecting repeated scans of the interior blank lines.
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
