import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class NotchViewControllerTransparencyTests: XCTestCase {
    func testPassThroughHostingViewStaysTransparent() throws {
        let viewModel = NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            windowHeight: 750,
            hasPhysicalNotch: true,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )

        let controller = NotchViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.view.isOpaque)
        XCTAssertTrue(controller.view.wantsLayer)

        let layer = try XCTUnwrap(controller.view.layer)
        XCTAssertFalse(layer.isOpaque)
        XCTAssertTrue(
            layer.backgroundColor == NSColor.clear.cgColor,
            "Expected the hosting view to keep a clear layer background"
        )
    }
}
