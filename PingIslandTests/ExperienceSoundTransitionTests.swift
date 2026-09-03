import XCTest
@testable import Ping_Island

final class ExperienceSoundTransitionTests: XCTestCase {
    private func session(id: String, lastUserMessageDate: Date) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/project",
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "message",
                lastMessageRole: "user",
                lastToolName: nil,
                firstUserMessage: "message",
                lastUserMessageDate: lastUserMessageDate
            ),
            lastActivity: lastUserMessageDate
        )
    }

    func testUsageWarningOnlyFiresWhenCrossingNinetyPercent() {
        XCTAssertNil(UsageSoundTransitionEvaluator.event(previous: nil, current: 95))
        XCTAssertNil(UsageSoundTransitionEvaluator.event(previous: 91, current: 96))
        XCTAssertEqual(
            UsageSoundTransitionEvaluator.event(previous: 89, current: 90),
            .usageWarning
        )
    }

    func testUsageResetOnlyFiresAfterMeaningfulRecovery() {
        XCTAssertNil(UsageSoundTransitionEvaluator.event(previous: 49, current: 20))
        XCTAssertNil(UsageSoundTransitionEvaluator.event(previous: 80, current: 30))
        XCTAssertEqual(
            UsageSoundTransitionEvaluator.event(previous: 80, current: 20),
            .usageReset
        )
    }

    func testIdleReminderFiresOnceUntilSessionLeavesWaitingState() {
        let now = Date()
        var tracker = IdleReminderSoundTracker()
        var session = SessionState(
            sessionId: "idle-reminder",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            lastActivity: now.addingTimeInterval(-IdleReminderSoundTracker.reminderDelay - 1)
        )

        XCTAssertEqual(tracker.sessionsNeedingReminder(from: [session], now: now).count, 1)
        XCTAssertTrue(tracker.sessionsNeedingReminder(from: [session], now: now).isEmpty)

        session.phase = .processing
        XCTAssertTrue(tracker.sessionsNeedingReminder(from: [session], now: now).isEmpty)
        session.phase = .waitingForInput
        XCTAssertEqual(tracker.sessionsNeedingReminder(from: [session], now: now).count, 1)
    }

    func testRapidSubmitHistorySurvivesTemporaryListChurn() {
        let now = Date()
        var tracker = RapidSubmitSoundTracker()
        tracker.observe([session(id: "a", lastUserMessageDate: now.addingTimeInterval(-2))], now: now)

        XCTAssertTrue(
            tracker.observe(
                [session(id: "a", lastUserMessageDate: now)],
                now: now
            ).isEmpty
        )
        XCTAssertTrue(tracker.observe([], now: now.addingTimeInterval(0.5)).isEmpty)
        XCTAssertTrue(
            tracker.observe(
                [session(id: "a", lastUserMessageDate: now.addingTimeInterval(1))],
                now: now.addingTimeInterval(1)
            ).isEmpty
        )
        XCTAssertTrue(tracker.observe([], now: now.addingTimeInterval(1.5)).isEmpty)

        XCTAssertEqual(
            tracker.observe(
                [session(id: "a", lastUserMessageDate: now.addingTimeInterval(2))],
                now: now.addingTimeInterval(2)
            ).map(\.sessionId),
            ["a"]
        )
    }
}
