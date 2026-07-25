import XCTest
@testable import Ping_Island

final class ClosedNotchPhysicalLayoutTests: XCTestCase {
    func testCameraClearanceUsesFullNotchPlusLip() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)

        XCTAssertEqual(clearance, 38 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }

    func testPreferredClosedHeightUsesClearancePlusTextBand() {
        let height = ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: 38)

        XCTAssertEqual(
            height,
            ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)
                + ClosedNotchPhysicalLayout.textBandHeight
        )
    }

    func testCameraClearanceFallsBackWhenDeviceHeightIsMissing() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 0)

        XCTAssertEqual(clearance, 32 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }
}
