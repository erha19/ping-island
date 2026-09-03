//
//  NotchView.swift
//  PingIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

/// Keeps the compact center message slightly narrower than the full center slot
/// so the closed notch matches the tighter visual balance used elsewhere.
private let compactCenterContentInset: CGFloat = 14
private let minimumClosedNotchFullContentWidth: CGFloat = 96

/// The screen-attached notch is stable product chrome rather than a theme
/// surface. Settings and detached panels may change theme, while this
/// presentation keeps the canonical black appearance and motion.
enum DockedNotchVisualStyle {
    static let surfaceColor = Color.black
    static let topSeparatorColor = Color.black
    static let openResponse: TimeInterval = 0.42
    static let openDampingFraction: CGFloat = 0.8
    static let closeResponse: TimeInterval = 0.45
    static let closeDampingFraction: CGFloat = 1.0

    static var contentTheme: IslandExperienceTheme {
        PingIslandExperienceTheme.definition
    }
}

struct OpenedPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    private static let temporaryReminderMuteDuration: TimeInterval = 10 * 60
    private static let startupDetachmentHintDelay: TimeInterval = 1.8
    private static let detachmentHintRetryDelay: TimeInterval = 0.75

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousPendingIds: Set<String> = []
    @State private var manualAttentionTracker = SessionManualAttentionTracker()
    @State private var previousCompletedReadyIds: Set<String> = []
    @State private var completionReadyTimestamps: [String: Date] = [:]
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var previousCompletionNotificationPhases: [String: SessionPhase] = [:]
    @State private var completionNotificationQueue: [SessionCompletionNotification] = []
    @State private var activeCompletionNotification: SessionCompletionNotification?
    @State private var completionNotificationDismissWorkItem: DispatchWorkItem?
    @State private var shouldDismissCompletionNotificationOnHoverExit: Bool = false
    @State private var isShowingDetachmentHint: Bool = false
    @State private var detachmentHintDismissWorkItem: DispatchWorkItem?
    @State private var detachmentHintPresentationWorkItem: DispatchWorkItem?
    @State private var delayedManualAttentionWorkItem: DispatchWorkItem?

    @Namespace private var activityNamespace

    private let petIconSize: CGFloat = 16

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.needsApprovalResponse }
    }

    /// Whether any session needs explicit human intervention (for example multi-choice questions).
    private var hasHumanIntervention: Bool {
        sessionMonitor.instances.contains {
            $0.phase == .waitingForInput && $0.intervention != nil
        }
    }

    /// Whether any session requires a user decision right now.
    private var hasManualAttentionIndicator: Bool {
        sessionMonitor.instances.contains {
            $0.needsPromptNotification
        }
    }

    private var activeSessions: [SessionState] {
        sessionMonitor.instances.filter(\.phase.isActive)
    }

    private var countedClosedSessions: [SessionState] {
        sessionMonitor.instances.filter { session in
            session.phase.isActive || session.phase.needsAttention
        }
    }

    private var activeSessionCount: Int {
        countedClosedSessions.count
    }

    private var usageSummaryProviders: [UsageSummaryProvider] {
        UsageSummaryPresenter.providers(
            claudeSnapshot: sessionMonitor.claudeUsageSnapshot,
            codexSnapshot: sessionMonitor.codexUsageSnapshot,
            mode: openedHeaderUsageValueMode,
            locale: settings.locale
        )
    }

    private var closedTrailingUsageWindow: UsageSummaryWindow? {
        guard let providerID = settings.closedNotchTrailingContentMode.usageProviderID else {
            return nil
        }

        return UsageSummaryPresenter.sevenDayWindow(
            forProviderID: providerID,
            in: usageSummaryProviders
        )
    }

    private var closedTrailingUsageProviderTitle: String? {
        guard let providerID = settings.closedNotchTrailingContentMode.usageProviderID else {
            return nil
        }

        return usageSummaryProviders.first { $0.id == providerID }?.title
    }

    private var openedHeaderUsageValueMode: UsageValueMode {
        isOnBuiltinDisplay ? .remaining : settings.usageValueMode
    }

    private var openedHeaderUsageDisplayStyle: UsageSummaryStripView.DisplayStyle {
        isOnBuiltinDisplay ? .preferredBattery : .numeric
    }

    private var isOnBuiltinDisplay: Bool {
        screenSelector.selectedScreen?.isBuiltinDisplay == true
    }

    private var shouldShowOpenedHeaderUsage: Bool {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances,
            activeCompletionNotification: activeCompletionNotification
        )

        return UsageSummaryPresenter.shouldShowSummary(
            for: route,
            showUsage: settings.showUsage,
            providers: usageSummaryProviders
        )
    }

    private var shouldHideForIdleState: Bool {
        settings.autoHideWhenIdle
            && activeSessions.isEmpty
            && !hasPendingPermission
            && !hasHumanIntervention
            && !hasCompletedReadyState
            && activeCompletionNotification == nil
    }

    /// Most recently active live session that has a hook message we can surface in the compact notch.
    private var latestHookMessageSession: SessionState? {
        latestHookMessageSession(from: sessionMonitor.instances)
    }

    private var closedCenterMessage: String? {
        guard settings.notchDisplayMode == .detailed else { return nil }
        return latestHookMessageSession?.compactHookMessage
    }

    /// Whether any tracked session completed and is ready for the user to continue.
    private var hasCompletedReadyState: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = completionReadyTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    private var closedIndicatorTone: NotchIndicatorTone {
        if hasHumanIntervention {
            return .intervention
        }
        if hasPendingPermission {
            return .warning
        }
        return .normal
    }

    private var representativeClosedSession: SessionState? {
        if let attention = sessionMonitor.instances
            .filter({ $0.needsManualAttention })
            .sorted(by: { ($0.attentionRequestedAt ?? $0.lastActivity) > ($1.attentionRequestedAt ?? $1.lastActivity) })
            .first {
            return attention
        }

        if let active = sessionMonitor.instances
            .filter({ $0.phase.isActive })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first {
            return active
        }

        return sessionMonitor.instances
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first
    }

    private var preferredShortcutSession: SessionState? {
        representativeClosedSession ?? latestHookMessageSession
    }

    private var closedMascotKind: MascotKind {
        settings.mascotKind(for: latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient)
    }

    private var completionNotificationMascotKind: MascotKind {
        let client = activeCompletionNotification?.session.mascotClient
            ?? latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient
        return settings.mascotKind(for: client)
    }

    private var areReminderNotificationsSuppressed: Bool {
        settings.areNotificationsMutedTemporarily
    }

    private var temporaryMuteButtonHelpText: String {
        guard let mutedUntil = settings.temporarilyMuteNotificationsUntil,
              AppSettings.isNotificationMuteActive(until: mutedUntil) else {
            return AppLocalization.string("10 分钟静音通知和声音")
        }

        return AppLocalization.format(
            "通知与声音已静音至 %@，点击恢复",
            formattedTemporaryMuteTime(mutedUntil)
        )
    }

    private var closedMascotStatus: MascotStatus {
        if viewModel.isDetachmentGestureActive {
            return .dragging
        }
        return MascotStatus.closedNotchStatus(
            representativePhase: representativeClosedSession?.phase,
            hasPendingPermission: hasPendingPermission,
            hasHumanIntervention: hasHumanIntervention
        )
    }

    private func latestHookMessageSession(from instances: [SessionState]) -> SessionState? {
        instances
            .filter { $0.phase != .ended && $0.compactHookMessage != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private func latestMascotSourceSession(from instances: [SessionState]) -> SessionState? {
        IslandMascotResolver.sourceSession(from: instances)
    }

    private func formattedTemporaryMuteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = settings.locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        viewModel.closedSize
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width
    }

    private var closedInnerWidth: CGFloat {
        max(0, closedContentWidth - (cornerRadiusInsets.closed.bottom * 2))
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // The docked notch keeps its established motion across experience themes.
    private var openAnimation: Animation {
        .spring(
            response: DockedNotchVisualStyle.openResponse,
            dampingFraction: DockedNotchVisualStyle.openDampingFraction,
            blendDuration: 0
        )
    }

    private var closeAnimation: Animation {
        .spring(
            response: DockedNotchVisualStyle.closeResponse,
            dampingFraction: DockedNotchVisualStyle.closeDampingFraction,
            blendDuration: 0
        )
    }

    // MARK: - Body

    var body: some View {
        instrumentedBody
            .environment(\.islandExperienceTheme, DockedNotchVisualStyle.contentTheme)
    }

    private var presentedBody: some View {
        bodyContent
            .offset(y: viewModel.closedPresentationOffsetY)
            .opacity(isVisible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }

    private var lifecycleBody: some View {
        presentedBody
            .onAppear {
                if !SessionMonitor.isRunningUnderXCTest {
                    sessionMonitor.startMonitoring()
                }
                viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)
                isVisible = !viewModel.shouldHideWindowPresentation
                viewModel.setManualAttentionActive(hasManualAttentionIndicator)
                handleProcessingChange()
                primeStartupPresentationState(sessionMonitor.instances)
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.startupDetachmentHintDelay)
            }
            .onDisappear {
                cancelScheduledDetachmentHintPresentation()
                cancelScheduledDelayedManualAttentionPresentation()
            }
            .onChange(of: viewModel.status) { oldStatus, newStatus in
                handleStatusChange(from: oldStatus, to: newStatus)
            }
    }

    private var settingsAwareBody: some View {
        lifecycleBody
            .onChange(of: settings.autoOpenCompletionPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .completed || $0 == .ended },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.autoOpenCompactedNotificationPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .compacted },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.temporarilyMuteNotificationsUntil) { _, mutedUntil in
                guard AppSettings.isNotificationMuteActive(until: mutedUntil) else { return }
                clearCompletionNotifications(keepPanelOpen: true)
                if viewModel.openReason == .notification {
                    viewModel.exitChat()
                }
            }
            .onChange(of: settings.autoHideWhenIdle) { _, _ in
                handleProcessingChange()
            }
    }

    private var contentTypeAwareBody: some View {
        settingsAwareBody
            .onChange(of: viewModel.contentType.id) { _, _ in
                maybePresentNextCompletionNotification()
            }
            .onReceive(sessionMonitor.$pendingInstances) { sessions in
                handlePendingSessionsChange(sessions)
            }
            .onReceive(sessionMonitor.$instances) { instances in
                viewModel.setManualAttentionActive(
                    instances.contains { $0.needsPromptNotification }
                )
                handleProcessingChange()
                handleManualAttentionChange(instances)
                handleCompletedReadyChange(instances)
                handleCompletionNotificationChange(instances)
            }
    }

    private var visibilityAwareBody: some View {
        contentTypeAwareBody
            .onChange(of: viewModel.isFullscreenEdgeRevealActive) { _, isActive in
                if isActive && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isFullscreenBrowserHiddenActive) { _, isActive in
                if isActive {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isIdleAutoHiddenActive) { _, isHidden in
                if isHidden && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isQuietBackgroundPresentationActive) { _, isActive in
                handleProcessingChange()
                if !isActive {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.presentationMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: viewModel.isFullscreenPhysicalNotchCompactActive) { _, isActive in
                if !isActive {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: settings.surfaceMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: settings.notchDetachmentHintPending) { _, isPending in
                if isPending {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                } else {
                    cancelScheduledDetachmentHintPresentation()
                }
            }
    }

    private var shortcutAwareBody: some View {
        visibilityAwareBody
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandOpenActiveSessionShortcut)) { _ in
                handleOpenActiveSessionShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandOpenSessionListShortcut)) { _ in
                handleOpenSessionListShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandPresentNotchDetachmentHint)) { _ in
                presentDetachmentHintIfNeeded(force: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandHookWalkthroughDemoShouldCloseNotch)) { _ in
                closeDockedNotchForHookWalkthroughDemo()
            }
            .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
                guard viewModel.status == .opened else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                    return
                }

                if case .instances = viewModel.contentType {
                    let effectiveHeight = activeCompletionNotification == nil
                        ? height
                        : max(height, SessionCompletionNotificationView.minimumContentHeight)
                    let measuredHeight = height > 0
                        ? closedNotchSize.height + effectiveHeight + 12
                        : nil
                    viewModel.updateOpenedMeasuredHeight(measuredHeight)
                } else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                }
            }
    }

    private func closeDockedNotchForHookWalkthroughDemo() {
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .opened else { return }

        withAnimation(viewModel.animation) {
            viewModel.notchClose()
        }
    }

    private var instrumentedBody: some View {
        shortcutAwareBody
    }

    private var bodyContent: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                styledNotchLayout
            }

            if isShowingDetachmentHint {
                NotchDetachmentHintView()
                    .offset(x: -22, y: 28)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                            removal: .opacity.animation(.easeOut(duration: 0.18))
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var styledNotchLayout: some View {
        let isOpened = viewModel.status == .opened
        let horizontalInset = isOpened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.bottom
        let shadowColor = (isOpened || isHovering) ? Color.black.opacity(0.7) : .clear

        return notchLayout
            .frame(maxWidth: isOpened ? notchSize.width : nil, alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding([.horizontal, .bottom], isOpened ? 12 : 0)
            .background(DockedNotchVisualStyle.surfaceColor)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DockedNotchVisualStyle.topSeparatorColor)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .shadow(color: shadowColor, radius: 6)
            .frame(
                maxWidth: isOpened ? notchSize.width : nil,
                maxHeight: isOpened ? notchSize.height : nil,
                alignment: .top
            )
            .animation(reduceMotion ? nil : (isOpened ? openAnimation : closeAnimation), value: viewModel.status)
            .animation(reduceMotion ? nil : viewModel.closedNotchResizeAnimation, value: notchSize)
            .animation(reduceMotion ? nil : .smooth, value: activityCoordinator.expandingActivity)
            .animation(reduceMotion ? nil : .smooth, value: hasPendingPermission)
            .animation(reduceMotion ? nil : .smooth, value: hasHumanIntervention)
            .animation(reduceMotion ? nil : .smooth, value: hasCompletedReadyState)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .onTapGesture {
                if !isOpened {
                    viewModel.notchOpen(reason: .click)
                }
            }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasHumanIntervention || hasCompletedReadyState
    }

    /// Keep the closed notch footprint stable and always show the leading icon.
    private var showsClosedLeadingIcon: Bool {
        viewModel.status != .opened || showClosedActivity
    }

    /// In fullscreen on physical-notch displays, the closed state should visually
    /// collapse back to the native macOS notch with no Island content shown.
    private var shouldHideClosedContent: Bool {
        viewModel.usesPhysicalNotchClosedPresentation && viewModel.status != .opened
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains pet and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))
                .zIndex(1)

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .zIndex(0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if shouldHideClosedContent {
                Color.clear
                    // Preserve the native-notch footprint without letting the
                    // empty closed state expand across the whole window.
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else if usesClosedIconOnlyLayout {
                closedIconOnlyContent
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else {
                HStack(spacing: 0) {
                    // Left side - pet always visible while closed.
                    if viewModel.status != .opened && showsClosedLeadingIcon {
                        MascotView(
                            kind: closedMascotKind,
                            status: closedMascotStatus,
                            size: petIconSize
                        )
                            .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
                        .frame(width: viewModel.status == .opened ? nil : sideWidth)
                        .padding(.leading, viewModel.status == .opened ? 8 : 0)
                    }

                    // Center content
                    if viewModel.status == .opened {
                        // Opened: show header content
                        openedHeaderContent
                    } else {
                        closedCenterContent
                    }

                    // Right side - in the closed state show session count by default,
                    // or the selected 7d usage remainder when available. Attention still wins.
                    if viewModel.status != .opened {
                        ZStack {
                            if hasManualAttentionIndicator {
                                BellIndicatorIcon(size: 12, color: closedIndicatorTone.emphasisColor)
                            } else if let usageWindow = closedTrailingUsageWindow {
                                ClosedNotchUsageRemainingIndicator(
                                    providerTitle: closedTrailingUsageProviderTitle,
                                    window: usageWindow
                                )
                            } else if activeSessionCount > 0 {
                                SessionCountIndicator(count: activeSessionCount)
                            }
                        }
                        .frame(width: closedTrailingWidth, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var usesClosedIconOnlyLayout: Bool {
        viewModel.status != .opened
            && closedNotchSize.width < minimumClosedNotchFullContentWidth
    }

    @ViewBuilder
    private var closedIconOnlyContent: some View {
        ZStack {
            if hasManualAttentionIndicator {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: min(16, iconOnlySize), weight: .semibold))
                    .foregroundStyle(closedIndicatorTone.emphasisColor)
                    .accessibilityLabel("需要处理")
            } else {
                MascotView(
                    kind: closedMascotKind,
                    status: closedMascotStatus,
                    size: iconOnlySize
                )
                .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var iconOnlySize: CGFloat {
        max(12, min(petIconSize, closedInnerWidth))
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    private var closedLeadingWidth: CGFloat {
        sideWidth
    }

    private var closedTrailingWidth: CGFloat {
        if closedTrailingUsageWindow != nil {
            return max(sideWidth, 34)
        }
        return sideWidth
    }

    private var closedCenterWidth: CGFloat {
        max(0, closedInnerWidth - closedLeadingWidth - closedTrailingWidth + (isBouncing ? 16 : 0))
    }

    private var compactCenterContentWidth: CGFloat {
        max(0, closedCenterWidth - compactCenterContentInset)
    }

    @ViewBuilder
    private var closedCenterContent: some View {
        HStack {
            if let message = closedCenterMessage {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(showClosedActivity ? 0.9 : 0.74))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 6)
                    .frame(width: compactCenterContentWidth, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityLabel("最新 hooks 消息")
            } else {
                // Preserve the compact notch footprint when there is no hook text to show.
                Color.clear
                    .frame(width: compactCenterContentWidth)
            }
        }
        .frame(width: closedCenterWidth, alignment: .center)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            if viewModel.openReason == .notification,
               activeCompletionNotification != nil {
                MascotView(
                    kind: completionNotificationMascotKind,
                    status: .idle,
                    size: petIconSize
                )
                .padding(.leading, 14)
            }

            if shouldShowOpenedHeaderUsage {
                UsageSummaryStripView(
                    providers: usageSummaryProviders,
                    inline: true,
                    displayStyle: openedHeaderUsageDisplayStyle,
                    locale: settings.locale
                )
                .padding(.leading, viewModel.openReason == .notification && activeCompletionNotification != nil ? 6 : 4)
                .layoutPriority(1)
                .zIndex(200)
            }

            Spacer(minLength: 0)

            NotchTemporaryMuteButton(
                isActive: areReminderNotificationsSuppressed,
                action: activateTemporaryReminderMute,
                helpText: temporaryMuteButtonHelpText
            )

            NotchSettingsButton(
                hasUnseenUpdate: updateManager.hasUnseenUpdate,
                action: openSettingsWindow
            )
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        IslandOpenedContentView(
            sessionMonitor: sessionMonitor,
            viewModel: viewModel,
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            style: .docked,
            activeCompletionNotification: activeCompletionNotification,
            onAttentionActionCompleted: {},
            onCompletionNotificationHoverChanged: handleCompletionNotificationHover,
            onDismissCompletionNotification: {
                clearCompletionNotifications(keepPanelOpen: true)
            }
        )
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    private var triggerForCurrentPresentation: IslandExpandedTrigger {
        switch viewModel.openReason {
        case .hover:
            return .hover
        case .notification:
            return .notification
        case .click, .boot, .unknown:
            return .click
        }
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)

        if viewModel.shouldHideWindowPresentation {
            isVisible = false
            return
        }

        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasHumanIntervention || hasCompletedReadyState {
            // Keep visible for attention/completion states but stop the active processing animation.
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()
            isVisible = true
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            cancelScheduledDetachmentHintPresentation()
            dismissDetachmentHint()
            if oldStatus != .opened, newStatus == .opened {
                recordIslandOpened()
            }
            // Clear completed-ready timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                completionReadyTimestamps.removeAll()
                clearCompletionNotifications(keepPanelOpen: true)
            }
        case .closed:
            if oldStatus == .opened {
                recordIslandClosed()
            }
            isVisible = !viewModel.shouldHideWindowPresentation
            maybePresentNextCompletionNotification()
            scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
        }
    }

    private func recordIslandOpened() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandOpened(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private func recordIslandClosed() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandClosed(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private var telemetryPresentationMode: String {
        switch viewModel.presentationMode {
        case .docked:
            return "docked"
        case .detached:
            return "detached"
        }
    }

    private func telemetryOpenSource(for reason: NotchOpenReason) -> String {
        switch reason {
        case .click:
            return "click"
        case .hover:
            return "hover"
        case .notification:
            return "notification"
        case .boot:
            return "boot"
        case .unknown:
            return "unknown"
        }
    }

    private func telemetryContentRoute(for contentType: NotchContentType) -> String {
        if activeCompletionNotification != nil {
            return "completion_notification"
        }
        if hasPendingPermission {
            return "approval"
        }
        if hasHumanIntervention {
            return "question"
        }

        switch contentType {
        case .instances:
            return "session_list"
        case .chat:
            return "session_detail"
        }
    }

    private func scheduleDetachmentHintPresentationIfNeeded(force: Bool = false, delay: TimeInterval) {
        guard force || settings.notchDetachmentHintPending else {
            cancelScheduledDetachmentHintPresentation()
            return
        }

        detachmentHintPresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [force] in
            detachmentHintPresentationWorkItem = nil
            presentDetachmentHintIfNeeded(force: force)
        }
        detachmentHintPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledDetachmentHintPresentation() {
        detachmentHintPresentationWorkItem?.cancel()
        detachmentHintPresentationWorkItem = nil
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if areReminderNotificationsSuppressed {
            previousPendingIds = currentIds
            return
        }

        let shouldSuppressAutoOpen = settings.smartSuppression &&
            TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()

        if viewModel.shouldSuppressAutomaticPresentation {
            previousPendingIds = currentIds
            return
        }

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !shouldSuppressAutoOpen {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func primeStartupPresentationState(_ instances: [SessionState]) {
        previousPendingIds = Set(instances.filter(\.needsAttention).map(\.stableId))
        previousCompletedReadyIds = Set(
            instances
                .filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
                .map(\.stableId)
        )
        _ = manualAttentionTracker.consumeNewAttentionSession(from: instances)
        primeCompletionNotificationTracking(instances)
    }

    private func presentDetachmentHintIfNeeded(force: Bool = false) {
        guard force || settings.notchDetachmentHintPending else { return }
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .closed else { return }
        guard !shouldHideClosedContent else { return }

        cancelScheduledDetachmentHintPresentation()
        settings.notchDetachmentHintPending = false
        detachmentHintDismissWorkItem?.cancel()

        if !isShowingDetachmentHint {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                isShowingDetachmentHint = true
            }
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingDetachmentHint = false
            }
        }
        detachmentHintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func dismissDetachmentHint() {
        detachmentHintDismissWorkItem?.cancel()
        detachmentHintDismissWorkItem = nil
        guard isShowingDetachmentHint else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingDetachmentHint = false
        }
    }

    private func handleManualAttentionChange(_ instances: [SessionState]) {
        guard let targetSession = manualAttentionTracker.consumeNewAttentionSession(from: instances) else {
            scheduleDelayedManualAttentionPresentationIfNeeded(instances)
            return
        }

        scheduleDelayedManualAttentionPresentationIfNeeded(instances)

        if areReminderNotificationsSuppressed {
            return
        }

        clearCompletionNotifications(keepPanelOpen: true)

        if viewModel.shouldSuppressAutomaticPresentation {
            return
        }

        if targetSession.needsPromptNotification {
            viewModel.presentNotificationAttention()
            return
        }

        viewModel.presentNotificationChat(for: targetSession)
    }

    private func scheduleDelayedManualAttentionPresentationIfNeeded(_ instances: [SessionState]) {
        delayedManualAttentionWorkItem?.cancel()
        delayedManualAttentionWorkItem = nil

        guard let readyAt = manualAttentionTracker.nextDelayedAttentionDate(from: instances) else {
            return
        }

        let delay = max(0, readyAt.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [self] in
            delayedManualAttentionWorkItem = nil
            handleManualAttentionChange(sessionMonitor.instances)
        }
        delayedManualAttentionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledDelayedManualAttentionPresentation() {
        delayedManualAttentionWorkItem?.cancel()
        delayedManualAttentionWorkItem = nil
    }

    private func handleCompletedReadyChange(_ instances: [SessionState]) {
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let completedIds = Set(completedSessions.map(\.stableId))
        let newCompletedIds = completedIds.subtracting(previousCompletedReadyIds)

        let now = Date()
        for session in completedSessions where newCompletedIds.contains(session.stableId) {
            completionReadyTimestamps[session.stableId] = now
        }

        let staleIds = Set(completionReadyTimestamps.keys).subtracting(completedIds)
        for staleId in staleIds {
            completionReadyTimestamps.removeValue(forKey: staleId)
        }
        previousCompletedReadyIds = completedIds

        if !newCompletedIds.isEmpty {
            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate the temporary completion badge.
                handleProcessingChange()
            }
        }
    }

    private func primeCompletionNotificationTracking(_ instances: [SessionState]) {
        previousCompletionNotificationPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )
        synchronizeCompletionNotifications(with: instances)
    }

    private func handleCompletionNotificationChange(_ instances: [SessionState]) {
        synchronizeCompletionNotifications(with: instances)

        if areReminderNotificationsSuppressed {
            if activeCompletionNotification != nil || !completionNotificationQueue.isEmpty {
                clearCompletionNotifications(keepPanelOpen: true)
            }

            previousCompletionNotificationPhases = Dictionary(
                uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
            )
            return
        }

        let currentPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )

        // Ambient popups are one-shot notifications. If the notch is already expanded for
        // some other reason, drop new ones instead of queueing them to appear later on
        // top of the normal expanded UI.
        if viewModel.status == .opened && activeCompletionNotification == nil {
            previousCompletionNotificationPhases = currentPhases
            completionNotificationQueue.removeAll()
            return
        }

        let newNotifications = instances
            .compactMap { session -> SessionCompletionNotification? in
                completionNotificationCandidate(
                    for: session,
                    previousPhase: previousCompletionNotificationPhases[session.stableId],
                    allSessions: instances
                )
            }
            .sorted { $0.session.lastActivity < $1.session.lastActivity }

        for notification in newNotifications {
            enqueueCompletionNotification(notification)
        }

        previousCompletionNotificationPhases = currentPhases
        maybePresentNextCompletionNotification()
    }

    private func completionNotificationCandidate(
        for session: SessionState,
        previousPhase: SessionPhase?,
        allSessions: [SessionState]
    ) -> SessionCompletionNotification? {
        let kind: SessionCompletionNotification.Kind
        if shouldQueueCompactedNotification(for: session, previousPhase: previousPhase) {
            kind = .compacted
        } else if shouldQueueCompletedNotification(for: session, previousPhase: previousPhase) {
            kind = .completed
        } else if shouldQueueEndedNotification(for: session, previousPhase: previousPhase) {
            kind = .ended
        } else {
            return nil
        }

        guard !isCompletionNotificationConsumed(session: session, kind: kind) else {
            return nil
        }

        if SessionCompletionNotificationPolicy.hasBlockingActiveSession(
            for: session,
            in: allSessions
        ) {
            markCompletionNotificationConsumed(session: session, kind: kind)
            return nil
        }

        return SessionCompletionNotification(session: session, kind: kind)
    }

    private func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompletionPanel
        )
    }

    private func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompletionPanel
        )
    }

    private func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueCompactedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompactedNotificationPanel
        )
    }

    private func synchronizeCompletionNotifications(with instances: [SessionState]) {
        let sessionsById = Dictionary(uniqueKeysWithValues: instances.map { ($0.stableId, $0) })

        if let active = activeCompletionNotification {
            if let latest = sessionsById[active.session.stableId] {
                activeCompletionNotification?.session = latest
            } else {
                dismissActiveCompletionNotification(closePanel: false, advanceQueue: true)
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
        guard !areReminderNotificationsSuppressed else { return }
        guard activeCompletionNotification == nil else { return }
        guard !completionNotificationQueue.isEmpty else { return }
        guard !viewModel.shouldSuppressAutomaticPresentation else { return }
        guard !hasPendingPermission && !hasHumanIntervention else { return }
        guard case .instances = viewModel.contentType else { return }

        if viewModel.status == .opened && viewModel.openReason != .notification {
            return
        }

        guard let nextNotification = dequeueNextPresentableCompletionNotification() else {
            return
        }
        activeCompletionNotification = nextNotification
        markCompletionNotificationConsumed(nextNotification)
        shouldDismissCompletionNotificationOnHoverExit = false

        if viewModel.status != .opened || viewModel.openReason != .notification {
            viewModel.notchOpen(reason: .notification)
        }

        scheduleCompletionNotificationDismissal(for: nextNotification.id)
    }

    private func dequeueNextPresentableCompletionNotification() -> SessionCompletionNotification? {
        while !completionNotificationQueue.isEmpty {
            let notification = completionNotificationQueue.removeFirst()
            guard isCompletionNotificationPresentable(notification) else {
                markCompletionNotificationConsumed(notification)
                continue
            }
            return notification
        }
        return nil
    }

    private func isCompletionNotificationPresentable(_ notification: SessionCompletionNotification) -> Bool {
        guard !isCompletionNotificationConsumed(notification) else { return false }
        guard SessionCompletionNotificationPolicy.hasRecentNotificationActivity(notification.session) else {
            return false
        }
        return !SessionCompletionNotificationPolicy.hasBlockingActiveSession(
            for: notification.session,
            in: sessionMonitor.instances
        )
    }

    private func scheduleCompletionNotificationDismissal(for notificationID: UUID) {
        completionNotificationDismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [self] in
            guard activeCompletionNotification?.id == notificationID else { return }
            dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
        }

        completionNotificationDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func clearCompletionNotifications(keepPanelOpen: Bool) {
        removeCompletionNotifications(matching: { _ in true }, keepPanelOpen: keepPanelOpen)
    }

    private func removeCompletionNotifications(
        matching shouldRemove: (SessionCompletionNotification.Kind) -> Bool,
        keepPanelOpen: Bool
    ) {
        let removedQueuedNotifications = completionNotificationQueue.filter { shouldRemove($0.kind) }
        completionNotificationQueue.removeAll { shouldRemove($0.kind) }
        for notification in removedQueuedNotifications {
            markCompletionNotificationConsumed(notification)
        }

        if let activeCompletionNotification, shouldRemove(activeCompletionNotification.kind) {
            dismissActiveCompletionNotification(closePanel: !keepPanelOpen, advanceQueue: true)
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
        dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
    }

    private func dismissActiveCompletionNotification(
        closePanel: Bool,
        advanceQueue: Bool
    ) {
        completionNotificationDismissWorkItem?.cancel()
        completionNotificationDismissWorkItem = nil
        shouldDismissCompletionNotificationOnHoverExit = false

        guard let dismissedNotification = activeCompletionNotification else {
            if advanceQueue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    maybePresentNextCompletionNotification()
                }
            }
            return
        }

        markCompletionNotificationConsumed(dismissedNotification)
        activeCompletionNotification = nil

        if closePanel,
           viewModel.status == .opened,
           viewModel.openReason == .notification,
           !hasPendingPermission,
           !hasHumanIntervention {
            viewModel.notchClose()
        }

        if advanceQueue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                maybePresentNextCompletionNotification()
            }
        }
    }

    private func isCompletionNotificationConsumed(
        session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) -> Bool {
        guard kind == .completed else { return false }
        return SessionCompletionNotificationRegistry.shared.isConsumed(session: session)
    }

    private func isCompletionNotificationConsumed(_ notification: SessionCompletionNotification) -> Bool {
        isCompletionNotificationConsumed(session: notification.session, kind: notification.kind)
    }

    private func markCompletionNotificationConsumed(
        session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) {
        guard kind == .completed else { return }
        SessionCompletionNotificationRegistry.shared.markConsumed(session: session)
    }

    private func markCompletionNotificationConsumed(_ notification: SessionCompletionNotification) {
        markCompletionNotificationConsumed(session: notification.session, kind: notification.kind)
    }

    private func openSettingsWindow() {
        updateManager.markUpdateSeen()
        SettingsWindowController.shared.present()
    }

    private func handleOpenActiveSessionShortcut() {
        guard let session = preferredShortcutSession else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleChat(for: session, reason: .click)
    }

    private func handleOpenSessionListShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleSessionList(reason: .click)
    }

    private func activateTemporaryReminderMute() {
        if areReminderNotificationsSuppressed {
            AppSettings.clearReminderNotificationMute()
        } else {
            AppSettings.muteReminderNotifications(for: Self.temporaryReminderMuteDuration)
            clearCompletionNotifications(keepPanelOpen: true)

            if viewModel.openReason == .notification {
                viewModel.exitChat()
            }
        }
    }

}

