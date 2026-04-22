import AppKit
import Combine
import SwiftUI

final class DetachedIslandWindow: NSWindow {
    var petMouseDownHandler: ((NSEvent) -> Bool)?
    var petMouseDraggedHandler: ((NSEvent) -> Bool)?
    var petMouseUpHandler: ((NSEvent) -> Bool)?
    var petRightMouseDownHandler: ((NSEvent) -> Bool)?
    var petRightMouseUpHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        let handled: Bool = switch event.type {
        case .leftMouseDown:
            petMouseDownHandler?(event) ?? false
        case .leftMouseDragged:
            petMouseDraggedHandler?(event) ?? false
        case .leftMouseUp:
            petMouseUpHandler?(event) ?? false
        case .rightMouseDown:
            petRightMouseDownHandler?(event) ?? false
        case .rightMouseUp:
            petRightMouseUpHandler?(event) ?? false
        default:
            false
        }

        guard !handled else { return }
        super.sendEvent(event)
    }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func configureTransparency() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

@MainActor
final class DetachedIslandViewController: NSViewController {
    private let viewModel: NotchViewModel
    private let sessionMonitor: SessionMonitor
    private let interactionModel: DetachedIslandInteractionModel
    private let bubbleViewState: DetachedIslandBubbleViewState
    private let onClose: () -> Void
    var onPetTap: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragStarted: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragChanged: (CGSize) -> Void = { _ in } {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragEnded: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onAttentionActionCompleted: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onCompletionNotificationHoverChanged: (Bool) -> Void = { _ in } {
        didSet { refreshRootViewIfLoaded() }
    }
    var onDismissCompletionNotification: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    private var hostingView: TransparentHostingView<AppLocalizedRootView<DetachedIslandPanelView>>!

    init(
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        interactionModel: DetachedIslandInteractionModel,
        bubbleViewState: DetachedIslandBubbleViewState,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.sessionMonitor = sessionMonitor
        self.interactionModel = interactionModel
        self.bubbleViewState = bubbleViewState
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = TransparentHostingView(rootView: makeRootView())

        self.view = hostingView
    }

    private func makeRootView() -> AppLocalizedRootView<DetachedIslandPanelView> {
        AppLocalizedRootView {
            DetachedIslandPanelView(
                viewModel: viewModel,
                sessionMonitor: sessionMonitor,
                interactionModel: interactionModel,
                bubbleViewState: bubbleViewState,
                onClose: onClose,
                onPetTap: onPetTap,
                onPetDragStarted: onPetDragStarted,
                onPetDragChanged: onPetDragChanged,
                onPetDragEnded: onPetDragEnded,
                onAttentionActionCompleted: onAttentionActionCompleted,
                onCompletionNotificationHoverChanged: onCompletionNotificationHoverChanged,
                onDismissCompletionNotification: onDismissCompletionNotification
            )
        }
    }

    private func refreshRootViewIfLoaded() {
        guard hostingView != nil else { return }
        hostingView.rootView = makeRootView()
    }
}

@MainActor
final class DetachedIslandWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultTrailingInset: CGFloat = 32
    private static let defaultBottomInset: CGFloat = 48

    private let viewModel: NotchViewModel
    private let sessionMonitor: SessionMonitor
    private let onClose: () -> Void
    private let onPetAnchorChanged: (CGPoint) -> Void
    private let interactionModel = DetachedIslandInteractionModel()
    private let bubbleViewState = DetachedIslandBubbleViewState()
    private var manualAttentionTracker = SessionManualAttentionTracker()
    private let detachedViewController: DetachedIslandViewController
    private var lastAppliedLayout: DetachedIslandWindowLayout
    private(set) var highlightedSessionStableID: String?
    private var cancellables = Set<AnyCancellable>()
    private var isWindowSizeUpdateScheduled = false
    private var isApplyingWindowSizeUpdate = false
    private var hasPendingWindowSizeUpdate = false
    private var interactionActivationWorkItem: DispatchWorkItem?
    private var bubbleVisibilityWorkItem: DispatchWorkItem?
    private var completionNotificationDismissWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: EventMonitor?
    private var floatingDragStartOrigin: CGPoint?
    private var petMouseDownPoint: CGPoint?
    private var petMouseDownScreenPoint: CGPoint?
    private var isPetDragActive = false
    private var isPetSecondaryClickArmed = false
    private var hasPrimedSoundTransitions = false
    private var previousProcessingIds = Set<String>()
    private var previousAttentionSoundIds = Set<String>()
    private var previousCompletionSoundIds = Set<String>()
    private var previousTaskErrorIds = Set<String>()
    private var previousResourceLimitIds = Set<String>()
    private var previousCompletionNotificationPhases: [String: SessionPhase] = [:]
    private var completionNotificationQueue: [SessionCompletionNotification] = []
    private var activeCompletionNotification: SessionCompletionNotification? {
        didSet {
            bubbleViewState.setActiveCompletionNotification(activeCompletionNotification)
        }
    }
    private var shouldDismissCompletionNotificationOnHoverExit = false

