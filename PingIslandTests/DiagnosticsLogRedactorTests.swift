import XCTest
@testable import NotchCode

final class DiagnosticsLogRedactorTests: XCTestCase {
    func testClaudeHookJSONLRedactionOmitsInternalPayloads() throws {
        let rawPrompt = "please inspect /tmp/synthetic-private/project and send token sk-secret"
        let lineObject: [String: Any] = [
            "id": "48B4CF32-3D27-42D4-8E12-4419013A7D58",
            "timestamp": "2026-05-03T10:00:00Z",
            "provider": "claude",
            "clientKind": "claudeCode",
            "eventType": "PreToolUse",
            "sessionKey": "claude:/tmp/synthetic-private/project/session-123",
            "expectsResponse": true,
            "statusKind": "working",
            "title": rawPrompt,
            "preview": "Bash: \(rawPrompt)",
            "arguments": ["PingIslandBridge", "--source", "claude", "--socket-path", "/tmp/private.sock"],
            "environment": [
                "ANTHROPIC_API_KEY": "sk-secret",
                "PWD": "/tmp/synthetic-private/project",
            ],
            "metadata": [
                "tool_name": "Bash",
                "prompt_text": rawPrompt,
                "client_kind": "claude",
            ],
            "stdinRaw": "{\"prompt\":\"\(rawPrompt)\"}",
            "envelopeJSON": "{\"message\":\"\(rawPrompt)\"}",
            "socketPath": "/tmp/private.sock",
            "deliveryOutcome": "delivered",
        ]
        let line = try jsonLine(lineObject)

        let sanitizedLine = try XCTUnwrap(DiagnosticsLogRedactor.sanitizedClaudeHookDebugLine(line))
        XCTAssertFalse(sanitizedLine.contains(rawPrompt))
        XCTAssertFalse(sanitizedLine.contains("sk-secret"))
        XCTAssertFalse(sanitizedLine.contains("session-123"))

        let sanitized = try decodedObject(sanitizedLine)
        XCTAssertEqual(sanitized["redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["eventType"] as? String, "PreToolUse")
        XCTAssertEqual(sanitized["provider"] as? String, "claude")
        XCTAssertNotNil(sanitized["sessionKeyHash"] as? String)

        let title = try XCTUnwrap(sanitized["title"] as? [String: Any])
        XCTAssertEqual(title["present"] as? Bool, true)
        XCTAssertEqual(title["characterCount"] as? Int, rawPrompt.count)

        let stdinRaw = try XCTUnwrap(sanitized["stdinRaw"] as? [String: Any])
        XCTAssertEqual(stdinRaw["present"] as? Bool, true)
        XCTAssertGreaterThan(stdinRaw["byteCount"] as? Int ?? 0, 0)

        let envelopeJSON = try XCTUnwrap(sanitized["envelopeJSON"] as? [String: Any])
        XCTAssertEqual(envelopeJSON["present"] as? Bool, true)
        XCTAssertGreaterThan(envelopeJSON["byteCount"] as? Int ?? 0, 0)

        let metadata = try XCTUnwrap(sanitized["metadata"] as? [String: Any])
        let selectedValues = try XCTUnwrap(metadata["selectedValues"] as? [String: Any])
        XCTAssertEqual(selectedValues["tool_name"] as? String, "Bash")
        XCTAssertNil(selectedValues["prompt_text"])
    }

    func testClaudeHookJSONLRedactionHandlesInvalidJSONWithoutLeakingRawLine() throws {
        let rawLine = "{\"stdinRaw\":\"secret prompt\""

        let sanitizedLine = try XCTUnwrap(DiagnosticsLogRedactor.sanitizedClaudeHookDebugLine(rawLine))
        XCTAssertFalse(sanitizedLine.contains("secret prompt"))

        let sanitized = try decodedObject(sanitizedLine)
        XCTAssertEqual(sanitized["redacted"] as? Bool, true)
        XCTAssertEqual(sanitized["parseError"] as? String, "invalid-json")
        XCTAssertGreaterThan(sanitized["rawByteCount"] as? Int ?? 0, 0)
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func decodedObject(_ line: String) throws -> [String: Any] {
        let data = try XCTUnwrap(line.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
