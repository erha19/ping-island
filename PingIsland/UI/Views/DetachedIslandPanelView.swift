import AppKit
import Combine
import SwiftUI

enum DetachedIslandPanelMetrics {
    static let petVisualFrame: CGFloat = 74
    static let petHitFrame: CGFloat = 92
    static let mascotDisplaySize: CGFloat = 46
    static let mascotRenderScale: CGFloat = 1.75
    static let badgeOffset = CGSize(width: -6, height: -10)
    static let bubbleGap: CGFloat = 8
    static let leftBubbleGap: CGFloat = 2
    static let bubbleTailWidth: CGFloat = 30
    static let bubbleTailHeight: CGFloat = 16
    static let bubbleTailOverlap: CGFloat = 7
    static let bubbleTailInset: CGFloat = 4
    static let bubbleCornerRadius: CGFloat = 22
    static let bubbleWindowGutter: CGFloat = 2
    static let bubbleHorizontalPadding: CGFloat = 6
    static let bubbleVerticalPadding: CGFloat = 4
    static let usageFooterReservedHeight: CGFloat = 34
    static let usageFooterVerticalOffset: CGFloat = -3
    static let floatingUsageBoltVerticalOffset: CGFloat = 6
    static let settingsHintBubbleSize = CGSize(width: 248, height: 92)
}

nonisolated enum DetachedIslandBubbleCorner: Equatable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

enum DetachedIslandBubblePlacement: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    static let priorityOrder: [DetachedIslandBubblePlacement] = [
        .topLeft,
        .topRight,
        .bottomLeft,
        .bottomRight
    ]

    var isBubbleLeftOfPet: Bool {
        switch self {
        case .topLeft, .bottomLeft:
            return true
        case .topRight, .bottomRight:
            return false
        }
    }

    var isBubbleAbovePet: Bool {
        switch self {
        case .topLeft, .topRight:
            return true
        case .bottomLeft, .bottomRight:
            return false
        }
    }

    var trimmedCorner: DetachedIslandBubbleCorner {
        switch self {
        case .topLeft:
            return .bottomTrailing
        case .topRight:
            return .bottomLeading
        case .bottomLeft:
            return .topTrailing
        case .bottomRight:
            return .topLeading
        }
    }
}

enum DetachedIslandBubbleContentMode: Equatable {
    case hoverPreview
    case pinnedList

    init?(bubbleState: DetachedIslandBubbleState) {
        switch bubbleState {
        case .hidden:
            return nil
        case .hoverPreview:
            self = .hoverPreview
        case .pinned:
            self = .pinnedList
        }
    }
}

struct DetachedIslandWindowLayout {
    let containerSize: CGSize
    let petFrame: CGRect
    let bubbleFrame: CGRect?
    let bubblePlacement: DetachedIslandBubblePlacement
    let petAnchorInWindow: CGPoint
    let bubbleContentMode: DetachedIslandBubbleContentMode?
}

enum DetachedIslandContentModel {
    static func preferredBubblePlacement(
        for petScreenAnchor: CGPoint,
        bubbleSize: CGSize,
        availableFrame: CGRect,
        preferredPlacement: DetachedIslandBubblePlacement = .topLeft
    ) -> DetachedIslandBubblePlacement {
        let petSize = CGSize(
            width: DetachedIslandPanelMetrics.petHitFrame,
            height: DetachedIslandPanelMetrics.petHitFrame
        )

        var fallbackPlacement = preferredPlacement
        var fallbackVisibleArea: CGFloat = -.greatestFiniteMagnitude

        for placement in DetachedIslandBubblePlacement.priorityOrder {
            let bubbleFrame = bubbleScreenFrame(
                for: placement,
                petScreenAnchor: petScreenAnchor,
                petSize: petSize,
                bubbleSize: bubbleSize
            )

            if availableFrame.contains(bubbleFrame) {
                return placement
            }

            let visibleArea = visibleArea(of: bubbleFrame, within: availableFrame)
            if visibleArea > fallbackVisibleArea {
                fallbackVisibleArea = visibleArea
                fallbackPlacement = placement
            }
        }

        return fallbackPlacement
    }

    static func sortedSessions(from sessions: [SessionState]) -> [SessionState] {
        IslandExpandedRouteResolver.orderedSessions(from: sessions)
    }

    static func representativeSession(from sessions: [SessionState]) -> SessionState? {
        IslandExpandedRouteResolver.highestPriorityAttentionSession(from: sessions)
            ?? sortedSessions(from: sessions).first
    }

