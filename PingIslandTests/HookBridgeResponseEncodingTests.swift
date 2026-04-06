import Foundation
import XCTest
@testable import Ping_Island

final class HookBridgeResponseEncodingTests: XCTestCase {
    func testApproveDecisionEncodesSharedBridgeShape() throws {
        let response = BridgeResponse(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            decision: .approve,
            reason: nil,
            updatedInput: nil,
            errorMessage: nil
        )

        let json = try encodedJSONObject(for: response)
        let decision = try XCTUnwrap(json["decision"] as? [String: Any])
        let approve = try XCTUnwrap(decision["approve"] as? [String: Any])

        XCTAssertTrue(approve.isEmpty)
    }

    func testAnswerDecisionEncodesSharedBridgeShape() throws {
        let response = BridgeResponse(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            decision: .answer(["question": "简洁明了"]),
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["question": "简洁明了"])
            ],
            errorMessage: nil
        )

        let json = try encodedJSONObject(for: response)
        let decision = try XCTUnwrap(json["decision"] as? [String: Any])
        let answer = try XCTUnwrap(decision["answer"] as? [String: Any])
        let payload = try XCTUnwrap(answer["_0"] as? [String: String])

        XCTAssertEqual(payload, ["question": "简洁明了"])
    }

    private func encodedJSONObject(for response: BridgeResponse) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
