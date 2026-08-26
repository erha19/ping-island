import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class NotchWindowControllerTests: XCTestCase {
    func testNotchPanelRemainsAvailableAcrossSpacesAndStationaryInMissionControl() {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testActiveSpaceChangePlansRestoreWithoutActivation() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .opened,
            openReason: .click,
            isVisible: true,
            isOnActiveSpace: false,
            updateSource: .activeSpaceChange
        )

        XCTAssertEqual(plan.orderAction, .restoreOnActiveSpace)
        XCTAssertFalse(plan.ignoresMouseEvents)
        XCTAssertFalse(plan.shouldActivateApplication)
    }

    func testActiveSpaceChangePlansNoActionWhenWindowIsAlreadyOnActiveSpace() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .opened,
            openReason: .click,
            isVisible: true,
            isOnActiveSpace: true,
            updateSource: .activeSpaceChange
        )

        XCTAssertEqual(plan.orderAction, .none)
        XCTAssertFalse(plan.shouldActivateApplication)
    }

    func testFullscreenEnvironmentChangeDoesNotActivateApplication() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .opened,
            openReason: .click,
            isVisible: true,
            isOnActiveSpace: true,
            updateSource: .environmentChange
        )

        XCTAssertEqual(plan.orderAction, .none)
        XCTAssertFalse(plan.ignoresMouseEvents)
        XCTAssertFalse(plan.shouldActivateApplication)
    }

    func testStateChangePlansNormalFrontOrderingForHiddenWindow() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .closed,
            openReason: .unknown,
            isVisible: false,
            isOnActiveSpace: true,
            updateSource: .stateChange
        )

        XCTAssertEqual(plan.orderAction, .orderFront)
        XCTAssertTrue(plan.ignoresMouseEvents)
        XCTAssertFalse(plan.shouldActivateApplication)
    }

    func testStateChangePlansNoOrderingForVisibleWindow() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .closed,
            openReason: .unknown,
            isVisible: true,
            isOnActiveSpace: false,
            updateSource: .stateChange
        )

        XCTAssertEqual(plan.orderAction, .none)
        XCTAssertFalse(plan.shouldActivateApplication)
    }

    func testNormalOpenedClickUpdateActivatesApplication() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .opened,
            openReason: .click,
            isVisible: true,
            isOnActiveSpace: true,
            updateSource: .stateChange
        )

        XCTAssertFalse(plan.ignoresMouseEvents)
        XCTAssertTrue(plan.shouldActivateApplication)
    }

    func testNormalNotificationUpdateDoesNotActivateApplication() {
        let plan = NotchWindowController.windowPresentationPlan(
            status: .opened,
            openReason: .notification,
            isVisible: true,
            isOnActiveSpace: true,
            updateSource: .stateChange
        )

        XCTAssertFalse(plan.ignoresMouseEvents)
        XCTAssertFalse(plan.shouldActivateApplication)
    }
}
