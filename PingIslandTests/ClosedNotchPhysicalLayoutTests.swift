import XCTest
@testable import NotchCode

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

    func testWingSideWidthConstant() {
        XCTAssertEqual(ClosedNotchPhysicalLayout.wingSideWidth, 28)
        XCTAssertEqual(ClosedNotchPhysicalLayout.wingUsageTrailingMinWidth, 34)
    }

    func testWingTrailingWidthUsesUsageFloor() {
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.wingTrailingWidth(hasExpandedUsage: false),
            ClosedNotchPhysicalLayout.wingSideWidth
        )
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.wingTrailingWidth(hasExpandedUsage: true),
            ClosedNotchPhysicalLayout.wingUsageTrailingMinWidth
        )
    }

    func testPreferredWingClosedWidthAddsBothWings() {
        let width = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
            deviceNotchWidth: 220,
            hasExpandedUsage: false
        )
        XCTAssertEqual(
            width,
            220 + 28 + 28 + (ClosedNotchPhysicalLayout.closedHorizontalContentInset * 2)
        )

        let usageWidth = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
            deviceNotchWidth: 220,
            hasExpandedUsage: true
        )
        XCTAssertEqual(
            usageWidth,
            220 + 34 + 34 + (ClosedNotchPhysicalLayout.closedHorizontalContentInset * 2)
        )
    }
}
