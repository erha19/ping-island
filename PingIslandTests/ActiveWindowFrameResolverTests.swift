import XCTest
@testable import NotchCode

final class ActiveWindowFrameResolverTests: XCTestCase {
    func testTopWindowFramePrefersFrontmostAppWindow() throws {
        let preferredPID: pid_t = 42
        let excludedPID: pid_t = 99
        let preferredBounds = ["X": 320, "Y": 180, "Width": 900, "Height": 640] as NSDictionary
        let fallbackBounds = ["X": 40, "Y": 60, "Width": 1280, "Height": 800] as NSDictionary

        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: excludedPID,
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: fallbackBounds
            ],
            [
                kCGWindowOwnerPID as String: preferredPID,
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: preferredBounds
            ]
        ]

        let frame = ActiveWindowFrameResolver.topWindowFrame(
            in: windowList,
            preferredProcessIdentifier: preferredPID,
            excludedProcessIdentifiers: [excludedPID]
        )

        let resolvedFrame = try XCTUnwrap(frame)
        XCTAssertEqual(resolvedFrame.minX, 320, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.minY, 180, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.width, 900, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.height, 640, accuracy: 0.5)
    }

    func testTopWindowFrameFallsBackToTopmostNonExcludedWindow() throws {
        let excludedPID: pid_t = 77
        let expectedBounds = ["X": 180, "Y": 120, "Width": 860, "Height": 540] as NSDictionary

        let windowList: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: excludedPID,
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 500, "Height": 500] as NSDictionary
            ],
            [
                kCGWindowOwnerPID as String: 55,
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: expectedBounds
            ]
        ]

        let frame = ActiveWindowFrameResolver.topWindowFrame(
            in: windowList,
            preferredProcessIdentifier: nil,
            excludedProcessIdentifiers: [excludedPID]
        )

        let resolvedFrame = try XCTUnwrap(frame)
        XCTAssertEqual(resolvedFrame.minX, 180, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.minY, 120, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.width, 860, accuracy: 0.5)
        XCTAssertEqual(resolvedFrame.height, 540, accuracy: 0.5)
    }
}
