import CoreGraphics
import XCTest
@testable import NotchCode

final class ScreenNotchMetricsTests: XCTestCase {
    func testDetectUsesSafeAreaHeightForPhysicalNotchDisplays() {
        let metrics = ScreenNotchMetrics.detect(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 38,
            auxiliaryTopLeftWidth: 620,
            auxiliaryTopRightWidth: 620
        )

        XCTAssertTrue(metrics.hasPhysicalNotch)
        XCTAssertEqual(metrics.size, CGSize(width: 276, height: 38))
        XCTAssertEqual(metrics.closedHeight, 38)
    }

    func testDetectFallsBackToDefaultWidthWhenAuxiliaryAreasAreUnavailable() {
        let metrics = ScreenNotchMetrics.detect(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTop: 37,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil
        )

        XCTAssertTrue(metrics.hasPhysicalNotch)
        XCTAssertEqual(metrics.size, CGSize(width: 180, height: 37))
        XCTAssertEqual(metrics.closedHeight, 37)
    }

    func testFallbackWidthDoesNotScaleWithDisplayResolution() {
        let compactResolution = ScreenNotchMetrics.detect(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 38,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil
        )
        let moreSpaceResolution = ScreenNotchMetrics.detect(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTop: 38,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil
        )

        XCTAssertEqual(compactResolution.size.width, ScreenNotchMetrics.fallbackNotchWidth)
        XCTAssertEqual(moreSpaceResolution.size.width, ScreenNotchMetrics.fallbackNotchWidth)
    }

    func testDetectFallsBackForNonNotchDisplays() {
        let metrics = ScreenNotchMetrics.detect(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            safeAreaTop: 0,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil
        )

        XCTAssertFalse(metrics.hasPhysicalNotch)
        XCTAssertEqual(metrics.size, ScreenNotchMetrics.fallbackSize)
        XCTAssertEqual(metrics.closedHeight, ScreenNotchMetrics.fallbackClosedHeight)
    }
}