    static func activeCount(from sessions: [SessionState]) -> Int {
        sessions.filter { $0.phase.isActive }.count
    }

    static func canPresentBubble(
        from sessions: [SessionState],
        mode: DetachedIslandBubbleContentMode,
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> Bool {
        switch mode {
        case .hoverPreview:
            if activeCompletionNotification != nil {
                return true
            }
            return IslandExpandedRouteResolver.highestPriorityAttentionSession(from: sessions) != nil
                || !IslandExpandedRouteResolver.activePreviewSessions(from: sessions).isEmpty
        case .pinnedList:
            return !sortedSessions(from: sessions).isEmpty
        }
    }

    @MainActor
    static func route(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        mode: DetachedIslandBubbleContentMode,
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> IslandExpandedRoute {
        let trigger: IslandExpandedTrigger = switch mode {
        case .hoverPreview:
            activeCompletionNotification == nil ? .hover : .notification
        case .pinnedList: .pinnedList
        }

        return IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: trigger,
            contentType: viewModel.contentType,
            sessions: sessions,
            activeCompletionNotification: activeCompletionNotification
        )
    }

    @MainActor
    static func bubbleContentSize(
        for route: IslandExpandedRoute,
        sessions: [SessionState],
        viewModel: NotchViewModel,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        additionalFooterHeight: CGFloat = 0
    ) -> CGSize {
        let widthLimit = viewModel.screenRect.width - 132

        switch route {
        case .sessionList:
            let width = min(widthLimit, 448)
            let sorted = sortedSessions(from: sessions)
            let estimatedHeight = sessionListEstimatedHeight(for: sorted)
            let height = min(
                viewModel.screenRect.height - 160,
                max(96, estimatedHeight + additionalFooterHeight)
            )
            return CGSize(width: width, height: height)
        case .hoverDashboard:
            let width = min(widthLimit, 392)
            let visibleCount = max(min(IslandExpandedRouteResolver.activePreviewSessions(from: sessions).count, 3), 1)
            let estimatedHeight = 18 + (CGFloat(visibleCount) * 94)
            let height = min(viewModel.screenRect.height - 160, max(120, estimatedHeight))
            return CGSize(width: width, height: height)
        case .attentionNotification(let session):
            let width = min(widthLimit, 392)
            let height: CGFloat
            if let measuredAttentionBubbleHeight {
                height = min(
                    viewModel.screenRect.height - 160,
                    max(170, measuredAttentionBubbleHeight)
                )
            } else if session.needsQuestionResponse {
                height = min(viewModel.screenRect.height - 160, 316)
            } else {
                height = min(viewModel.screenRect.height - 160, 228)
            }
            return CGSize(width: width, height: max(170, height))
        case .completionNotification:
            let width = min(widthLimit, 392)
            let height = min(viewModel.screenRect.height - 160, 260)
            return CGSize(width: width, height: max(190, height))
        case .chat:
            return viewModel.panelSize(for: .detached)
        }
    }

    private static func sessionListEstimatedHeight(for sessions: [SessionState]) -> CGFloat {
        guard !sessions.isEmpty else { return 96 }

        let contentHeight = sessions.reduce(CGFloat(0)) { partial, session in
            partial + sessionListRowHeight(for: session)
        }
        let spacing = CGFloat(max(0, sessions.count - 1)) * 2
        let verticalInsets: CGFloat = 8
        return contentHeight + spacing + verticalInsets
    }

    private static func sessionListRowHeight(for session: SessionState) -> CGFloat {
        if session.needsQuestionResponse || session.needsApprovalResponse || session.needsManualAttention {
            return 86
        }
        if session.phase.isActive {
            return 74
        }
        if session.shouldUseMinimalCompactPresentation || session.usesTitleOnlySubagentPresentation {
            return 46
        }
        return 56
    }

    static func contentWidth(
        for bubbleFrameWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            bubbleFrameWidth - (DetachedIslandPanelMetrics.bubbleHorizontalPadding * 2)
        )
    }

