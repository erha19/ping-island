import XCTest
@testable import Ping_Island

final class ClosedNotchPhysicalLayoutTests: XCTestCase {
    func testCameraClearanceUsesFullNotchPlusLip() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)

        XCTAssertEqual(clearance, 38 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }

    func testVisibleBandIsTextBandPlusBottomPadding() {
        XCTAssertEqual(ClosedNotchPhysicalLayout.textBandHeight, 16)
        XCTAssertEqual(ClosedNotchPhysicalLayout.visibleBandBottomPadding, 6)
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.visibleBandHeight,
            ClosedNotchPhysicalLayout.textBandHeight
                + ClosedNotchPhysicalLayout.visibleBandBottomPadding
        )
        XCTAssertEqual(ClosedNotchPhysicalLayout.visibleBandHeight, 22)
    }

    func testPreferredClosedHeightUsesClearancePlusVisibleBand() {
        let height = ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: 38)

        XCTAssertEqual(
            height,
            ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)
                + ClosedNotchPhysicalLayout.visibleBandHeight
        )
        XCTAssertEqual(height, 38 + 6 + 22)
    }

    func testCameraClearanceFallsBackWhenDeviceHeightIsMissing() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 0)

        XCTAssertEqual(clearance, 32 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }
}
