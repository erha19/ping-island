import CoreGraphics
import XCTest
@testable import Ping_Island

final class NotchViewModelTests: XCTestCase {
    func testPresentNotificationChatOpensClosedNotchAndShowsTargetSession() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "approval-session")

            viewModel.presentNotificationChat(for: session)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .chat(session))
        }
    }

    func testPresentNotificationChatKeepsOpenedNotchExpandedWhileSwitchingSessions() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let originalSession = makeSession(id: "original-session")
            let refreshedSession = makeSession(id: "refreshed-session")

            viewModel.notchOpen(reason: .notification)
            viewModel.showChat(for: originalSession)

            viewModel.presentNotificationChat(for: refreshedSession)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .chat(refreshedSession))
        }
    }

    func testDeferredHoverOpenDoesNotOverrideActiveNotificationPresentation() async {
        await MainActor.run {
            let viewModel = makeViewModel()

            viewModel.isHovering = true
            viewModel.notchOpen(reason: .notification)
            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testPresentSessionListClearsSavedChatAndOpensManualList() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "chat-session")

            viewModel.showChat(for: session)
            viewModel.presentSessionList(reason: .click)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testClosedHeightUsesDetectedSystemNotchHeight() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false }
            )

            XCTAssertEqual(viewModel.closedHeight, 38)
            XCTAssertEqual(viewModel.closedSize, CGSize(width: 266, height: 38))
        }
    }

    func testClosedWidthExpandsToCoverWiderDetectedSystemNotch() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 312, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false }
            )

            XCTAssertEqual(viewModel.closedWidth, 312)
            XCTAssertEqual(viewModel.closedSize, CGSize(width: 312, height: 38))
        }
    }

    func testPresentChatOpensClickedNotchAndShowsTargetSession() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "focus-session")

            viewModel.presentChat(for: session, reason: .click)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
            XCTAssertEqual(viewModel.contentType, .chat(session))
        }
    }

    func testPhysicalNotchFullscreenStateWaitsForStableExitSignal() async {
        var isFullscreenActive = true

        let viewModel = await MainActor.run {
            NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in isFullscreenActive },
                fullscreenStateSettleDelay: 0.05
            )
        }

        await MainActor.run {
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)
            isFullscreenActive = false
            viewModel.refreshFullscreenPresentationStateForTesting()
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)
        }

        try? await Task.sleep(nanoseconds: 120_000_000)

        await MainActor.run {
            XCTAssertFalse(viewModel.isFullscreenPhysicalNotchCompactActive)
        }
    }

    func testPhysicalNotchFullscreenStateIgnoresTransientWindowAnimationGap() async {
        var isFullscreenActive = true

        let viewModel = await MainActor.run {
            NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in isFullscreenActive },
                fullscreenStateSettleDelay: 0.05
            )
        }

        await MainActor.run {
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)
            isFullscreenActive = false
            viewModel.refreshFullscreenPresentationStateForTesting()
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        await MainActor.run {
            isFullscreenActive = true
            viewModel.refreshFullscreenPresentationStateForTesting()
        }

        try? await Task.sleep(nanoseconds: 120_000_000)

        await MainActor.run {
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)
        }
    }

    func testPhysicalNotchFullscreenStateRespectsHideInFullscreenDisabled() async {
        var isFullscreenActive = true
        var hideInFullscreen = false

        let viewModel = await MainActor.run {
            NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in isFullscreenActive },
                hideInFullscreenProvider: { hideInFullscreen }
            )
        }

        await MainActor.run {
            XCTAssertFalse(viewModel.isFullscreenPhysicalNotchCompactActive)

            hideInFullscreen = true
            viewModel.refreshFullscreenPresentationStateForTesting()
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)

            hideInFullscreen = false
            viewModel.refreshFullscreenPresentationStateForTesting()
            XCTAssertTrue(viewModel.isFullscreenPhysicalNotchCompactActive)
        }

        try? await Task.sleep(nanoseconds: 220_000_000)

        await MainActor.run {
            XCTAssertFalse(viewModel.isFullscreenPhysicalNotchCompactActive)
        }
    }

    func testFullscreenBrowserHidesWindowPresentationEvenOnPhysicalNotch() async {
        let viewModel = await MainActor.run {
            NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in true },
                fullscreenBrowserHiddenProvider: { _ in true }
            )
        }

        await MainActor.run {
            XCTAssertTrue(viewModel.isFullscreenBrowserHiddenActive)
            XCTAssertTrue(viewModel.shouldHideWindowPresentation)
            XCTAssertTrue(viewModel.shouldSuppressAutomaticPresentation)
        }
    }

    func testIdleAutoHideTracksVisibleSessionActivity() async {
        let viewModel = await MainActor.run {
            NotchViewModel(
                deviceNotchRect: .zero,
                screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                windowHeight: 320,
                hasPhysicalNotch: false,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                autoHideWhenIdleProvider: { true }
            )
        }

        await MainActor.run {
            viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: false)
            XCTAssertTrue(viewModel.isIdleAutoHiddenActive)
            XCTAssertTrue(viewModel.shouldHideWindowPresentation)

            viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: true)
            XCTAssertFalse(viewModel.isIdleAutoHiddenActive)
            XCTAssertFalse(viewModel.shouldHideWindowPresentation)
        }
    }

    func testToggleChatClosesWhenSameSessionIsAlreadyVisible() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "focus-session")

            viewModel.presentChat(for: session, reason: .click)
            viewModel.toggleChat(for: session, reason: .click)

            XCTAssertEqual(viewModel.status, .closed)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testToggleSessionListClosesManualListWhenAlreadyOpen() async {
        await MainActor.run {
            let viewModel = makeViewModel()

            viewModel.presentSessionList(reason: .click)
            viewModel.toggleSessionList(reason: .click)

            XCTAssertEqual(viewModel.status, .closed)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    @MainActor
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )
    }

    private func makeSession(id: String) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)"
        )
    }
}