    @MainActor
    static func layout(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        bubbleState: DetachedIslandBubbleState,
        bubblePlacement: DetachedIslandBubblePlacement,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        additionalFooterHeight: CGFloat = 0,
        activeCompletionNotification: SessionCompletionNotification? = nil,
        guideBubbleSize: CGSize? = nil,
        petScreenAnchor: CGPoint? = nil,
        availableFrame: CGRect? = nil
    ) -> DetachedIslandWindowLayout {
        let petSize = CGSize(
            width: DetachedIslandPanelMetrics.petHitFrame,
            height: DetachedIslandPanelMetrics.petHitFrame
        )
        let hiddenAnchor = CGPoint(x: petSize.width / 2, y: petSize.height / 2)

        guard let mode = DetachedIslandBubbleContentMode(bubbleState: bubbleState),
              canPresentBubble(
                from: sessions,
                mode: mode,
                activeCompletionNotification: activeCompletionNotification
              ) else {
            if let guideBubbleSize {
                return bubbleLayout(
                    petSize: petSize,
                    bubbleSize: guideBubbleSize,
                    bubblePlacement: bubblePlacement,
                    bubbleContentMode: nil,
                    petScreenAnchor: petScreenAnchor,
                    availableFrame: availableFrame
                )
            }

            return DetachedIslandWindowLayout(
                containerSize: petSize,
                petFrame: CGRect(origin: .zero, size: petSize),
                bubbleFrame: nil,
                bubblePlacement: bubblePlacement,
                petAnchorInWindow: hiddenAnchor,
                bubbleContentMode: nil
            )
        }

        let route = route(
            for: sessions,
            viewModel: viewModel,
            mode: mode,
            activeCompletionNotification: activeCompletionNotification
        )
        let bubbleSize = bubbleContentSize(
            for: route,
            sessions: sessions,
            viewModel: viewModel,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            additionalFooterHeight: additionalFooterHeight
        )
        return bubbleLayout(
            petSize: petSize,
            bubbleSize: bubbleSize,
            bubblePlacement: bubblePlacement,
            bubbleContentMode: mode,
            petScreenAnchor: petScreenAnchor,
            availableFrame: availableFrame
        )
    }

    private static func bubbleLayout(
        petSize: CGSize,
        bubbleSize: CGSize,
        bubblePlacement: DetachedIslandBubblePlacement,
        bubbleContentMode: DetachedIslandBubbleContentMode?,
        petScreenAnchor: CGPoint?,
        availableFrame: CGRect?
    ) -> DetachedIslandWindowLayout {
        let resolvedPlacement: DetachedIslandBubblePlacement
        if let petScreenAnchor, let availableFrame {
            resolvedPlacement = preferredBubblePlacement(
                for: petScreenAnchor,
                bubbleSize: bubbleSize,
                availableFrame: availableFrame,
                preferredPlacement: bubblePlacement
            )
        } else {
            resolvedPlacement = bubblePlacement
        }

        let horizontalGap = resolvedPlacement.isBubbleLeftOfPet
            ? DetachedIslandPanelMetrics.leftBubbleGap
            : DetachedIslandPanelMetrics.bubbleGap
        let verticalGap = DetachedIslandPanelMetrics.bubbleGap
        let topPlacementVerticalAdjustment = resolvedPlacement == .topLeft
            ? DetachedIslandPanelMetrics.petVisualFrame
            : 0
        let bottomPlacementVerticalAdjustment = resolvedPlacement.isBubbleAbovePet
            ? 0
            : DetachedIslandPanelMetrics.petVisualFrame
        let gutter = DetachedIslandPanelMetrics.bubbleWindowGutter
        let containerWidth = petSize.width + horizontalGap + bubbleSize.width + (gutter * 2)
        let containerHeight = max(
            petSize.height,
            petSize.height + verticalGap + bubbleSize.height
                - topPlacementVerticalAdjustment
                - bottomPlacementVerticalAdjustment
        ) + (gutter * 2)

        let petOriginX: CGFloat
        let bubbleOriginX: CGFloat
        if resolvedPlacement.isBubbleLeftOfPet {
            bubbleOriginX = gutter
            petOriginX = gutter + bubbleSize.width + horizontalGap
        } else {
            petOriginX = gutter
            bubbleOriginX = gutter + petSize.width + horizontalGap
        }

        let petOriginY: CGFloat
        let bubbleOriginY: CGFloat
        if resolvedPlacement.isBubbleAbovePet {
            bubbleOriginY = gutter
            petOriginY = max(gutter, gutter + bubbleSize.height + verticalGap - topPlacementVerticalAdjustment)
        } else {
            petOriginY = gutter
            bubbleOriginY = max(
                gutter,
                gutter + petSize.height + verticalGap - bottomPlacementVerticalAdjustment
            )
        }

        let petFrame = CGRect(
            origin: CGPoint(x: petOriginX, y: petOriginY),
            size: petSize
        )
        let bubbleFrame = CGRect(
            origin: CGPoint(x: bubbleOriginX, y: bubbleOriginY),
            size: bubbleSize
        )

        return DetachedIslandWindowLayout(
            containerSize: CGSize(
                width: containerWidth,
                height: containerHeight
            ),
            petFrame: petFrame,
            bubbleFrame: bubbleFrame,
            bubblePlacement: resolvedPlacement,
            petAnchorInWindow: CGPoint(x: petFrame.midX, y: petFrame.midY),
            bubbleContentMode: bubbleContentMode
        )
    }