private struct NotchDetachmentHintView: View {
    @State private var isArrowNudging = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StraightDetachHintArrow()
                .stroke(
                    Color.white.opacity(0.86),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 76, height: 40)
                .offset(
                    x: -36 + (isArrowNudging ? -4 : 4),
                    y: 2 + (isArrowNudging ? -3 : 3)
                )
                .onAppear {
                    isArrowNudging = false
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isArrowNudging = true
                    }
                }
                .onDisappear {
                    isArrowNudging = false
                }

            Text(appLocalized: "拖动宠物，让宠物离岛工作")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.96))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
                .offset(y: 62)
        }
        .frame(width: 242, height: 118, alignment: .topTrailing)
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.string("拖动宠物，让宠物离岛工作")))
    }
}

private struct StraightDetachHintArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.maxX - 14, y: rect.maxY - 14)
        let end = CGPoint(x: rect.minX + 14, y: rect.minY + 16)

        path.move(to: start)
        path.addQuadCurve(
            to: end,
            control: CGPoint(x: rect.midX + 4, y: rect.midY + 6)
        )

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 12, y: end.y - 2))

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 6, y: end.y + 11))

        return path
    }
}

private struct NotchSettingsButton: View {
    let hasUnseenUpdate: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? .black : .white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                    )

                if hasUnseenUpdate {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black, lineWidth: 1.5)
                        )
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct NotchTemporaryMuteButton: View {
    let isActive: Bool
    let action: () -> Void
    let helpText: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: isActive ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconForegroundStyle: AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.white.opacity(isHovering ? 0.8 : 0.6))
        }
        return AnyShapeStyle(isHovering ? Color.black : Color.white.opacity(0.92))
    }

    private var backgroundFillColor: Color {
        if isActive {
            return Color.white.opacity(isHovering ? 0.12 : 0.06)
        }
        return isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }

    private var borderColor: Color {
        if isActive {
            return Color.white.opacity(isHovering ? 0.22 : 0.12)
        }
        return .clear
    }
}

