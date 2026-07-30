import Foundation
import XCTest
@testable import NotchCode

final class SessionEventLogSummaryTests: XCTestCase {
    func testPruneHeartbeatSkipsProcessingLog() {
        let event = SessionEvent.pruneTimedOutExternalContinuations(
            now: Date(timeIntervalSince1970: 1_744_384_902)
        )

        XCTAssertEqual(event.processingLogName, "pruneTimedOutExternalContinuations")
        XCTAssertNil(event.processingLogSessionPrefix)
        XCTAssertFalse(event.shouldEmitProcessingLog)
    }

    func testHookReceivedProcessingLogUsesStableSummary() {
        let event = SessionEvent.hookReceived(
            HookEvent(
                sessionId: "abcdef12345678",
                cwd: "/tmp/project",
                event: "PreToolUse",
                status: "running_tool",
                provider: .claude,
                clientInfo: .default(for: .claude),
                pid: nil,
                tty: nil,
                tool: "Read",
                toolInput: nil,
                toolUseId: "tool-1",
                notificationType: nil,
                message: nil
            )
        )

        XCTAssertEqual(event.processingLogName, "hookReceived.PreToolUse")
        XCTAssertEqual(event.processingLogSessionPrefix, "abcdef12")
        XCTAssertTrue(event.shouldEmitProcessingLog)
    }
}