    private static func bubbleScreenFrame(
        for placement: DetachedIslandBubblePlacement,
        petScreenAnchor: CGPoint,
        petSize: CGSize,
        bubbleSize: CGSize
    ) -> CGRect {
        let petFrame = CGRect(
            x: petScreenAnchor.x - (petSize.width / 2),
            y: petScreenAnchor.y - (petSize.height / 2),
            width: petSize.width,
            height: petSize.height
        )
        let horizontalGap = placement.isBubbleLeftOfPet
            ? DetachedIslandPanelMetrics.leftBubbleGap
            : DetachedIslandPanelMetrics.bubbleGap
        let verticalGap = DetachedIslandPanelMetrics.bubbleGap
        let originX = placement.isBubbleLeftOfPet
            ? petFrame.minX - horizontalGap - bubbleSize.width
            : petFrame.maxX + horizontalGap
        let originY = placement.isBubbleAbovePet
            ? petFrame.maxY + verticalGap
            : petFrame.minY - verticalGap - bubbleSize.height

        return CGRect(origin: CGPoint(x: originX, y: originY), size: bubbleSize)
    }

    private static func visibleArea(of rect: CGRect, within bounds: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

@MainActor
final class DetachedIslandInteractionModel: ObservableObject {
    @Published private(set) var bubbleState: DetachedIslandBubbleState = .hidden
    @Published private(set) var bubblePlacement: DetachedIslandBubblePlacement = .topLeft
    @Published private(set) var isPetDragging = false
    @Published private(set) var isSettingsHintVisible = false

    var bubbleContentMode: DetachedIslandBubbleContentMode? {
        DetachedIslandBubbleContentMode(bubbleState: bubbleState)
    }

    #if compiler(>=6.3)
    // Match NotchViewModel teardown behavior for Xcode 26 unit-test stability.
    nonisolated deinit {}
    #endif

    func setBubblePlacement(_ placement: DetachedIslandBubblePlacement) {
        guard bubblePlacement != placement else { return }
        bubblePlacement = placement
    }

    func togglePrimaryBubble(
        canPresentPreview: Bool,
        canPresentPinnedBubble: Bool
    ) {
        switch bubbleState {
        case .hidden:
            if canPresentPreview {
                bubbleState = .hoverPreview
            } else if canPresentPinnedBubble {
                bubbleState = .pinned
            }
        case .hoverPreview, .pinned:
            bubbleState = .hidden
        }
    }

    func togglePinned(canPresentBubble: Bool) {
        guard canPresentBubble else { return }

        switch bubbleState {
        case .pinned:
            bubbleState = .hidden
        case .hidden, .hoverPreview:
            bubbleState = .pinned
        }
    }

    func hidePinnedBubble() {
        bubbleState = .hidden
    }

    func presentHoverPreview(canPresentBubble: Bool) {
        guard canPresentBubble else {
            hidePinnedBubble()
            return
        }

        bubbleState = .hoverPreview
    }

    func resetForDragSuppression() {
        hidePinnedBubble()
    }

    func setPetDragging(_ isDragging: Bool) {
        guard isPetDragging != isDragging else { return }
        isPetDragging = isDragging
    }

    func setSettingsHintVisible(_ visible: Bool) {
        guard isSettingsHintVisible != visible else { return }
        isSettingsHintVisible = visible
    }
}

@MainActor
final class DetachedIslandBubbleViewState: ObservableObject {
    @Published var highlightedSessionStableID: String?
    @Published private(set) var activeCompletionNotification: SessionCompletionNotification?
    @Published private(set) var renderedBubbleState: DetachedIslandBubbleState = .hidden
    @Published private(set) var isBubbleVisible = false
    @Published private(set) var measuredAttentionBubbleHeight: CGFloat?

    var bubbleFadeDuration: TimeInterval { 0.18 }

    #if compiler(>=6.3)
    // Match NotchViewModel teardown behavior for Xcode 26 unit-test stability.
    nonisolated deinit {}
    #endif

    func prepareLayout(for bubbleState: DetachedIslandBubbleState) {
        guard renderedBubbleState != bubbleState else { return }
        renderedBubbleState = bubbleState
    }

    func setBubbleVisible(_ visible: Bool) {
        guard isBubbleVisible != visible else { return }
        isBubbleVisible = visible
    }

    func setMeasuredAttentionBubbleHeight(_ height: CGFloat?) {
        let sanitized = height.map { ceil(max(0, $0)) }
        guard measuredAttentionBubbleHeight != sanitized else { return }
        measuredAttentionBubbleHeight = sanitized
    }

    func setActiveCompletionNotification(_ notification: SessionCompletionNotification?) {
        guard activeCompletionNotification != notification else { return }
        activeCompletionNotification = notification
    }
}

struct DetachedIslandPanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var interactionModel: DetachedIslandInteractionModel
    @ObservedObject var bubbleViewState: DetachedIslandBubbleViewState
    @ObservedObject private var settings = AppSettings.shared
    @State private var isPetDragging = false

    let onClose: () -> Void
    let onPetTap: () -> Void
    let onPetDragStarted: () -> Void
    let onPetDragChanged: (CGSize) -> Void
    let onPetDragEnded: () -> Void
    let onBubbleHoverChanged: (Bool) -> Void
    let onAttentionActionCompleted: () -> Void
    let onCompletionNotificationHoverChanged: (Bool) -> Void
    let onDismissCompletionNotification: () -> Void

    private var sortedSessions: [SessionState] {
        DetachedIslandContentModel.sortedSessions(from: sessionMonitor.instances)
    }

    private var representativeSession: SessionState? {
        DetachedIslandContentModel.representativeSession(from: sortedSessions)
    }

    private var activeCount: Int {
        DetachedIslandContentModel.activeCount(from: sortedSessions)
    }

    private var bubbleContentMode: DetachedIslandBubbleContentMode? {
        DetachedIslandBubbleContentMode(bubbleState: bubbleViewState.renderedBubbleState)
    }

    private var bubbleRoute: IslandExpandedRoute? {
        guard let bubbleContentMode else { return nil }
        return DetachedIslandContentModel.route(
            for: sortedSessions,
            viewModel: viewModel,
            mode: bubbleContentMode,
            activeCompletionNotification: bubbleViewState.activeCompletionNotification
        )
    }

    private var layout: DetachedIslandWindowLayout {
        DetachedIslandContentModel.layout(
            for: sortedSessions,
            viewModel: viewModel,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            additionalFooterHeight: shouldShowFloatingUsageFooter
                ? DetachedIslandPanelMetrics.usageFooterReservedHeight
                : 0,
            activeCompletionNotification: bubbleViewState.activeCompletionNotification,
            guideBubbleSize: interactionModel.isSettingsHintVisible
                ? DetachedIslandPanelMetrics.settingsHintBubbleSize
                : nil
        )
    }

    private var usageSummaryProviders: [UsageSummaryProvider] {
        UsageSummaryPresenter.providers(
            claudeSnapshot: sessionMonitor.claudeUsageSnapshot,
            codexSnapshot: sessionMonitor.codexUsageSnapshot,
            mode: settings.usageValueMode,
            locale: settings.locale
        )
    }

    private var floatingPetUsageWindows: [UsageSummaryWindow] {
        guard settings.showUsage else { return [] }
        return usageSummaryProviders
            .flatMap(\.windows)
            .filter(UsageSummaryPresenter.shouldShowFloatingBolt)
    }

    private var shouldShowFloatingUsageFooter: Bool {
        guard let bubbleRoute else { return false }
        return UsageSummaryPresenter.shouldShowSummary(
            for: bubbleRoute,
            showUsage: settings.showUsage,
            providers: usageSummaryProviders
        )
    }

    private var compactMascotKind: MascotKind {
        settings.mascotKind(for: IslandMascotResolver.sourceSession(from: sortedSessions)?.mascotClient)
    }

    private var compactMascotStatus: MascotStatus {
        if isPetDragging {
            return .dragging
        }
        return MascotStatus.closedNotchStatus(
            representativePhase: representativeSession?.phase,
            hasPendingPermission: sortedSessions.contains { $0.needsApprovalResponse },
            hasHumanIntervention: sortedSessions.contains { $0.intervention != nil }
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let bubbleFrame = layout.bubbleFrame,
               let bubbleContentMode,
               let bubbleRoute {
                bubbleView(
                    mode: bubbleContentMode,
                    route: bubbleRoute,
                    contentWidth: DetachedIslandContentModel.contentWidth(for: bubbleFrame.width)
                )
                    .onHover(perform: onBubbleHoverChanged)
                    .onDisappear {
                        onBubbleHoverChanged(false)
                    }
                    .opacity(bubbleViewState.isBubbleVisible ? 1 : 0)
                    .allowsHitTesting(bubbleViewState.isBubbleVisible)
                    .frame(width: bubbleFrame.width, height: bubbleFrame.height)
                    .offset(x: bubbleFrame.minX, y: bubbleFrame.minY)
            } else if let bubbleFrame = layout.bubbleFrame,
                      interactionModel.isSettingsHintVisible {
                DetachedFloatingPetSettingsHintView(placement: layout.bubblePlacement)
                    .allowsHitTesting(false)
                    .frame(width: bubbleFrame.width, height: bubbleFrame.height)
                    .offset(x: bubbleFrame.minX, y: bubbleFrame.minY)
            }

            petButton
                .frame(width: layout.petFrame.width, height: layout.petFrame.height)
                .offset(x: layout.petFrame.minX, y: layout.petFrame.minY)
        }
        .frame(
            width: layout.containerSize.width,
            height: layout.containerSize.height,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
        .onAppear {
            if !SessionMonitor.isRunningUnderXCTest {
                sessionMonitor.startMonitoring()
            }
        }
        .onChange(of: bubbleRoute) { _, route in
            guard case .attentionNotification = route else {
                bubbleViewState.setMeasuredAttentionBubbleHeight(nil)
                return
            }
        }
        .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
            guard case .attentionNotification = bubbleRoute else {
                return
            }

            let measuredHeight = height > 0
                ? min(
                    viewModel.screenRect.height - 160,
                    max(
                        170,
                        height + (DetachedIslandPanelMetrics.bubbleVerticalPadding * 2)
                    )
                )
                : nil
            bubbleViewState.setMeasuredAttentionBubbleHeight(measuredHeight)
        }
    }

    private var petButton: some View {
        DetachedFloatingPetInteractionView(
            activeCount: activeCount,
            usageWindows: floatingPetUsageWindows,
            mascotKind: compactMascotKind,
            mascotStatus: compactMascotStatus,
            isDragging: interactionModel.isPetDragging,
            onTap: onPetTap,
            onDragStarted: {
                isPetDragging = true
                onPetDragStarted()
            },
            onDragChanged: onPetDragChanged,
            onDragEnded: {
                isPetDragging = false
                onPetDragEnded()
            }
        )
    }

    private func bubbleView(
        mode: DetachedIslandBubbleContentMode,
        route: IslandExpandedRoute,
        contentWidth: CGFloat
    ) -> some View {
        DetachedIslandBubbleChrome(placement: layout.bubblePlacement) {
            VStack(alignment: .leading, spacing: shouldShowFloatingUsageFooter ? 4 : 8) {
                IslandOpenedContentView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    surface: .floating,
                    trigger: mode == .pinnedList
                        ? .pinnedList
                        : (bubbleViewState.activeCompletionNotification == nil ? .hover : .notification),
                    style: .detached,
                    activeCompletionNotification: bubbleViewState.activeCompletionNotification,
                    highlightedSessionStableID: route == .sessionList
                        ? bubbleViewState.highlightedSessionStableID
                        : nil,
                    contentWidthOverride: contentWidth,
                    onAttentionActionCompleted: onAttentionActionCompleted,
                    onCompletionNotificationHoverChanged: onCompletionNotificationHoverChanged,
                    onDismissCompletionNotification: onDismissCompletionNotification
                )

                if shouldShowFloatingUsageFooter {
                    HStack {
                        Spacer(minLength: 0)
                        UsageSummaryStripView(
                            providers: usageSummaryProviders,
                            inline: true,
                            alignment: .trailing,
                            displayStyle: .battery,
                            batteryHoverDetailStyle: .currentWindow,
                            batteryPopoverPlacement: .above,
                            locale: settings.locale
                        )
                        .zIndex(200)
                    }
                    .padding(.top, -2)
                    .offset(y: DetachedIslandPanelMetrics.usageFooterVerticalOffset)
                    .zIndex(200)
                }
            }
        }
    }
}

