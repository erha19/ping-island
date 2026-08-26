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
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
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

        // Start with ignoring mouse events (closed state)
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
            updateSource: updateSource
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

    static func windowPresentationPlan(
        status: NotchStatus,
        openReason: NotchOpenReason,
        isVisible: Bool,
        isOnActiveSpace: Bool,
        updateSource: WindowPresentationUpdateSource
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
            ignoresMouseEvents: status != .opened,
            shouldActivateApplication: shouldActivateApplication
        )
    }
}
