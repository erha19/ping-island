import AppKit
import Combine
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

    func testClosingDetailViewResetsToSessionListForNextManualOpen() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "focus-session")

            viewModel.presentChat(for: session, reason: .click)
            viewModel.notchClose()
            viewModel.notchOpen(reason: .click)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .click)
            XCTAssertEqual(viewModel.contentType, .instances)
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

    func testDetachmentGestureRequiresDownwardDominantThreshold() {
        XCTAssertFalse(
            IslandDetachmentGestureGate.qualifies(
                start: CGPoint(x: 200, y: 400),
                current: CGPoint(x: 205, y: 385),
                hasSatisfiedLongPress: true
            )
        )
        XCTAssertFalse(
            IslandDetachmentGestureGate.qualifies(
                start: CGPoint(x: 200, y: 400),
                current: CGPoint(x: 246, y: 360),
                hasSatisfiedLongPress: true
            )
        )
        XCTAssertFalse(
            IslandDetachmentGestureGate.qualifies(
                start: CGPoint(x: 200, y: 400),
                current: CGPoint(x: 210, y: 360),
                hasSatisfiedLongPress: false
            )
        )
        XCTAssertTrue(
            IslandDetachmentGestureGate.qualifies(
                start: CGPoint(x: 200, y: 400),
                current: CGPoint(x: 210, y: 360),
                hasSatisfiedLongPress: true
            )
        )
    }

    func testDetachmentTriggerScreenRectUsesFixedPhysicalNotchRegion() async {
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

            XCTAssertEqual(viewModel.detachmentTriggerScreenRect, viewModel.geometry.notchScreenRect)
        }
    }

    func testDockedDetachmentLongPressNarrowsClosedWidthUntilCancelled() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let initialWidth = viewModel.closedWidth

            XCTAssertFalse(viewModel.isDetachmentNarrowingClosedNotch)
            XCTAssertFalse(viewModel.isDetachmentGestureActive)
            viewModel.beginDockedDetachmentTrackingForTesting()

            XCTAssertTrue(viewModel.isDetachmentNarrowingClosedNotch)
            XCTAssertTrue(viewModel.isDetachmentGestureActive)
            XCTAssertLessThan(viewModel.closedWidth, initialWidth)

            viewModel.cancelDockedDetachmentTrackingForTesting()
            XCTAssertFalse(viewModel.isDetachmentNarrowingClosedNotch)
            XCTAssertFalse(viewModel.isDetachmentGestureActive)
            XCTAssertEqual(viewModel.closedWidth, initialWidth)
        }
    }

    func testDockedDetachmentLongPressNarrowsToPhysicalNotchWidth() async {
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

            viewModel.beginDockedDetachmentTrackingForTesting()

            XCTAssertEqual(viewModel.closedWidth, 220)
        }
    }

    func testBeginDetachedPresentationResetsLongPressNarrowedWidth() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let initialWidth = viewModel.closedWidth

            viewModel.beginDockedDetachmentTrackingForTesting()
            XCTAssertLessThan(viewModel.closedWidth, initialWidth)

            viewModel.beginDetachedPresentation(contentType: .instances, playSound: false)
            XCTAssertEqual(viewModel.closedWidth, initialWidth)
        }
    }

    func testDetachedSizeShrinksComparedToDockedOpenedSize() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "chat-size")

            viewModel.presentChat(for: session, reason: .click)

            XCTAssertLessThan(viewModel.detachedSize.width, viewModel.openedSize.width)
            XCTAssertLessThan(viewModel.detachedSize.height, viewModel.openedSize.height)
        }
    }

    func testBeginDetachedPresentationStartsInCompactInstancesMode() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "preserved-chat")

            viewModel.beginDetachedPresentation(contentType: .chat(session))

            XCTAssertEqual(viewModel.presentationMode, .detached)
            XCTAssertEqual(viewModel.detachedDisplayMode, .compact)
            XCTAssertEqual(viewModel.contentType, .instances)

            viewModel.redockAfterDetached()
            viewModel.notchOpen(reason: .click)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testCompactDetachedSizeMatchesClosedNotchSize() async {
        await MainActor.run {
            let originalMode = AppSettings.notchDisplayMode
            defer { AppSettings.notchDisplayMode = originalMode }

            let viewModel = makeViewModel()
            AppSettings.notchDisplayMode = .detailed

            viewModel.beginDetachedPresentation(contentType: .instances)

            XCTAssertEqual(viewModel.detachedDisplayMode, .compact)
            XCTAssertEqual(viewModel.detachedSize, viewModel.closedSize)
        }
    }

    func testCompactDetachedSizeShrinksToOrbWhenDetailDisplayIsDisabled() async {
        await MainActor.run {
            let originalMode = AppSettings.notchDisplayMode
            defer { AppSettings.notchDisplayMode = originalMode }

            let viewModel = makeViewModel()
            AppSettings.notchDisplayMode = .compact

            viewModel.beginDetachedPresentation(contentType: .instances)

            XCTAssertEqual(viewModel.detachedDisplayMode, .compact)
            XCTAssertLessThan(viewModel.detachedSize.width, viewModel.closedSize.width)
            XCTAssertEqual(viewModel.detachedSize.width, viewModel.detachedSize.height)
        }
    }

    func testExpandedDetachedSizeIgnoresMeasuredHeightFeedback() async {
        await MainActor.run {
            let viewModel = makeViewModel()

            viewModel.beginDetachedPresentation(contentType: .instances)
            viewModel.setDetachedDisplayMode(.hoverExpanded)

            let baselineSize = viewModel.detachedSize

            viewModel.updateOpenedMeasuredHeight(280)
            viewModel.updateOpenedMeasuredHeight(320)

            XCTAssertEqual(viewModel.detachedSize, baselineSize)
        }
    }

    func testDetachedContentResolverPrefersAttentionThenActivity() {
        let now = Date()
        let active = SessionState(
            sessionId: "active",
            cwd: "/tmp/active",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-20)
        )
        let attention = SessionState(
            sessionId: "attention",
            cwd: "/tmp/attention",
            phase: .waitingForInput,
            lastActivity: now.addingTimeInterval(-60)
        )

        let resolved = IslandDetachedContentResolver.resolve(
            status: .closed,
            openReason: .unknown,
            contentType: .instances,
            sessions: [active, attention]
        )

        XCTAssertEqual(resolved, .chat(attention))
    }

    func testDetachedContentResolverNormalizesNotificationPreviewToStableDetail() {
        let target = SessionState(
            sessionId: "latest",
            cwd: "/tmp/latest",
            phase: .processing
        )

        let resolved = IslandDetachedContentResolver.resolve(
            status: .opened,
            openReason: .notification,
            contentType: .instances,
            sessions: [target]
        )

        XCTAssertEqual(resolved, .chat(target))
    }

    func testIslandMascotResolverFallsBackToDefaultWhenOnlyIdleHistoryRemains() {
        let idle = SessionState(
            sessionId: "idle",
            cwd: "/tmp/idle",
            phase: .idle,
            lastActivity: Date()
        )

        XCTAssertNil(IslandMascotResolver.sourceSession(from: [idle]))
    }

    func testIslandMascotResolverPrefersFreshAttentionOrActiveSessions() {
        let now = Date()
        let idle = SessionState(
            sessionId: "idle",
            cwd: "/tmp/idle",
            phase: .idle,
            lastActivity: now
        )
        let active = SessionState(
            sessionId: "active",
            cwd: "/tmp/active",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-20)
        )
        let attention = SessionState(
            sessionId: "attention",
            cwd: "/tmp/attention",
            phase: .waitingForInput,
            lastActivity: now.addingTimeInterval(-5)
        )

        XCTAssertEqual(
            IslandMascotResolver.sourceSession(from: [idle, active, attention])?.sessionId,
            "attention"
        )
    }

    func testRedockAfterDetachedRestoresClosedDockedStateAndResetsDetailSelection() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "detached-chat")

            viewModel.beginDetachedPresentation(contentType: .chat(session))
            viewModel.redockAfterDetached()

            XCTAssertEqual(viewModel.presentationMode, .docked)
            XCTAssertEqual(viewModel.status, .closed)
            XCTAssertEqual(viewModel.contentType, .instances)

            viewModel.notchOpen(reason: .click)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testEventMonitorsRebuildAllMonitorsOnWakeNotification() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let workspaceNotificationCenter = NotificationCenter()
            let recorder = MonitorRecorder()

            let monitors = EventMonitors(
                notificationCenter: notificationCenter,
                workspaceNotificationCenter: workspaceNotificationCenter,
                currentMouseLocation: { CGPoint(x: 40, y: 24) },
                monitorFactory: recorder.makeMonitor(mask:handler:)
            )

            XCTAssertEqual(recorder.createdMasks, [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
            XCTAssertEqual(recorder.startedMasks, [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])

            workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

            XCTAssertEqual(
                recorder.createdMasks,
                [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            )
            XCTAssertEqual(recorder.stopCallCount, 4)
            XCTAssertEqual(monitors.mouseLocation.value, CGPoint(x: 40, y: 24))
        }
    }

    func testEventMonitorsRebuildAllMonitorsOnAppActivation() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let workspaceNotificationCenter = NotificationCenter()
            let recorder = MonitorRecorder()

            let monitors = EventMonitors(
                notificationCenter: notificationCenter,
                workspaceNotificationCenter: workspaceNotificationCenter,
                currentMouseLocation: { .zero },
                monitorFactory: recorder.makeMonitor(mask:handler:)
            )

            notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

            XCTAssertEqual(recorder.stopCallCount, 4)
            XCTAssertEqual(
                recorder.startedMasks,
                [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            )
            XCTAssertEqual(monitors.mouseLocation.value, .zero)
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

private final class MonitorRecorder {
    private(set) var createdMasks: [NSEvent.EventTypeMask] = []
    private(set) var startedMasks: [NSEvent.EventTypeMask] = []
    private(set) var stopCallCount = 0

    func makeMonitor(
        mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> EventMonitoring {
        createdMasks.append(mask)
        return FakeEventMonitor(
            mask: mask,
            startHook: { [weak self] mask in
                self?.startedMasks.append(mask)
            },
            stopHook: { [weak self] in
                self?.stopCallCount += 1
            },
            handler: handler
        )
    }
}

private final class FakeEventMonitor: EventMonitoring {
    private let mask: NSEvent.EventTypeMask
    private let startHook: (NSEvent.EventTypeMask) -> Void
    private let stopHook: () -> Void
    let handler: (NSEvent) -> Void

    init(
        mask: NSEvent.EventTypeMask,
        startHook: @escaping (NSEvent.EventTypeMask) -> Void,
        stopHook: @escaping () -> Void,
        handler: @escaping (NSEvent) -> Void
    ) {
        self.mask = mask
        self.startHook = startHook
        self.stopHook = stopHook
        self.handler = handler
    }

    func start() {
        startHook(mask)
    }

    func stop() {
        stopHook()
    }
}