private struct DetachedFloatingPetSettingsHintView: View {
    let placement: DetachedIslandBubblePlacement

    var body: some View {
        DetachedIslandBubbleChrome(placement: placement) {
            VStack(alignment: .leading, spacing: 8) {
                Text(appLocalized: "最后一步：右键宠物形象")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: "需要重新打开设置面板时，直接右键宠物形象就可以。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                AppLocalization.string("最后一步：右键宠物形象")
                + " "
                + AppLocalization.string("需要重新打开设置面板时，直接右键宠物形象就可以。")
            )
        )
    }
}

private struct DetachedFloatingPetInteractionView: View {
    let activeCount: Int
    let usageWindows: [UsageSummaryWindow]
    let mascotKind: MascotKind
    let mascotStatus: MascotStatus
    let isDragging: Bool
    let onTap: () -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DetachedFloatingMascotView(
                kind: mascotKind,
                status: mascotStatus,
                isDragging: isDragging
            )
            .frame(
                width: DetachedIslandPanelMetrics.petVisualFrame,
                height: DetachedIslandPanelMetrics.petVisualFrame
            )

            if activeCount > 0 {
                activeCountBadge
                    .offset(
                        x: DetachedIslandPanelMetrics.badgeOffset.width,
                        y: DetachedIslandPanelMetrics.badgeOffset.height
                    )
            }
        }
        .frame(
            width: DetachedIslandPanelMetrics.petHitFrame,
            height: DetachedIslandPanelMetrics.petHitFrame
        )
        .overlay(alignment: .top) {
            if !usageWindows.isEmpty {
                DetachedFloatingUsageBoltView(windows: usageWindows)
                    .offset(y: DetachedIslandPanelMetrics.floatingUsageBoltVerticalOffset)
                    .allowsHitTesting(false)
            }
        }
        .rotationEffect(.degrees(isDragging ? -7 : 0))
        .scaleEffect(isDragging ? 1.08 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isDragging)
        .overlay {
            DetachedPetInteractionBridge(
                size: CGSize(
                    width: DetachedIslandPanelMetrics.petHitFrame,
                    height: DetachedIslandPanelMetrics.petHitFrame
                ),
                onTap: onTap,
                onDragStarted: onDragStarted,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(
                width: DetachedIslandPanelMetrics.petHitFrame,
                height: DetachedIslandPanelMetrics.petHitFrame
            )
        }
    }

    @ViewBuilder
    private var activeCountBadge: some View {
        PixelNumberView(
            value: activeCount,
            color: .white.opacity(0.96),
            fontSize: activeCount >= 10 ? 8.2 : 9.2,
            weight: .semibold,
            tracking: activeCount >= 10 ? -0.15 : -0.05
        )
    }
}

