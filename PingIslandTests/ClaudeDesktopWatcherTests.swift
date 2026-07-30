import XCTest
@testable import NotchCode

final class ClaudeDesktopWatcherTests: XCTestCase {
    func testDiscoveryIntervalBacksOffWhenNoNewSessionsAreFound() {
        XCTAssertEqual(
            ClaudeDesktopWatcher.discoveryInterval(for: .rootMissing),
            .seconds(60)
        )
        XCTAssertEqual(
            ClaudeDesktopWatcher.discoveryInterval(for: .scanned(registeredNewSession: false)),
            .seconds(15)
        )
        XCTAssertEqual(
            ClaudeDesktopWatcher.discoveryInterval(for: .scanned(registeredNewSession: true)),
            .seconds(2)
        )
    }
}
