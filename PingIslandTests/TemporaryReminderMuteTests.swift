import XCTest
@testable import NotchCode

final class TemporaryReminderMuteTests: XCTestCase {
    func testNotificationMuteIsActiveOnlyBeforeDeadline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(
            AppSettings.isNotificationMuteActive(
                until: now.addingTimeInterval(600),
                now: now
            )
        )
        XCTAssertFalse(
            AppSettings.isNotificationMuteActive(
                until: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testNotificationMuteTreatsMissingDeadlineAsInactive() {
        XCTAssertFalse(AppSettings.isNotificationMuteActive(until: nil))
    }
}