private struct DetachedFloatingUsageBoltView: View {
    let windows: [UsageSummaryWindow]

    private let cycleInterval: TimeInterval = 1.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            if let window = window(for: context.date) {
                let phase = context.date.timeIntervalSinceReferenceDate
                let pulse = 1 + (sin(phase * .pi * 2 / 1.2) * 0.05)
                let lift = sin(phase * .pi * 2 / 1.6) * 1.2

                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(color(for: window.severity))
                    .scaleEffect((window.severity == .critical ? 1.08 : 1) * pulse)
                    .offset(y: lift)
                    .id(window.id)
                    .help(window.resetText ?? window.valueText)
                    .accessibilityLabel(Text(accessibilityLabel(for: window)))
            }
        }
    }

    private func window(for date: Date) -> UsageSummaryWindow? {
        guard !windows.isEmpty else { return nil }
        let index = Int(date.timeIntervalSinceReferenceDate / cycleInterval) % windows.count
        return windows[index]
    }

    private func color(for severity: UsageSummarySeverity) -> Color {
        switch severity {
        case .healthy:
            return Color(red: 0.42, green: 0.92, blue: 0.60)
        case .warning:
            return Color(red: 0.98, green: 0.82, blue: 0.32)
        case .critical:
            return Color(red: 0.98, green: 0.44, blue: 0.38)
        }
    }

    private func accessibilityLabel(for window: UsageSummaryWindow) -> String {
        [window.label, window.valueText, window.resetText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct DetachedPetInteractionBridge: NSViewRepresentable {
    let size: CGSize
    let onTap: () -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> DetachedPetInteractionView {
        let view = DetachedPetInteractionView(frame: NSRect(origin: .zero, size: size))
        update(view)
        return view
    }

    func updateNSView(_ nsView: DetachedPetInteractionView, context: Context) {
        nsView.frame = NSRect(origin: .zero, size: size)
        update(nsView)
    }

    private func update(_ view: DetachedPetInteractionView) {
        view.onTap = onTap
        view.onDragStarted = onDragStarted
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

private final class DetachedPetInteractionView: NSView {
    var onTap: () -> Void = {}
    var onDragStarted: () -> Void = {}
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private let dragThreshold: CGFloat = 3
    private var mouseDownPoint: CGPoint?
    private var hasStartedDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: currentPoint.x - mouseDownPoint.x,
            height: currentPoint.y - mouseDownPoint.y
        )

        if !hasStartedDrag, hypot(translation.width, translation.height) >= dragThreshold {
            hasStartedDrag = true
            onDragStarted()
        }

        guard hasStartedDrag else { return }
        onDragChanged(translation)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            hasStartedDrag = false
        }

        if hasStartedDrag {
            onDragEnded()
            return
        }

        onTap()
    }
}

private struct DetachedFloatingMascotView: View {
    let kind: MascotKind
    let status: MascotStatus
    let isDragging: Bool

    private var renderSize: CGFloat {
        DetachedIslandPanelMetrics.mascotDisplaySize * DetachedIslandPanelMetrics.mascotRenderScale
    }

    private var displayScale: CGFloat {
        DetachedIslandPanelMetrics.mascotDisplaySize / renderSize
    }

    var body: some View {
        MascotView(
            kind: kind,
            status: status,
            size: renderSize,
            isDragging: isDragging
        )
        .frame(width: renderSize, height: renderSize)
        .scaleEffect(displayScale)
        .frame(
            width: DetachedIslandPanelMetrics.mascotDisplaySize,
            height: DetachedIslandPanelMetrics.mascotDisplaySize
        )
        .compositingGroup()
        .drawingGroup(opaque: false, colorMode: .linear)
        .allowsHitTesting(false)
    }
}

private struct DetachedIslandBubbleChrome<Content: View>: View {
    let placement: DetachedIslandBubblePlacement
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DetachedIslandPanelMetrics.bubbleHorizontalPadding)
            .padding(.vertical, DetachedIslandPanelMetrics.bubbleVerticalPadding)
            .background(
                DetachedIslandBubbleShape(placement: placement)
                    .fill(Color.black)
            )
    }
}