    init(
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        onClose: @escaping () -> Void,
        onPetAnchorChanged: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.sessionMonitor = sessionMonitor
        self.onClose = onClose
        self.onPetAnchorChanged = onPetAnchorChanged
        self.lastAppliedLayout = Self.windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor
        )

        let initialContentSize = lastAppliedLayout.containerSize
        let hostingController = DetachedIslandViewController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            interactionModel: interactionModel,
            bubbleViewState: bubbleViewState,
            onClose: onClose
        )
        hostingController.loadViewIfNeeded()
        self.detachedViewController = hostingController

        let window = DetachedIslandWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        hostingController.view.frame = NSRect(origin: .zero, size: initialContentSize)
        hostingController.view.autoresizingMask = [.width, .height]
        window.contentView = hostingController.view
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // Keep shadow rendering inside SwiftUI content; window-level shadow on a transparent
        // borderless window produces jagged outlines around the composited alpha edges.
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = true
        // Keep the detached pet visible above fullscreen apps and across spaces.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)

        hostingController.onPetTap = { [weak self, weak interactionModel, weak sessionMonitor] in
            let sessions = sessionMonitor?.instances ?? []
            interactionModel?.togglePrimaryBubble(
                canPresentPreview: DetachedIslandContentModel.canPresentBubble(
                    from: sessions,
                    mode: .hoverPreview,
                    activeCompletionNotification: self?.activeCompletionNotification
                ),
                canPresentPinnedBubble: DetachedIslandContentModel.canPresentBubble(
                    from: sessions,
                    mode: .pinnedList
                )
            )
        }
        hostingController.onPetDragStarted = { [weak self] in
            self?.beginFloatingDrag()
        }
        hostingController.onPetDragChanged = { [weak self] translation in
            self?.updateFloatingDrag(translation: translation)
        }
        hostingController.onPetDragEnded = { [weak self] in
            self?.endFloatingDrag()
        }
        hostingController.onAttentionActionCompleted = { [weak self] in
            self?.dismissAttentionBubble()
        }
        hostingController.onCompletionNotificationHoverChanged = { [weak self] isHovering in
            self?.handleCompletionNotificationHover(isHovering)
        }
        hostingController.onDismissCompletionNotification = { [weak self] in
            self?.dismissActiveCompletionNotification(closeBubble: true, advanceQueue: true)
        }
        window.petMouseDownHandler = { [weak self] event in
            self?.handlePetMouseDown(event) ?? false
        }
        window.petMouseDraggedHandler = { [weak self] event in
            self?.handlePetMouseDragged(event) ?? false
        }
        window.petMouseUpHandler = { [weak self] event in
            self?.handlePetMouseUp(event) ?? false
        }
        window.petRightMouseDownHandler = { [weak self] event in
            self?.handlePetRightMouseDown(event) ?? false
        }
        window.petRightMouseUpHandler = { [weak self] event in
            self?.handlePetRightMouseUp(event) ?? false
        }

        window.delegate = self
        bindWindowSizeUpdates()
        primeCompletionNotificationTracking(sessionMonitor.instances)
        primeSoundTransitions(sessionMonitor.instances)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(at origin: CGPoint) {
        guard let window else { return }
        suppressInteraction()
        lastAppliedLayout = Self.windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification
        )
        let initialFrame = NSRect(
            origin: origin,
            size: lastAppliedLayout.containerSize
        )
        window.setFrame(initialFrame, display: false)
        updateBubblePlacementForCurrentWindow()
        NSApp.activate(ignoringOtherApps: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        presentExistingAttentionIfNeeded()
    }

    func present(atPetAnchor petAnchor: CGPoint) {
        guard let window else { return }
        suppressInteraction()
        lastAppliedLayout = Self.windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification,
            petAnchorScreen: petAnchor,
            availableFrame: availableFrame(for: petAnchor)
        )
        let origin = Self.windowOrigin(
            preservingPetAnchorAt: petAnchor,
            layout: lastAppliedLayout
        )
        let frame = NSRect(origin: origin, size: lastAppliedLayout.containerSize)
        window.setFrame(frame, display: false)
        updateBubblePlacementForCurrentWindow()
        NSApp.activate(ignoringOtherApps: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        presentExistingAttentionIfNeeded()
    }

    var currentPetAnchor: CGPoint? {
        guard let window else { return nil }
        return Self.petAnchorScreenPoint(for: window.frame, layout: lastAppliedLayout)
    }

    var currentExpandedRoute: IslandExpandedRoute? {
        guard let bubbleContentMode = interactionModel.bubbleContentMode else { return nil }
        return DetachedIslandContentModel.route(
            for: sessionMonitor.instances,
            viewModel: viewModel,
            mode: bubbleContentMode,
            activeCompletionNotification: activeCompletionNotification
        )
    }

    func activateInteraction() {
        interactionActivationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            self.interactionActivationWorkItem = nil
            window.ignoresMouseEvents = false
        }

        interactionActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func updateDragPosition(
        cursorLocation: CGPoint,
        cursorWindowOffset: CGPoint
    ) {
        guard let window else { return }
        suppressInteraction()
        interactionModel.resetForDragSuppression()
        hideBubbleRenderingImmediately()
        let contentSize = window.frame.size
        let origin = Self.windowOrigin(
            for: cursorLocation,
            cursorWindowOffset: cursorWindowOffset,
            windowSize: contentSize
        )
        window.setFrameOrigin(origin)
        updateBubblePlacementForCurrentWindow()
    }

    func beginFloatingDrag() {
        guard floatingDragStartOrigin == nil else { return }
        cancelInteractionActivation()
        interactionModel.resetForDragSuppression()
        interactionModel.setPetDragging(true)
        hideBubbleRenderingImmediately()
        floatingDragStartOrigin = window?.frame.origin
    }

    func updateFloatingDrag(translation: CGSize) {
        guard let window else { return }

        if floatingDragStartOrigin == nil {
            beginFloatingDrag()
        }

        guard let startOrigin = floatingDragStartOrigin else { return }
        let origin = CGPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y + translation.height
        )
        window.setFrameOrigin(origin)
        updateBubblePlacementForCurrentWindow()
    }

    func endFloatingDrag() {
        floatingDragStartOrigin = nil
        interactionModel.setPetDragging(false)
        if let currentPetAnchor {
            onPetAnchorChanged(currentPetAnchor)
        }
        activateInteraction()
    }

    func handlePetSecondaryClick() {
        SettingsWindowController.shared.present()
    }

    func presentHoverBubbleForTesting() {
        let canPresentBubble = DetachedIslandContentModel.canPresentBubble(
            from: sessionMonitor.instances,
            mode: .hoverPreview,
            activeCompletionNotification: activeCompletionNotification
        )
        interactionModel.presentHoverPreview(canPresentBubble: canPresentBubble)
        syncBubblePresentation(to: interactionModel.bubbleState)
        syncOutsideClickMonitor()
        reconcileHighlightedSessionState()
    }

    func togglePinnedBubbleForTesting() {
        let canPresentBubble = DetachedIslandContentModel.canPresentBubble(
            from: sessionMonitor.instances,
            mode: .pinnedList
        )
        interactionModel.togglePinned(canPresentBubble: canPresentBubble)
        syncBubblePresentation(to: interactionModel.bubbleState)
        syncOutsideClickMonitor()
        reconcileHighlightedSessionState()
    }

    func hideBubbleForTesting() {
        interactionModel.hidePinnedBubble()
        syncBubblePresentation(to: interactionModel.bubbleState)
        syncOutsideClickMonitor()
        reconcileHighlightedSessionState()
    }

    func dismissAttentionBubble() {
        interactionModel.hidePinnedBubble()
    }

    var renderedBubbleStateForTesting: DetachedIslandBubbleState {
        bubbleViewState.renderedBubbleState
    }

    var isBubbleVisibleForTesting: Bool {
        bubbleViewState.isBubbleVisible
    }

    var isPetDraggingForTesting: Bool {
        interactionModel.isPetDragging
    }

    func applySessionSnapshotForTesting(_ sessions: [SessionState]) {
        sessionMonitor.instances = sessions
        handleManualAttentionChange()
        handleCompletionNotificationChange(sessions)
        handleSessionSoundTransitions(sessions)
        reconcileHighlightedSessionState()
    }

    var currentActiveCompletionNotificationForTesting: SessionCompletionNotification? {
        activeCompletionNotification
    }

    func dismiss() {
        interactionActivationWorkItem?.cancel()
        interactionActivationWorkItem = nil
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil
        completionNotificationDismissWorkItem?.cancel()
        completionNotificationDismissWorkItem = nil
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
        floatingDragStartOrigin = nil
        interactionModel.setPetDragging(false)
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }

    private func bindWindowSizeUpdates() {
        viewModel.$contentType
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        sessionMonitor.$instances
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] instances in
                self?.handleManualAttentionChange()
                self?.handleCompletionNotificationChange(instances)
                self?.handleSessionSoundTransitions(instances)
                self?.reconcileHighlightedSessionState()
                self?.reconcileBubbleStateWithAvailableContent()
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        bubbleViewState.$measuredAttentionBubbleHeight
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        interactionModel.$bubbleState
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bubbleState in
                self?.syncBubblePresentation(to: bubbleState)
                self?.syncOutsideClickMonitor()
                self?.reconcileHighlightedSessionState()
            }
            .store(in: &cancellables)

        interactionModel.$bubblePlacement
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        AppSettings.shared.$notchDisplayMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileHighlightedSessionState()
                self?.reconcileBubbleStateWithAvailableContent()
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoOpenCompletionPanel
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if !isEnabled {
                    self.removeCompletionNotifications(
                        matching: { $0 == .completed || $0 == .ended },
                        keepBubbleOpen: false
                    )
                } else {
                    self.maybePresentNextCompletionNotification()
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoOpenCompactedNotificationPanel
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if !isEnabled {
                    self.removeCompletionNotifications(
                        matching: { $0 == .compacted },
                        keepBubbleOpen: false
                    )
                } else {
                    self.maybePresentNextCompletionNotification()
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$temporarilyMuteNotificationsUntil
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mutedUntil in
                guard let self,
                      AppSettings.isNotificationMuteActive(until: mutedUntil) else { return }
                self.clearCompletionNotifications(keepBubbleOpen: false)
            }
            .store(in: &cancellables)
    }

    private func scheduleWindowSizeUpdate() {
        hasPendingWindowSizeUpdate = true
        guard !isWindowSizeUpdateScheduled else { return }
        isWindowSizeUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isWindowSizeUpdateScheduled = false
                self.applyPendingWindowSizeUpdate()
            }
        }
    }

    private func applyPendingWindowSizeUpdate() {
        guard let window else { return }
        guard hasPendingWindowSizeUpdate else { return }

        if isApplyingWindowSizeUpdate {
            scheduleWindowSizeUpdate()
            return
        }

        hasPendingWindowSizeUpdate = false
        let currentFrame = window.frame
        let petAnchorScreen = Self.petAnchorScreenPoint(
            for: currentFrame,
            layout: lastAppliedLayout
        )
        let newLayout = Self.windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame(for: petAnchorScreen)
        )
        interactionModel.setBubblePlacement(newLayout.bubblePlacement)
        let newOrigin = Self.windowOrigin(
            preservingPetAnchorAt: petAnchorScreen,
            layout: newLayout
        )
        let targetFrame = NSRect(origin: newOrigin, size: newLayout.containerSize)

        guard !Self.framesMatch(currentFrame, targetFrame) else {
            lastAppliedLayout = newLayout
            return
        }

        isApplyingWindowSizeUpdate = true
        window.setFrame(targetFrame, display: false, animate: false)
        isApplyingWindowSizeUpdate = false
        lastAppliedLayout = newLayout

        if hasPendingWindowSizeUpdate {
            scheduleWindowSizeUpdate()
        }
    }

    static func windowLayout(
        for viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        bubbleState: DetachedIslandBubbleState = .hidden,
        bubblePlacement: DetachedIslandBubblePlacement = .topLeft,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        activeCompletionNotification: SessionCompletionNotification? = nil,
        petAnchorScreen: CGPoint? = nil,
        availableFrame: CGRect? = nil
    ) -> DetachedIslandWindowLayout {
        DetachedIslandContentModel.layout(
            for: sessionMonitor.instances,
            viewModel: viewModel,
            bubbleState: bubbleState,
            bubblePlacement: bubblePlacement,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification,
            petScreenAnchor: petAnchorScreen,
            availableFrame: availableFrame
        )
    }

    static func windowSize(
        for viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        bubbleState: DetachedIslandBubbleState = .hidden,
        bubblePlacement: DetachedIslandBubblePlacement = .topLeft,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        activeCompletionNotification: SessionCompletionNotification? = nil,
        petAnchorScreen: CGPoint? = nil,
        availableFrame: CGRect? = nil
    ) -> CGSize {
        windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor,
            bubbleState: bubbleState,
            bubblePlacement: bubblePlacement,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame
        ).containerSize
    }

    static func windowOrigin(
        for cursorLocation: CGPoint,
        cursorWindowOffset: CGPoint,
        windowSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: cursorLocation.x - cursorWindowOffset.x,
            y: cursorLocation.y - min(cursorWindowOffset.y, windowSize.height)
        )
    }

    static func defaultPetAnchor(
        in visibleFrame: CGRect,
        alignedTo activeWindowFrame: CGRect? = nil
    ) -> CGPoint {
        let halfPet = DetachedIslandPanelMetrics.petHitFrame / 2
        let referenceFrame = activeWindowFrame?
            .intersection(visibleFrame)
            .nilIfEmpty ?? visibleFrame

        return CGPoint(
            x: referenceFrame.maxX - defaultTrailingInset - halfPet,
            y: referenceFrame.minY + defaultBottomInset + halfPet
        )
    }

    static func clampedPetAnchor(
        _ petAnchor: CGPoint,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let halfPet = DetachedIslandPanelMetrics.petHitFrame / 2
        let minX = visibleFrame.minX + halfPet
        let maxX = visibleFrame.maxX - halfPet
        let minY = visibleFrame.minY + halfPet
        let maxY = visibleFrame.maxY - halfPet

        let resolvedX = minX <= maxX
            ? min(max(petAnchor.x, minX), maxX)
            : visibleFrame.midX
        let resolvedY = minY <= maxY
            ? min(max(petAnchor.y, minY), maxY)
            : visibleFrame.midY

        return CGPoint(x: resolvedX, y: resolvedY)
    }

    static func floatingPetAnchor(
        from petAnchor: CGPoint,
        in visibleFrame: CGRect
    ) -> FloatingPetAnchor {
        let clampedAnchor = clampedPetAnchor(petAnchor, in: visibleFrame)
        let xRatio = visibleFrame.width > 0
            ? (clampedAnchor.x - visibleFrame.minX) / visibleFrame.width
            : 0.5
        let yRatio = visibleFrame.height > 0
            ? (clampedAnchor.y - visibleFrame.minY) / visibleFrame.height
            : 0.5

        return FloatingPetAnchor(
            xRatio: Double(xRatio),
            yRatio: Double(yRatio)
        )
    }

    static func petAnchor(
        from storedAnchor: FloatingPetAnchor?,
        in visibleFrame: CGRect,
        defaultWindowFrame: CGRect? = nil
    ) -> CGPoint {
        guard let storedAnchor else {
            return clampedPetAnchor(
                defaultPetAnchor(
                    in: visibleFrame,
                    alignedTo: defaultWindowFrame
                ),
                in: visibleFrame
            )
        }

        let rawAnchor = CGPoint(
            x: visibleFrame.minX + (CGFloat(storedAnchor.xRatio) * visibleFrame.width),
            y: visibleFrame.minY + (CGFloat(storedAnchor.yRatio) * visibleFrame.height)
        )
        return clampedPetAnchor(rawAnchor, in: visibleFrame)
    }

    static func petAnchorScreenPoint(
        for frame: NSRect,
        layout: DetachedIslandWindowLayout
    ) -> CGPoint {
        CGPoint(
            x: frame.minX + layout.petAnchorInWindow.x,
            y: frame.maxY - layout.petAnchorInWindow.y
        )
    }

    static func windowOrigin(
        preservingPetAnchorAt petAnchorScreen: CGPoint,
        layout: DetachedIslandWindowLayout
    ) -> CGPoint {
        CGPoint(
            x: petAnchorScreen.x - layout.petAnchorInWindow.x,
            y: petAnchorScreen.y - (layout.containerSize.height - layout.petAnchorInWindow.y)
        )
    }

    static func petInteractionFrame(
        for layout: DetachedIslandWindowLayout
    ) -> CGRect {
        CGRect(
            x: layout.petFrame.minX,
            y: layout.containerSize.height - layout.petFrame.maxY,
            width: layout.petFrame.width,
            height: layout.petFrame.height
        )
    }

    static func floatingDragTranslation(
        from start: CGPoint,
        to current: CGPoint
    ) -> CGSize {
        CGSize(
            width: current.x - start.x,
            height: current.y - start.y
        )
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
        abs(lhs.size.width - rhs.size.width) < 0.5 &&
        abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private func suppressInteraction() {
        cancelInteractionActivation()
        window?.ignoresMouseEvents = true
    }

    private func cancelInteractionActivation() {
        interactionActivationWorkItem?.cancel()
        interactionActivationWorkItem = nil
    }

    private func handlePetMouseDown(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard isPointInsidePet(point) else { return false }
        petMouseDownPoint = point
        petMouseDownScreenPoint = screenPoint(for: event)
        isPetDragActive = false
        return true
    }

    private func handlePetMouseDragged(_ event: NSEvent) -> Bool {
        guard petMouseDownPoint != nil,
              let petMouseDownScreenPoint else { return false }

        let currentScreenPoint = screenPoint(for: event)
        let translation = Self.floatingDragTranslation(
            from: petMouseDownScreenPoint,
            to: currentScreenPoint
        )

        if !isPetDragActive,
           hypot(translation.width, translation.height) >= 3 {
            isPetDragActive = true
            beginFloatingDrag()
        }

        guard isPetDragActive else { return true }
        updateFloatingDrag(translation: translation)
        return true
    }

    private func handlePetMouseUp(_ event: NSEvent) -> Bool {
        defer {
            petMouseDownPoint = nil
            petMouseDownScreenPoint = nil
            isPetDragActive = false
        }

        guard petMouseDownPoint != nil else { return false }

        if isPetDragActive {
            endFloatingDrag()
            return true
        }

        guard isPointInsidePet(event.locationInWindow) else { return true }
        detachedViewController.onPetTap()
        return true
    }

    private func handlePetRightMouseDown(_ event: NSEvent) -> Bool {
        guard isPointInsidePet(event.locationInWindow) else {
            isPetSecondaryClickArmed = false
            return false
        }

        isPetSecondaryClickArmed = true
        return true
    }

    private func handlePetRightMouseUp(_ event: NSEvent) -> Bool {
        defer { isPetSecondaryClickArmed = false }
        guard isPetSecondaryClickArmed else { return false }
        guard isPointInsidePet(event.locationInWindow) else { return true }

        handlePetSecondaryClick()
        return true
    }

    private func isPointInsidePet(_ point: CGPoint) -> Bool {
        Self.petInteractionFrame(for: lastAppliedLayout).contains(point)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        // Window movement and hit-testing use AppKit screen coordinates (origin at bottom-left).
        MouseEventReplay.appKitScreenLocation(
            for: event,
            fallbackScreenLocation: NSEvent.mouseLocation
        )
    }

    private func syncBubblePresentation(to targetState: DetachedIslandBubbleState) {
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil

        switch targetState {
        case .hidden:
            hideBubblePresentation()
        case .hoverPreview, .pinned:
            showBubblePresentation(targetState)
        }
    }

    private func showBubblePresentation(_ targetState: DetachedIslandBubbleState) {
        bubbleViewState.prepareLayout(for: targetState)
        applyWindowSizeUpdateImmediately()
        withAnimation(.easeInOut(duration: bubbleViewState.bubbleFadeDuration)) {
            bubbleViewState.setBubbleVisible(true)
        }
    }

    private func hideBubbleRenderingImmediately() {
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil
        bubbleViewState.setBubbleVisible(false)
        bubbleViewState.prepareLayout(for: .hidden)
        applyWindowSizeUpdateImmediately()
    }

    private func hideBubblePresentation() {
        hideBubbleRenderingImmediately()
    }

    private func applyWindowSizeUpdateImmediately() {
        hasPendingWindowSizeUpdate = true
        applyPendingWindowSizeUpdate()
    }

    private func presentExistingAttentionIfNeeded() {
        guard interactionModel.bubbleState != .pinned else { return }
        guard DetachedIslandContentModel.canPresentBubble(
            from: sessionMonitor.instances,
            mode: .hoverPreview,
            activeCompletionNotification: activeCompletionNotification
        ) else {
            return
        }
        guard IslandExpandedRouteResolver.highestPriorityAttentionSession(
            from: sessionMonitor.instances
        ) != nil else {
            return
        }

        interactionModel.presentHoverPreview(canPresentBubble: true)
    }

    private func handleManualAttentionChange() {
        guard let targetSession = manualAttentionTracker.consumeNewAttentionSession(
            from: sessionMonitor.instances
        ) else {
            return
        }

        clearCompletionNotifications(keepBubbleOpen: true)

        if interactionModel.bubbleState == .pinned {
            updateHighlightedSessionStableID(targetSession.stableId)
            return
        }

        updateHighlightedSessionStableID(nil)
        presentExistingAttentionIfNeeded()
    }

    private func reconcileHighlightedSessionState() {
        guard interactionModel.bubbleState == .pinned else {
            updateHighlightedSessionStableID(nil)
            return
        }

        guard let highlightedSessionStableID else { return }

        guard let session = sessionMonitor.instances.first(where: {
            $0.stableId == highlightedSessionStableID
        }), session.needsManualAttention else {
            updateHighlightedSessionStableID(nil)
            return
        }
    }

    private func updateHighlightedSessionStableID(_ stableID: String?) {
        guard highlightedSessionStableID != stableID else { return }
        highlightedSessionStableID = stableID
        bubbleViewState.highlightedSessionStableID = stableID
    }

    private func reconcileBubbleStateWithAvailableContent() {
        switch interactionModel.bubbleState {
        case .hidden:
            return
        case .hoverPreview:
            guard DetachedIslandContentModel.canPresentBubble(
                from: sessionMonitor.instances,
                mode: .hoverPreview,
                activeCompletionNotification: activeCompletionNotification
            ) else {
                interactionModel.hidePinnedBubble()
                return
            }
        case .pinned:
            guard DetachedIslandContentModel.canPresentBubble(
                from: sessionMonitor.instances,
                mode: .pinnedList
            ) else {
                interactionModel.hidePinnedBubble()
                return
            }
        }
    }

    private func syncOutsideClickMonitor() {
        let shouldMonitorOutsideClicks = interactionModel.bubbleState == .pinned
            || interactionModel.bubbleState == .hoverPreview

        if shouldMonitorOutsideClicks {
            guard outsideClickMonitor == nil else { return }
            let monitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handlePotentialOutsideClick(event)
            }
            monitor.start()
            outsideClickMonitor = monitor
        } else {
            outsideClickMonitor?.stop()
            outsideClickMonitor = nil
        }
    }

    private func handlePotentialOutsideClick(_ event: NSEvent) {
        guard interactionModel.bubbleState == .pinned,
              let window else { return }

        let eventLocation = MouseEventReplay.appKitScreenLocation(
            for: event,
            fallbackScreenLocation: NSEvent.mouseLocation
        )

        guard !window.frame.contains(eventLocation) else { return }
        interactionModel.hidePinnedBubble()
    }

    private func updateBubblePlacementForCurrentWindow() {
        guard let window else { return }
        let petAnchorScreen = Self.petAnchorScreenPoint(
            for: window.frame,
            layout: lastAppliedLayout
        )
        let resolvedLayout = Self.windowLayout(
            for: viewModel,
            sessionMonitor: sessionMonitor,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            activeCompletionNotification: activeCompletionNotification,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame(for: petAnchorScreen)
        )
        interactionModel.setBubblePlacement(resolvedLayout.bubblePlacement)
    }

    private func availableFrame(for petAnchor: CGPoint? = nil) -> CGRect {
        if let screen = window?.screen {
            return screen.visibleFrame
        }

        if let petAnchor,
           let matchingScreen = NSScreen.screens.first(where: {
               $0.frame.insetBy(dx: -1, dy: -1).contains(petAnchor)
           }) {
            return matchingScreen.visibleFrame
        }

        return viewModel.screenRect
    }

    private func primeCompletionNotificationTracking(_ instances: [SessionState]) {
        previousCompletionNotificationPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )
        synchronizeCompletionNotifications(with: instances)
    }

    private func handleCompletionNotificationChange(_ instances: [SessionState]) {
        synchronizeCompletionNotifications(with: instances)

        if AppSettings.areReminderNotificationsSuppressed {
            if activeCompletionNotification != nil || !completionNotificationQueue.isEmpty {
                clearCompletionNotifications(keepBubbleOpen: false)
            }

            previousCompletionNotificationPhases = Dictionary(
                uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
            )
            return
        }

        let currentPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )

        if interactionModel.bubbleState == .pinned && activeCompletionNotification == nil {
            previousCompletionNotificationPhases = currentPhases
            completionNotificationQueue.removeAll()
            return
        }

        let newNotifications = instances
            .compactMap { session -> SessionCompletionNotification? in
                let previousPhase = previousCompletionNotificationPhases[session.stableId]

                if shouldQueueCompactedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .compacted)
                }

                if shouldQueueCompletedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .completed)
                }

                if shouldQueueEndedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .ended)
                }

                return nil
            }
            .sorted { $0.session.lastActivity < $1.session.lastActivity }

        for notification in newNotifications {
            enqueueCompletionNotification(notification)
        }

        previousCompletionNotificationPhases = currentPhases
        maybePresentNextCompletionNotification()
    }

    private func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard AppSettings.autoOpenCompletionPanel else { return false }
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return true
    }

    private func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard AppSettings.autoOpenCompletionPanel else { return false }
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return true
    }

    private func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard AppSettings.autoOpenCompactedNotificationPanel else { return false }
        guard previousPhase == .compacting else { return false }
        guard session.phase != .compacting else { return false }
        return true
    }

    private func synchronizeCompletionNotifications(with instances: [SessionState]) {
        let sessionsById = Dictionary(uniqueKeysWithValues: instances.map { ($0.stableId, $0) })

        if let active = activeCompletionNotification {
            if let latest = sessionsById[active.session.stableId] {
                activeCompletionNotification?.session = latest
            } else {
                dismissActiveCompletionNotification(closeBubble: false, advanceQueue: true)
            }
        }

        completionNotificationQueue = completionNotificationQueue.compactMap { notification in
            guard let latest = sessionsById[notification.session.stableId] else { return nil }
            var updated = notification
            updated.session = latest
            return updated
        }
    }

    private func enqueueCompletionNotification(_ notification: SessionCompletionNotification) {
        if let active = activeCompletionNotification,
           active.session.stableId == notification.session.stableId {
            activeCompletionNotification?.session = notification.session
            return
        }

        if let queuedIndex = completionNotificationQueue.firstIndex(where: {
            $0.session.stableId == notification.session.stableId
        }) {
            var updated = completionNotificationQueue[queuedIndex]
            updated.session = notification.session
            completionNotificationQueue[queuedIndex] = updated
            return
        }

        completionNotificationQueue.append(notification)
    }

    private func maybePresentNextCompletionNotification() {
        guard !AppSettings.areReminderNotificationsSuppressed else { return }
        guard activeCompletionNotification == nil else { return }
        guard !completionNotificationQueue.isEmpty else { return }
        guard case .instances = viewModel.contentType else { return }
        guard interactionModel.bubbleState != .pinned else { return }
        guard IslandExpandedRouteResolver.highestPriorityAttentionSession(
            from: sessionMonitor.instances
        ) == nil else {
            return
        }

        let nextNotification = completionNotificationQueue.removeFirst()
        activeCompletionNotification = nextNotification
        shouldDismissCompletionNotificationOnHoverExit = false
        interactionModel.presentHoverPreview(canPresentBubble: true)
        scheduleCompletionNotificationDismissal(for: nextNotification.id)
    }

    private func scheduleCompletionNotificationDismissal(for notificationID: UUID) {
        completionNotificationDismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeCompletionNotification?.id == notificationID else { return }
            self.dismissActiveCompletionNotification(closeBubble: true, advanceQueue: true)
        }

        completionNotificationDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func clearCompletionNotifications(keepBubbleOpen: Bool) {
        removeCompletionNotifications(matching: { _ in true }, keepBubbleOpen: keepBubbleOpen)
    }

    private func removeCompletionNotifications(
        matching shouldRemove: (SessionCompletionNotification.Kind) -> Bool,
        keepBubbleOpen: Bool
    ) {
        completionNotificationQueue.removeAll { shouldRemove($0.kind) }

        if let activeCompletionNotification,
           shouldRemove(activeCompletionNotification.kind) {
            dismissActiveCompletionNotification(
                closeBubble: !keepBubbleOpen,
                advanceQueue: true
            )
        }
    }

    private func handleCompletionNotificationHover(_ isHovering: Bool) {
        guard activeCompletionNotification != nil else {
            shouldDismissCompletionNotificationOnHoverExit = false
            return
        }

        if isHovering {
            shouldDismissCompletionNotificationOnHoverExit = true
            completionNotificationDismissWorkItem?.cancel()
            completionNotificationDismissWorkItem = nil
            return
        }

        guard shouldDismissCompletionNotificationOnHoverExit else { return }
        shouldDismissCompletionNotificationOnHoverExit = false
        dismissActiveCompletionNotification(closeBubble: true, advanceQueue: true)
    }

    private func dismissActiveCompletionNotification(
        closeBubble: Bool,
        advanceQueue: Bool
    ) {
        completionNotificationDismissWorkItem?.cancel()
        completionNotificationDismissWorkItem = nil
        shouldDismissCompletionNotificationOnHoverExit = false

        guard activeCompletionNotification != nil else {
            if advanceQueue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.maybePresentNextCompletionNotification()
                }
            }
            return
        }

        activeCompletionNotification = nil

        if closeBubble, interactionModel.bubbleState == .hoverPreview {
            if IslandExpandedRouteResolver.highestPriorityAttentionSession(
                from: sessionMonitor.instances
            ) != nil {
                presentExistingAttentionIfNeeded()
            } else {
                interactionModel.hidePinnedBubble()
            }
        }

        if advanceQueue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.maybePresentNextCompletionNotification()
            }
        }
    }

    private func primeSoundTransitions(_ instances: [SessionState]) {
        previousProcessingIds = Set(
            instances
                .filter { $0.phase == .processing || $0.phase == .compacting }
                .map(\.stableId)
        )
        previousAttentionSoundIds = Set(
            instances
                .filter { $0.needsApprovalResponse || ($0.phase == .waitingForInput && $0.intervention != nil) }
                .map(\.stableId)
        )
        previousCompletionSoundIds = Set(
            instances
                .filter { $0.phase == .waitingForInput && $0.intervention == nil }
                .map(\.stableId)
        )
        previousTaskErrorIds = Set(
            instances.flatMap { session in
                session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
            }
        )
        previousResourceLimitIds = Set(
            instances
                .filter { $0.phase == .compacting }
                .map(\.stableId)
        )
        hasPrimedSoundTransitions = true
    }

    private func handleSessionSoundTransitions(_ instances: [SessionState]) {
        if !hasPrimedSoundTransitions {
            primeSoundTransitions(instances)
            return
        }

        let processingSessions = instances.filter {
            $0.phase == .processing || $0.phase == .compacting
        }
        let attentionSessions = instances.filter {
            $0.needsApprovalResponse || ($0.phase == .waitingForInput && $0.intervention != nil)
        }
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let resourceLimitedSessions = instances.filter {
            $0.phase == .compacting
        }

        let newProcessingIds = Set(processingSessions.map(\.stableId))
        let newAttentionIds = Set(attentionSessions.map(\.stableId))
        let newCompletedIds = Set(completedSessions.map(\.stableId))
        let newTaskErrorIds = Set(
            instances.flatMap { session in
                session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
            }
        )
        let newResourceLimitIds = Set(resourceLimitedSessions.map(\.stableId))
        let errorDeltaIds = newTaskErrorIds.subtracting(previousTaskErrorIds)
        let errorSessions = instances.filter { session in
            session.completedErrorToolIDs.contains { errorDeltaIds.contains("\(session.sessionId):\($0)") }
        }
        let completionDeltaIds = newCompletedIds.subtracting(previousCompletionSoundIds)
        let newlyCompletedSessions = completedSessions.filter { session in
            completionDeltaIds.contains(session.stableId)
        }

        let isNewAttention = !newAttentionIds.subtracting(previousAttentionSoundIds).isEmpty
        let isNewCompletion = !completionDeltaIds.isEmpty
        let isNewTaskError = !errorDeltaIds.isEmpty
        let isNewResourceLimit = !newResourceLimitIds.subtracting(previousResourceLimitIds).isEmpty

        if isNewTaskError {
            playEventSoundIfNeeded(.taskError, sessions: errorSessions)
        } else if isNewResourceLimit {
            playEventSoundIfNeeded(.resourceLimit, sessions: resourceLimitedSessions)
        } else if isNewAttention {
            playEventSoundIfNeeded(.attentionRequired, sessions: attentionSessions)
        } else if isNewCompletion {
            playEventSoundIfNeeded(.taskCompleted, sessions: newlyCompletedSessions)
        } else if !newProcessingIds.subtracting(previousProcessingIds).isEmpty {
            playEventSoundIfNeeded(.processingStarted, sessions: processingSessions)
        }

        previousProcessingIds = newProcessingIds
        previousAttentionSoundIds = newAttentionIds
        previousCompletionSoundIds = newCompletedIds
        previousTaskErrorIds = newTaskErrorIds
        previousResourceLimitIds = newResourceLimitIds
    }

    private func playEventSoundIfNeeded(_ event: NotificationEvent, sessions: [SessionState]) {
        guard AppSettings.soundEnabled else { return }

        Task { [weak self] in
            guard let self else { return }
            let shouldPlaySound = await self.shouldPlayNotificationSound(for: sessions)
            if shouldPlaySound {
                _ = await MainActor.run {
                    AppSettings.playSound(for: event)
                }
            }
        }
    }

    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}

private extension CGRect {
    var nilIfEmpty: CGRect? {
        guard !isNull, !isEmpty, width > 0, height > 0 else {
            return nil
        }

        return self
    }
}