private struct SessionCountIndicator: View {
    let count: Int
    private let closedNotchRightShift: CGFloat = 4

    var body: some View {
        PixelNumberView(
            value: count,
            color: .white.opacity(0.92),
            fontSize: count >= 10 ? 8.8 : 9.6,
            weight: .semibold,
            tracking: count >= 10 ? -0.15 : -0.05
        )
        .frame(minWidth: 18)
        .offset(x: closedNotchRightShift)
    }
}

private struct ClosedNotchUsageRemainingIndicator: View {
    let providerTitle: String?
    let window: UsageSummaryWindow
    private let closedNotchRightShift: CGFloat = 4

    var body: some View {
        Text(remainingText)
            .font(.system(size: remainingPercentage >= 100 ? 8.0 : 8.8, weight: .semibold, design: .rounded))
            .foregroundStyle(color(for: window.severity))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: 28, alignment: .trailing)
            .offset(x: closedNotchRightShift)
            .help(helpText)
            .accessibilityLabel(Text(helpText))
    }

    private var remainingPercentage: Int {
        Int(max(0, window.remainingPercentage).rounded())
    }

    private var remainingText: String {
        "\(remainingPercentage)%"
    }

    private var helpText: String {
        let title = providerTitle ?? ""
        let prefix = title.isEmpty ? window.label : "\(title) \(window.label)"
        return "\(prefix) \(remainingText) \(AppLocalization.string("剩余"))"
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
}
