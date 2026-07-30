import Foundation
import XCTest
@testable import NotchCode

final class SessionCompletionPreviewBuilderTests: XCTestCase {
    func testLatestUserAndAssistantTextPreferConversationHistory() {
        let session = SessionState(
            sessionId: "completion-preview-history",
            cwd: "/tmp/project",
            chatItems: [
                ChatHistoryItem(id: "1", type: .user("第一条问题"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "2", type: .assistant("第一条回答"), timestamp: Date(timeIntervalSince1970: 2)),
                ChatHistoryItem(id: "3", type: .user("最新问题"), timestamp: Date(timeIntervalSince1970: 3)),
                ChatHistoryItem(id: "4", type: .assistant("最新回答"), timestamp: Date(timeIntervalSince1970: 4))
            ],
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "回退消息",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "首条问题",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: session), "最新问题")
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "最新回答")
    }

    func testLatestPreviewFallsBackToStoredConversationSummary() {
        let session = SessionState(
            sessionId: "completion-preview-fallback",
            cwd: "/tmp/project",
            previewText: "  最终\n结果  ",
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "  最后一条消息  ",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "  最初问题  ",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: session), "最初问题")
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: session), "最终 结果")
    }

    func testCompactedNotificationSuppressesAssistantPreview() {
        let session = SessionState(
            sessionId: "completion-preview-compacted",
            cwd: "/tmp/project",
            previewText: "压缩后的最新结果",
            conversationInfo: ConversationInfo(
                summary: "会话摘要",
                lastMessage: "最终消息",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "初始问题",
                lastUserMessageDate: nil
            )
        )

        XCTAssertNil(
            SessionCompletionPreviewBuilder.latestAssistantText(
                for: session,
                notificationKind: .compacted
            )
        )
        XCTAssertEqual(
            SessionCompletionPreviewBuilder.latestAssistantText(
                for: session,
                notificationKind: .completed
            ),
            "压缩后的最新结果"
        )
    }
}