private struct DetachedIslandBubbleShape: Shape {
    let placement: DetachedIslandBubblePlacement

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(
            DetachedIslandPanelMetrics.bubbleCornerRadius,
            min(rect.width, rect.height) / 2
        )
        let topLeadingRadius = placement.trimmedCorner == .topLeading ? 0 : radius
        let topTrailingRadius = placement.trimmedCorner == .topTrailing ? 0 : radius
        let bottomTrailingRadius = placement.trimmedCorner == .bottomTrailing ? 0 : radius
        let bottomLeadingRadius = placement.trimmedCorner == .bottomLeading ? 0 : radius

        path.move(to: CGPoint(x: rect.minX + topLeadingRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topTrailingRadius, y: rect.minY))
        addCorner(
            on: &path,
            to: CGPoint(x: rect.maxX, y: rect.minY + topTrailingRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY),
            radius: topTrailingRadius
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailingRadius))
        addCorner(
            on: &path,
            to: CGPoint(x: rect.maxX - bottomTrailingRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: bottomTrailingRadius
        )

        path.addLine(to: CGPoint(x: rect.minX + bottomLeadingRadius, y: rect.maxY))
        addCorner(
            on: &path,
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeadingRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY),
            radius: bottomLeadingRadius
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeadingRadius))
        addCorner(
            on: &path,
            to: CGPoint(x: rect.minX + topLeadingRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY),
            radius: topLeadingRadius
        )
        path.closeSubpath()
        return path
    }

    private func addCorner(
        on path: inout Path,
        to: CGPoint,
        control: CGPoint,
        radius: CGFloat
    ) {
        if radius > 0 {
            path.addQuadCurve(to: to, control: control)
        } else {
            path.addLine(to: to)
        }
    }
}
