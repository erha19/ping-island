import XCTest
@testable import NotchCode

final class ClosedNotchDotIconTests: XCTestCase {
    func testToneMapsIdleToOrangeWorkingToGreenWarningToRed() {
        XCTAssertEqual(ClosedNotchDotTone.from(status: .idle), .idle)
        XCTAssertEqual(ClosedNotchDotTone.from(status: .working), .working)
        XCTAssertEqual(ClosedNotchDotTone.from(status: .warning), .warning)
        XCTAssertEqual(ClosedNotchDotTone.from(status: .dragging), .idle)

        XCTAssertEqual(ClosedNotchDotTone.idle.rgb, ClosedNotchDotTone.RGB(r: 1.0, g: 0.7, b: 0.0))
        XCTAssertEqual(ClosedNotchDotTone.working.rgb, ClosedNotchDotTone.RGB(r: 0.4, g: 0.75, b: 0.45))
        XCTAssertEqual(ClosedNotchDotTone.warning.rgb, ClosedNotchDotTone.RGB(r: 1.0, g: 0.3, b: 0.3))
    }

    func testStatusBarFillsLocalTwoByFourCanvas() {
        XCTAssertEqual(ClosedNotchDotGlyph.canvasColumns, 2)
        XCTAssertEqual(ClosedNotchDotGlyph.canvasRows, 4)

        let bar = ClosedNotchDotGlyph.statusBarPoints
        XCTAssertEqual(bar.count, 8)
        XCTAssertEqual(Set(bar.map(\.x)), Set([0, 1]))
        XCTAssertEqual(Set(bar.map(\.y)), Set([0, 1, 2, 3]))
    }

    func testStatusMotionUsesSpinForWorkingAndBlinkForWarning() {
        XCTAssertEqual(ClosedNotchDotStatusMotion.from(status: .working), .spin)
        XCTAssertEqual(ClosedNotchDotStatusMotion.from(status: .warning), .blink)
        XCTAssertEqual(ClosedNotchDotStatusMotion.from(status: .idle), .staticBar)
        XCTAssertEqual(ClosedNotchDotStatusMotion.from(status: .dragging), .staticBar)
    }

    func testWorkingSpinRotatesStatusBarAroundItsCenter() {
        let center = ClosedNotchDotGlyph.statusBarCenter
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 1.5, accuracy: 0.001)

        let upright = ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: 0)
        XCTAssertEqual(upright.count, ClosedNotchDotGlyph.statusBarPoints.count)

        // Corner (1, 0) around (0.5, 1.5) by 180° → (0, 3)
        let flipped = ClosedNotchDotGlyph.rotatedPoint(
            ClosedNotchDotPoint(1, 0),
            angleRadians: .pi,
            around: center
        )
        XCTAssertEqual(flipped.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 3.0, accuracy: 0.001)

        let quarter = ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: .pi / 2)
        XCTAssertNotEqual(
            Set(upright.map { String(format: "%.2f,%.2f", $0.x, $0.y) }),
            Set(quarter.map { String(format: "%.2f,%.2f", $0.x, $0.y) })
        )
    }
}
