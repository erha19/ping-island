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

struct OpenedPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = SessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousApprovalIds: Set<String> = []
    @State private var previousQuestionIds: Set<String> = []
    @State private var previousQuestionInterventionIDs: [String: String] = [:]
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var hasPrimedSoundTransitions: Bool = false
    @State private var previousProcessingIds: Set<String> = []
    @State private var previousAttentionSoundIds: Set<String> = []
    @State private var previousCompletionSoundIds: Set<String> = []
    @State private var previousTaskErrorIds: Set<String> = []
    @State private var previousResourceLimitIds: Set<String> = []
    @State private var previousCompletionNotificationPhases: [String: SessionPhase] = [:]
    @State private var completionNotificationQueue: [SessionCompletionNotification] = []
    @State private var activeCompletionNotification: SessionCompletionNotification?
    @State private var completionNotificationDismissWorkItem: DispatchWorkItem?
    @State private var shouldDismissCompletionNotificationOnHoverExit: Bool = false

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
            $0.needsApprovalResponse || $0.intervention != nil
        }
    }

    private var activeSessionCount: Int {
        sessionMonitor.instances.count
    }

    /// Most recently active live session that has a hook message we can surface in the compact notch.
    private var latestHookMessageSession: SessionState? {
        sessionMonitor.instances
            .filter { $0.phase != .ended && $0.compactHookMessage != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
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
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
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

    private var completionNotificationPetTone: NotchIndicatorTone {
        guard let session = activeCompletionNotification?.session else { return .normal }
        if session.clientInfo.brand == .codebuddy {
            return .codebuddy
        }
        if session.clientInfo.brand == .qoder {
            return .qoder
        }
        return session.provider == .codex ? .codex : .claude
    }

    private var closedPetActivity: NotchPetActivity {
        if isProcessing {
            return .processing
        }
        if activeSessionCount == 0 {
            return .sleeping
        }
        return .idle
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

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasHumanIntervention)
                    .animation(.smooth, value: hasCompletedReadyState)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .offset(y: viewModel.closedPresentationOffsetY)
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            isVisible = !viewModel.shouldHideClosedPresentation
            viewModel.setManualAttentionActive(hasManualAttentionIndicator)
            handleProcessingChange()
            handleApprovalSessionsChange(sessionMonitor.instances)
            primeCompletionNotificationTracking(sessionMonitor.instances)
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: viewModel.contentType.id) { _, _ in
            maybePresentNextCompletionNotification()
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            viewModel.setManualAttentionActive(
                instances.contains { $0.needsApprovalResponse || $0.intervention != nil }
            )
            handleProcessingChange()
            handleSessionSoundTransitions(instances)
            handleApprovalSessionsChange(instances)
            handleQuestionInterventionChange(instances)
            handleWaitingForInputChange(instances)
            handleCompletionNotificationChange(instances)
        }
        .onChange(of: viewModel.isFullscreenEdgeRevealActive) { _, isActive in
            if isActive && viewModel.status != .opened {
                isVisible = false
            } else {
                handleProcessingChange()
            }
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

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    private var sortedHoverSessions: [SessionState] {
        sessionMonitor.instances.sorted { $0.shouldSortBeforeInQueue($1) }
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

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
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
            } else {
                HStack(spacing: 0) {
                    // Left side - pet always visible while closed; permission indicator appears only when needed
                    if viewModel.status != .opened && showsClosedLeadingIcon {
                        HStack(spacing: 4) {
                            NotchPetIcon(
                                style: settings.notchPetStyle,
                                size: petIconSize,
                                tone: closedIndicatorTone,
                                activity: closedPetActivity
                            )
                                .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)

                            // Attention indicator follows the active state tone so question mode stays color-consistent.
                            if hasPendingPermission || hasHumanIntervention {
                                PermissionIndicatorIcon(size: 14, color: closedIndicatorTone.emphasisColor)
                                    .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                            }
                        }
                        .frame(width: viewModel.status == .opened ? nil : sideWidth + ((hasPendingPermission || hasHumanIntervention) ? 18 : 0))
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
                    // or a bell when manual attention is needed. Hide it when settings are visible.
                    if viewModel.status != .opened {
                        ZStack {
                            if hasManualAttentionIndicator {
                                BellIndicatorIcon(size: 14, color: closedIndicatorTone.emphasisColor)
                            } else if activeSessionCount > 0 {
                                SessionCountIndicator(count: activeSessionCount)
                            }
                        }
                        .frame(width: sideWidth, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    private var closedLeadingWidth: CGFloat {
        sideWidth + ((hasPendingPermission || hasHumanIntervention) ? 18 : 0)
    }

    private var closedTrailingWidth: CGFloat {
        sideWidth
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
        HStack(spacing: 12) {
            if viewModel.openReason == .notification,
               activeCompletionNotification != nil {
                NotchPetIcon(
                    style: settings.notchPetStyle,
                    size: petIconSize,
                    tone: completionNotificationPetTone,
                    activity: .idle
                )
                .padding(.leading, 14)
            }

            Spacer()

            NotchSettingsButton(
                hasUnseenUpdate: updateManager.hasUnseenUpdate,
                action: openSettingsWindow
            )
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                if viewModel.openReason == .notification,
                   let notification = activeCompletionNotification {
                    SessionCompletionNotificationView(
                        notification: notification,
                        onHoverChanged: handleCompletionNotificationHover,
                        onDismiss: {
                            clearCompletionNotifications(keepPanelOpen: true)
                        }
                    )
                } else if viewModel.openReason == .hover {
                    SessionHoverDashboardView(
                        sessions: sortedHoverSessions,
                        sessionMonitor: sessionMonitor
                    )
                } else {
                    SessionListView(
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                }
            case .chat(let session):
                let liveSession = sessionMonitor.instances.first(where: { $0.sessionId == session.sessionId }) ?? session

                if liveSession.provider == .claude {
                    ChatView(
                        sessionId: liveSession.sessionId,
                        initialSession: liveSession,
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                } else {
                    CodexSessionView(
                        session: liveSession,
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                }
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if viewModel.shouldHideClosedPresentation {
            isVisible = viewModel.status == .opened
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
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
                clearCompletionNotifications(keepPanelOpen: true)
            }
        case .closed:
            isVisible = !viewModel.shouldHideClosedPresentation
            maybePresentNextCompletionNotification()
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

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

    private func handleApprovalSessionsChange(_ instances: [SessionState]) {
        let approvalSessions = instances.filter { $0.needsApprovalResponse }
        let currentApprovalIds = Set(approvalSessions.map(\.stableId))
        let newApprovalIds = currentApprovalIds.subtracting(previousApprovalIds)

        guard !newApprovalIds.isEmpty else {
            previousApprovalIds = currentApprovalIds
            return
        }

        clearCompletionNotifications(keepPanelOpen: true)

        if viewModel.shouldSuppressAutomaticPresentation {
            previousApprovalIds = currentApprovalIds
            return
        }

        let targetSession = approvalSessions
            .filter { newApprovalIds.contains($0.stableId) }
            .sorted {
                let dateA = $0.attentionRequestedAt ?? $0.lastActivity
                let dateB = $1.attentionRequestedAt ?? $1.lastActivity
                return dateA > dateB
            }
            .first

        if let targetSession {
            if viewModel.status != .opened {
                viewModel.notchOpen(reason: .notification)
            }
            viewModel.showChat(for: targetSession)
        }

        previousApprovalIds = currentApprovalIds
    }

    private func handleQuestionInterventionChange(_ instances: [SessionState]) {
        let questionSessions = instances.filter { $0.needsQuestionResponse }
        let currentQuestionIds = Set(questionSessions.map(\.stableId))
        let currentQuestionInterventionIDs = Dictionary(
            uniqueKeysWithValues: questionSessions.map { session in
                (session.stableId, session.intervention?.id ?? "")
            }
        )
        let newQuestionIds = currentQuestionIds.subtracting(previousQuestionIds)
        let refreshedQuestionIds = Set<String>(
            currentQuestionInterventionIDs.compactMap { sessionId, interventionId in
                guard let previousInterventionId = previousQuestionInterventionIDs[sessionId],
                      !previousInterventionId.isEmpty,
                      previousInterventionId != interventionId else {
                    return nil
                }
                return sessionId
            }
        )
        let attentionQuestionIds = newQuestionIds.union(refreshedQuestionIds)

        guard !attentionQuestionIds.isEmpty else {
            previousQuestionIds = currentQuestionIds
            previousQuestionInterventionIDs = currentQuestionInterventionIDs
            return
        }

        clearCompletionNotifications(keepPanelOpen: true)

        if viewModel.shouldSuppressAutomaticPresentation {
            previousQuestionIds = currentQuestionIds
            previousQuestionInterventionIDs = currentQuestionInterventionIDs
            return
        }

        let targetSession = questionSessions
            .filter { attentionQuestionIds.contains($0.stableId) }
            .sorted {
                let dateA = $0.lastUserMessageDate ?? $0.lastActivity
                let dateB = $1.lastUserMessageDate ?? $1.lastActivity
                return dateA > dateB
            }
            .first

        if let targetSession {
            if viewModel.status == .opened {
                viewModel.notchClose()
                DispatchQueue.main.async {
                    viewModel.notchOpen(reason: .notification)
                    viewModel.showChat(for: targetSession)
                }
            } else {
                viewModel.notchOpen(reason: .notification)
                viewModel.showChat(for: targetSession)
            }
        }

        previousQuestionIds = currentQuestionIds
        previousQuestionInterventionIDs = currentQuestionInterventionIDs
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let allWaitingIds = Set(
            instances
                .filter { $0.phase == .waitingForInput }
                .map(\.stableId)
        )
        let newWaitingIds = allWaitingIds.subtracting(previousWaitingForInputIds)

        // Only completed sessions without intervention should get the temporary green checkmark.
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let completedIds = Set(completedSessions.map(\.stableId))

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in completedSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(completedIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
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

        previousWaitingForInputIds = allWaitingIds
    }

    private func primeCompletionNotificationTracking(_ instances: [SessionState]) {
        previousCompletionNotificationPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )
        synchronizeCompletionNotifications(with: instances)
    }

    private func handleCompletionNotificationChange(_ instances: [SessionState]) {
        synchronizeCompletionNotifications(with: instances)

        let currentPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )

        // Completion popups are one-shot ambient notifications. If the notch is already
        // expanded for some other reason, drop new completion popups instead of queueing
        // them to appear later on top of the normal expanded UI.
        if viewModel.status == .opened && activeCompletionNotification == nil {
            previousCompletionNotificationPhases = currentPhases
            completionNotificationQueue.removeAll()
            return
        }

        let newNotifications = instances
            .compactMap { session -> SessionCompletionNotification? in
                let previousPhase = previousCompletionNotificationPhases[session.stableId]

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
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return true
    }

    private func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return true
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
        guard activeCompletionNotification == nil else { return }
        guard !completionNotificationQueue.isEmpty else { return }
        guard !viewModel.shouldSuppressAutomaticPresentation else { return }
        guard !hasPendingPermission && !hasHumanIntervention else { return }
        guard case .instances = viewModel.contentType else { return }

        if viewModel.status == .opened && viewModel.openReason != .notification {
            return
        }

        let nextNotification = completionNotificationQueue.removeFirst()
        activeCompletionNotification = nextNotification
        shouldDismissCompletionNotificationOnHoverExit = false

        if viewModel.status != .opened || viewModel.openReason != .notification {
            viewModel.notchOpen(reason: .notification)
        }

        playEventSoundIfNeeded(.taskCompleted, sessions: [nextNotification.session])
        scheduleCompletionNotificationDismissal(for: nextNotification.id)
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
        completionNotificationQueue.removeAll()
        dismissActiveCompletionNotification(closePanel: !keepPanelOpen, advanceQueue: false)
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

        guard activeCompletionNotification != nil else {
            if advanceQueue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    maybePresentNextCompletionNotification()
                }
            }
            return
        }

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

    private func handleSessionSoundTransitions(_ instances: [SessionState]) {
        if !hasPrimedSoundTransitions {
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

        let isNewAttention = !newAttentionIds.subtracting(previousAttentionSoundIds).isEmpty
        let isNewTaskError = !errorDeltaIds.isEmpty
        let isNewResourceLimit = !newResourceLimitIds.subtracting(previousResourceLimitIds).isEmpty

        if isNewTaskError {
            playEventSoundIfNeeded(.taskError, sessions: errorSessions)
        } else if isNewResourceLimit {
            playEventSoundIfNeeded(.resourceLimit, sessions: resourceLimitedSessions)
        } else if isNewAttention {
            playEventSoundIfNeeded(.attentionRequired, sessions: attentionSessions)
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

        Task {
            let shouldPlaySound = await shouldPlayNotificationSound(for: sessions)
            if shouldPlaySound {
                _ = await MainActor.run {
                    AppSettings.playSound(for: event)
                }
            }
        }
    }

    private func openSettingsWindow() {
        updateManager.markUpdateSeen()
        SettingsWindowController.shared.present()
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
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
