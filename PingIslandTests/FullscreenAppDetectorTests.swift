import CoreGraphics
import XCTest
@testable import Ping_Island

final class FullscreenAppDetectorTests: XCTestCase {
    func testNearlyScreenSizedWindowWithMenuBarInsetIsNotFullscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let maximizedChromeLikeWindow = CGRect(x: 0, y: 28, width: 1512, height: 954)

        XCTAssertFalse(
            FullscreenAppDetector.isLikelyFullscreenWindow(
                bounds: maximizedChromeLikeWindow,
                screenFrame: screen
            )
        )
    }

    func testEdgeToEdgeWindowIsFullscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        XCTAssertTrue(
            FullscreenAppDetector.isLikelyFullscreenWindow(
                bounds: screen,
                screenFrame: screen
            )
        )
    }
}
