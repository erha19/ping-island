//
//  NotchViewModel.swift
//  PingIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published private(set) var openedMeasuredHeight: CGFloat?
    @Published private(set) var isFullscreenEdgeRevealActive = false
    @Published private(set) var isFullscreenPhysicalNotchCompactActive = false
    @Published private(set) var isFullscreenBrowserHiddenActive = false
    @Published private(set) var isIdleAutoHiddenActive = false
    @Published private(set) var isSettingsPopoverPresented = false

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    private static let defaultClosedHeight = ScreenNotchMetrics.fallbackClosedHeight
    private static let defaultClosedWidth: CGFloat = 266
    @Published private(set) var closedWidth: CGFloat

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    var closedHeight: CGFloat {
        usesPhysicalNotchClosedPresentation
            ? deviceNotchRect.height
            : detectedClosedHeight
    }
    var usesPhysicalNotchClosedPresentation: Bool {
        hasPhysicalNotch && isFullscreenPhysicalNotchCompactActive
    }
    var closedSize: CGSize {
        if usesPhysicalNotchClosedPresentation {
            return deviceNotchRect.size
        }
        return CGSize(width: closedWidth, height: closedHeight)
    }
    var closedScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - closedSize.width / 2,
            y: screenRect.maxY - closedSize.height,
            width: closedSize.width,
            height: closedSize.height
        )
    }

    private var detectedClosedHeight: CGFloat {
        guard hasPhysicalNotch else { return Self.defaultClosedHeight }
        let systemHeight = ceil(deviceNotchRect.height)
        return systemHeight > 0 ? systemHeight : Self.defaultClosedHeight
    }

    private var detectedClosedWidth: CGFloat {
        Self.detectedClosedWidth(
            deviceNotchRect: deviceNotchRect,
            hasPhysicalNotch: hasPhysicalNotch
        )
    }

    private static func detectedClosedWidth(
        deviceNotchRect: CGRect,
        hasPhysicalNotch: Bool
    ) -> CGFloat {
        guard hasPhysicalNotch else { return defaultClosedWidth }
        let systemWidth = ceil(deviceNotchRect.width)
        guard systemWidth > 0 else { return defaultClosedWidth }
        return max(defaultClosedWidth, systemWidth)
    }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        let maxAllowedHeight = maximumOpenedHeight

        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width - 64, 600),
                height: maxAllowedHeight
            )
        case .instances:
            let fallbackHeight: CGFloat = openReason == .hover ? 180 : 200
            let measuredHeight = openedMeasuredHeight ?? fallbackHeight
            return CGSize(
                width: openReason == .hover
                    ? min(screenRect.width - 64, 600)
                    : min(screenRect.width * 0.4, 480),
                height: min(maxAllowedHeight, max(closedHeight + 24, measuredHeight))
            )
        }
    }

    private var maximumOpenedHeight: CGFloat {
        let maxPanelHeight = CGFloat(AppSettings.maxPanelHeight)
        let screenLimit = screenRect.height - 120

        if openReason == .hover {
            return min(screenLimit, maxPanelHeight)
        }

        switch contentType {
        case .chat:
            return min(screenLimit, maxPanelHeight)
        case .instances:
            return min(screenLimit, maxPanelHeight)
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events: EventMonitors?
    private let fullscreenActivityProvider: @MainActor (CGRect) -> Bool
    private let fullscreenBrowserHiddenProvider: @MainActor (CGRect) -> Bool
    private let hideInFullscreenProvider: @MainActor () -> Bool
    private let autoHideWhenIdleProvider: @MainActor () -> Bool
    private var hoverTimer: DispatchWorkItem?
    // Keep hover previews feeling responsive without making incidental cursor
    // passes over the notch expand it too aggressively.
    private let defaultHoverActivationDelay: TimeInterval = 0.24
    private let fullscreenHoverActivationDelay: TimeInterval = 0.18
    private let fullscreenRevealZoneHeight: CGFloat = 8
    private let fullscreenRevealZoneHorizontalInset: CGFloat = 36
    private let fullscreenStateSettleDelay: TimeInterval
    private var fullscreenPhysicalNotchCollapseWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool,
        enableEventMonitoring: Bool = true,
        observeSystemEnvironment: Bool = true,
        fullscreenActivityProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenAppActive,
        hideInFullscreenProvider: @escaping @MainActor () -> Bool = { AppSettings.hideInFullscreen },
        fullscreenBrowserHiddenProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenBrowserActive,
        autoHideWhenIdleProvider: @escaping @MainActor () -> Bool = { AppSettings.autoHideWhenIdle },
        fullscreenStateSettleDelay: TimeInterval = 0.18
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedWidth = Self.detectedClosedWidth(
            deviceNotchRect: deviceNotchRect,
            hasPhysicalNotch: hasPhysicalNotch
        )
        self.events = enableEventMonitoring ? EventMonitors.shared : nil
        self.fullscreenActivityProvider = fullscreenActivityProvider
        self.fullscreenBrowserHiddenProvider = fullscreenBrowserHiddenProvider
        self.hideInFullscreenProvider = hideInFullscreenProvider
        self.autoHideWhenIdleProvider = autoHideWhenIdleProvider
        self.fullscreenStateSettleDelay = fullscreenStateSettleDelay
        if enableEventMonitoring {
            setupEventHandlers()
        }
        if observeSystemEnvironment {
            observeEnvironment()
        }
        refreshFullscreenPresentationState()
    }

    private func observeEnvironment() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$hideInFullscreen
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideWhenIdle
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$maxPanelHeight
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func refreshFullscreenPresentationState() {
        let isFullscreenActive = fullscreenActivityProvider(screenRect)
        let shouldHideForFullscreenBrowser = fullscreenBrowserHiddenProvider(screenRect)
        let shouldUseEdgeReveal = shouldUseFullscreenEdgeReveal(isFullscreenActive: isFullscreenActive)
        let shouldUsePhysicalNotchCompact = shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive)

        if shouldHideForFullscreenBrowser != isFullscreenBrowserHiddenActive {
            isFullscreenBrowserHiddenActive = shouldHideForFullscreenBrowser
        }

        applyPhysicalNotchFullscreenState(shouldUsePhysicalNotchCompact)

        guard shouldUseEdgeReveal != isFullscreenEdgeRevealActive else { return }
        isFullscreenEdgeRevealActive = shouldUseEdgeReveal

        if shouldUseEdgeReveal {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }

        if shouldHideForFullscreenBrowser {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }
    }

    func refreshFullscreenPresentationStateForTesting() {
        refreshFullscreenPresentationState()
    }

    private func applyPhysicalNotchFullscreenState(_ shouldUsePhysicalNotchCompact: Bool) {
        if shouldUsePhysicalNotchCompact {
            fullscreenPhysicalNotchCollapseWorkItem?.cancel()
            fullscreenPhysicalNotchCollapseWorkItem = nil
            if !isFullscreenPhysicalNotchCompactActive {
                isFullscreenPhysicalNotchCompactActive = true
            }
            return
        }

        guard isFullscreenPhysicalNotchCompactActive else { return }

        fullscreenPhysicalNotchCollapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenPhysicalNotchCollapseWorkItem = nil
            let isFullscreenActive = self.fullscreenActivityProvider(self.screenRect)
            if self.shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive) {
                self.isFullscreenPhysicalNotchCompactActive = true
            } else {
                self.isFullscreenPhysicalNotchCompactActive = false
            }
        }
        fullscreenPhysicalNotchCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenStateSettleDelay, execute: workItem)
    }

    private func shouldUseFullscreenEdgeReveal(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider() && !hasPhysicalNotch && isFullscreenActive
    }

    private func shouldUsePhysicalNotchCompact(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider()
            && hasPhysicalNotch
            && isFullscreenActive
            && !isFullscreenBrowserHiddenActive
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        guard let events else { return }

        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDown(event)
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = isPointInHoverTrigger(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        if !newHovering,
           status == .opened,
           openReason == .hover,
           !isSettingsPopoverPresented,
           AppSettings.autoCollapseOnLeave {
            notchClose()
        }

        // Start hover timer to auto-expand after a short dwell
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.performDeferredHoverOpenIfNeeded()
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverActivationDelay, execute: workItem)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        if isSettingsPopoverPresented {
            return
        }

        if MouseEventReplay.isReplayed(event) {
            return
        }

        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                // The panel window already handles click-through replay for intercepted clicks.
                notchClose()
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed, .popping:
            if isPointInHoverTrigger(location) {
                notchOpen(reason: .click)
            }
        }
    }

    private var hoverActivationDelay: TimeInterval {
        isFullscreenEdgeRevealActive ? fullscreenHoverActivationDelay : defaultHoverActivationDelay
    }

    var shouldHideWindowPresentation: Bool {
        if isFullscreenBrowserHiddenActive {
            return true
        }
        if isFullscreenEdgeRevealActive && status != .opened {
            return true
        }
        if isIdleAutoHiddenActive && status != .opened {
            return true
        }
        return false
    }

    var shouldHideClosedPresentation: Bool {
        shouldHideWindowPresentation
    }

    var shouldSuppressAutomaticPresentation: Bool {
        isFullscreenBrowserHiddenActive || (isFullscreenEdgeRevealActive && status != .opened)
    }

    var closedPresentationOffsetY: CGFloat {
        shouldHideWindowPresentation ? -(closedHeight + 12) : 0
    }

    func isPointInHoverTrigger(_ point: CGPoint) -> Bool {
        if shouldHideClosedPresentation {
            return fullscreenRevealTriggerRect.contains(point)
        }
        return isPointInClosedNotch(point)
    }

    private func isPointInClosedNotch(_ point: CGPoint) -> Bool {
        closedScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    func updateIdleAutoHiddenState(hasVisibleSessionActivity: Bool) {
        let shouldHide = autoHideWhenIdleProvider() && !hasVisibleSessionActivity
        if shouldHide != isIdleAutoHiddenActive {
            isIdleAutoHiddenActive = shouldHide
        }
    }

    private var fullscreenRevealTriggerRect: CGRect {
        let width = closedSize.width + (fullscreenRevealZoneHorizontalInset * 2)
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - fullscreenRevealZoneHeight,
            width: width,
            height: fullscreenRevealZoneHeight
        )
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        hoverTimer?.cancel()
        hoverTimer = nil

        if reason == .notification && shouldSuppressAutomaticPresentation {
            return
        }

        openReason = reason
        status = .opened
        if case .instances = contentType {
            openedMeasuredHeight = nil
        }

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Hover opens a lightweight preview instead of restoring the full chat view.
        if reason == .hover {
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func performDeferredHoverOpenIfNeeded() {
        guard isHovering else { return }
        guard status == .closed || status == .popping else { return }
        notchOpen(reason: .hover)
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
        openedMeasuredHeight = nil
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func setSettingsPopoverPresented(_ isPresented: Bool) {
        isSettingsPopoverPresented = isPresented
    }

    func showChat(for session: SessionState) {
        currentChatSession = session
        openedMeasuredHeight = nil

        // Avoid unnecessary updates only when the snapshot is already current.
        if case .chat(let current) = contentType, current == session {
            return
        }
        contentType = .chat(session)
    }

    func presentChat(for session: SessionState, reason: NotchOpenReason = .click) {
        notchOpen(reason: reason)
        showChat(for: session)
    }

    func toggleChat(for session: SessionState, reason: NotchOpenReason = .click) {
        if status == .opened,
           case .chat(let currentSession) = contentType,
           currentSession.sessionId == session.sessionId {
            notchClose()
            return
        }

        presentChat(for: session, reason: reason)
    }

    /// Surface a session from an automatic notification without collapsing first.
    /// This keeps attention-driven panel refreshes stable when the notch is already open.
    func presentNotificationChat(for session: SessionState) {
        notchOpen(reason: .notification)
        showChat(for: session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
    }

    func presentSessionList(reason: NotchOpenReason = .click) {
        exitChat()
        notchOpen(reason: reason)
    }

    func toggleSessionList(reason: NotchOpenReason = .click) {
        if status == .opened,
           reason == .click,
           openReason == .click,
           case .instances = contentType {
            notchClose()
            return
        }

        presentSessionList(reason: reason)
    }

    func updateOpenedMeasuredHeight(_ height: CGFloat?) {
        let sanitized = height.map { max(closedHeight, ceil($0)) }

        guard sanitized != openedMeasuredHeight else { return }
        openedMeasuredHeight = sanitized
    }

    func setManualAttentionActive(_ isActive: Bool) {
        let targetWidth = detectedClosedWidth
        guard closedWidth != targetWidth else { return }
        closedWidth = targetWidth
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        guard !shouldSuppressAutomaticPresentation else { return }
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
