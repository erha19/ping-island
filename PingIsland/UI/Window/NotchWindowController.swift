//
//  NotchWindowController.swift
//  PingIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    enum WindowOrderAction: Equatable {
        case none
        case orderFront
        case restoreOnActiveSpace
    }

    enum WindowPresentationUpdateSource: Equatable {
        case stateChange
        case environmentChange
        case activeSpaceChange
    }

    struct WindowPresentationPlan: Equatable {
        let orderAction: WindowOrderAction
        let ignoresMouseEvents: Bool
        let shouldActivateApplication: Bool
    }

    let viewModel: NotchViewModel
    private let fullWindowFrame: NSRect
    private var cancellables = Set<AnyCancellable>()

    init(
        screen: NSScreen,
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        performBootAnimation: Bool
    ) {
        self.viewModel = viewModel

        let screenFrame = screen.frame

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )
        self.fullWindowFrame = windowFrame

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor
        )
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: capture input while the pointer is over the notch, before mouse-down.
        // - Opened: ignoresMouseEvents = false (buttons inside panel work)
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .stateChange
                )
            }
            .store(in: &cancellables)

        viewModel.$openReason
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .stateChange
                )
            }
            .store(in: &cancellables)

        viewModel.$isFullscreenEdgeRevealActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .environmentChange
                )
            }
            .store(in: &cancellables)

        viewModel.$isFullscreenBrowserHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .environmentChange
                )
            }
            .store(in: &cancellables)

        viewModel.$isIdleAutoHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .environmentChange
                )
            }
            .store(in: &cancellables)

        viewModel.$isQuietBackgroundPresentationActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .environmentChange
                )
            }
            .store(in: &cancellables)

        viewModel.$presentationMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .stateChange
                )
            }
            .store(in: &cancellables)

        EnergyGovernor.shared.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] mode in
                guard let self, let notchWindow, let viewModel else { return }
                viewModel.updateQuietBackgroundPresentationState(isActive: mode == .quietBackground)
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .environmentChange
                )
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(
                    window: notchWindow,
                    viewModel: viewModel,
                    updateSource: .activeSpaceChange
                )
            }
            .store(in: &cancellables)

        // Input routing must not wait for the throttled hover/dwell pipeline:
        // global mouse-down monitors observe clicks only after the menu bar receives them.
        EventMonitors.shared.mouseRoutingLocation
            .sink { [weak self, weak notchWindow, weak viewModel] location in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateMouseEventHandling(
                    window: notchWindow,
                    viewModel: viewModel,
                    pointerLocation: location
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            viewModel.$geometry,
            viewModel.$closedWidth,
            viewModel.$isFullscreenPhysicalNotchCompactActive
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak notchWindow, weak viewModel] _ in
            guard let self, let notchWindow, let viewModel else { return }
            self.updateMouseEventHandling(
                window: notchWindow,
                viewModel: viewModel,
                pointerLocation: NSEvent.mouseLocation
            )
        }
        .store(in: &cancellables)

        // Seed routing from the actual pointer even when it has not moved since launch.
        notchWindow.ignoresMouseEvents = true
        updateWindowPresentation(
            window: notchWindow,
            viewModel: viewModel,
            updateSource: .stateChange
        )

        // Perform boot animation after a brief delay
        if performBootAnimation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateWindowPresentation(
        window: NotchPanel,
        viewModel: NotchViewModel,
        updateSource: WindowPresentationUpdateSource
    ) {
        let shouldHideWindow = viewModel.shouldHideWindowPresentation

        if shouldHideWindow {
            window.ignoresMouseEvents = true
            if window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        if window.frame != fullWindowFrame {
            window.setFrame(fullWindowFrame, display: true)
        }

        let plan = Self.windowPresentationPlan(
            status: viewModel.status,
            openReason: viewModel.openReason,
            isVisible: window.isVisible,
            isOnActiveSpace: window.isOnActiveSpace,
            updateSource: updateSource,
            isPointerInClosedNotch: viewModel.closedScreenRect.insetBy(dx: -10, dy: -5).contains(NSEvent.mouseLocation)
        )

        switch plan.orderAction {
        case .none:
            break
        case .orderFront:
            window.orderFront(nil)
        case .restoreOnActiveSpace:
            // Clear stale visible ordering before restoring the all-Spaces panel.
            if window.isVisible {
                window.orderOut(nil)
            }
            window.orderFrontRegardless()
        }

        window.ignoresMouseEvents = plan.ignoresMouseEvents
        if plan.shouldActivateApplication {
            NSApp.activate(ignoringOtherApps: false)
            window.makeKey()
        }
    }

    private func updateMouseEventHandling(
        window: NotchPanel,
        viewModel: NotchViewModel,
        pointerLocation: CGPoint
    ) {
        let shouldIgnore = viewModel.shouldHideWindowPresentation
            || (viewModel.status != .opened
                && !viewModel.closedScreenRect.insetBy(dx: -10, dy: -5).contains(pointerLocation))
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
        }
    }

    static func windowPresentationPlan(
        status: NotchStatus,
        openReason: NotchOpenReason,
        isVisible: Bool,
        isOnActiveSpace: Bool,
        updateSource: WindowPresentationUpdateSource,
        isPointerInClosedNotch: Bool = false
    ) -> WindowPresentationPlan {
        let orderAction: WindowOrderAction
        if updateSource == .activeSpaceChange && !isOnActiveSpace {
            orderAction = .restoreOnActiveSpace
        } else {
            orderAction = isVisible ? .none : .orderFront
        }

        let isNotificationOpen: Bool
        if case .notification = openReason {
            isNotificationOpen = true
        } else {
            isNotificationOpen = false
        }

        // Space recovery must preserve the foreground app in the newly active Space.
        let shouldActivateApplication = status == .opened
            && !isNotificationOpen
            && updateSource == .stateChange

        return WindowPresentationPlan(
            orderAction: orderAction,
            ignoresMouseEvents: status != .opened && !isPointerInClosedNotch,
            shouldActivateApplication: shouldActivateApplication
        )
    }
}
