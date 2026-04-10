//
//  SessionListView.swift
//  PingIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct SessionListView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @State private var expandedSessionStableID: String?

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run Claude Code, Codex CLI, or Codex App")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    // MARK: - Instances List

    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        isExpanded: expandedSessionStableID == session.stableId,
                        onActivate: { activateSession(session) },
                        onToggleExpanded: { toggleExpanded(session) },
                        onFocus: { activateSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onApproveForSession: { approveSessionForScope(session) },
                        onReject: { rejectSession(session) }
                    )
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 4)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OpenedPanelContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: sortedInstances.map(\.stableId)) { _, stableIDs in
            guard let expandedSessionStableID, !stableIDs.contains(expandedSessionStableID) else { return }
            self.expandedSessionStableID = nil
        }
    }

    // MARK: - Actions

    private func activateSession(_ session: SessionState) {
        Task {
            _ = await SessionLauncher.shared.activate(session)
        }
    }

    private func toggleExpanded(_ session: SessionState) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            if expandedSessionStableID == session.stableId {
                expandedSessionStableID = nil
            } else {
                expandedSessionStableID = session.stableId
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func approveSessionForScope(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let isExpanded: Bool
    let onActivate: () -> Void
    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isYabaiAvailable = false
    @ObservedObject private var settings = AppSettings.shared

    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.needsApprovalResponse
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        if session.needsQuestionResponse {
            return true
        }
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var providerLabel: String {
        session.messageBadgeDisplayName
    }

    private var interactionLabel: String {
        session.interactionDisplayName
    }

    private var providerColor: Color {
        session.clientTintColor
    }

    private var terminalSourceLabel: String? {
        session.terminalSourceBadgeLabel
    }

    private var titleFontSize: CGFloat {
        CGFloat(settings.contentFontSize)
    }

    private var detailFontSize: CGFloat {
        max(11, titleFontSize - 2)
    }

    private var detailsEnabled: Bool {
        settings.showAgentDetail
    }

    private var isMinimalCompactPresentation: Bool {
        session.shouldUseMinimalCompactPresentation
    }

    private var isCollapsedCompactPresentation: Bool {
        isMinimalCompactPresentation && !isExpanded
    }

    private var projectTitleFontSize: CGFloat {
        max(11, titleFontSize - 1)
    }

    private var sessionTitleFontSize: CGFloat {
        if isCollapsedCompactPresentation {
            return max(11, titleFontSize - 1)
        }
        return max(12, titleFontSize + 1)
    }

    var body: some View {
        HStack(alignment: isCollapsedCompactPresentation ? .center : .top, spacing: 10) {
            leadingContent

            if isCollapsedCompactPresentation {
                compactMetaLine
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        metaBadge(
                            timeLabel,
                            tint: Color.white.opacity(0.1),
                            foreground: .white.opacity(0.64),
                            fontDesign: .monospaced
                        )
                        metaBadge(providerLabel, tint: providerColor.opacity(0.2))
                        if let ideHostBadgeLabel = session.ideHostBadgeLabel {
                            metaBadge(
                                ideHostBadgeLabel,
                                tint: ideHostBadgeTint,
                                foreground: .white.opacity(0.9)
                            )
                        }
                        if let terminalSourceLabel {
                            metaBadge(
                                terminalSourceLabel,
                                tint: terminalBadgeTint,
                                foreground: .white.opacity(0.9)
                            )
                        }
                    }

                    trailingActions
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, isCollapsedCompactPresentation ? 5 : 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
        .saturation(isCollapsedCompactPresentation ? 0 : 1)
        .opacity(isCollapsedCompactPresentation ? 0.72 : 1)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(rowBorderColor, lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    private var leadingContent: some View {
        Group {
            if isMinimalCompactPresentation {
                baseLeadingContent
                    .onTapGesture(count: 2) { onActivate() }
                    .onTapGesture { onToggleExpanded() }
            } else {
                baseLeadingContent
                    .onTapGesture(count: 2) { onChat() }
                    .onTapGesture { onActivate() }
            }
        }
    }

    private var baseLeadingContent: some View {
        HStack(alignment: isCollapsedCompactPresentation ? .center : .top, spacing: 10) {
            avatarView

            VStack(alignment: .leading, spacing: isCollapsedCompactPresentation ? 0 : 5) {
                titleLine
                    .lineLimit(1)
                    .truncationMode(.tail)

                if shouldShowExpandedDetails {
                    previewLinesView
                        .transition(
                            .opacity.combined(with: .move(edge: .top))
                        )
                }
            }

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLine: Text {
        Text(session.projectName)
            .font(.system(size: projectTitleFontSize, weight: .semibold))
            .foregroundColor(.white.opacity(0.84))
        + Text(" · ")
            .font(.system(size: projectTitleFontSize, weight: .bold))
            .foregroundColor(.white.opacity(0.34))
        + Text(session.displayTitle)
            .font(.system(size: sessionTitleFontSize, weight: .bold))
            .foregroundColor(.white)
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))

            MascotView(
                kind: settings.mascotKind(for: session.mascotClient),
                status: MascotStatus(session: session),
                size: isCollapsedCompactPresentation ? 16 : 18
            )
            .padding(6)

            avatarStatusBadge
                .offset(x: 2, y: 2)
        }
        .frame(width: isCollapsedCompactPresentation ? 30 : 34, height: isCollapsedCompactPresentation ? 30 : 34)
    }

    @ViewBuilder
    private var avatarStatusBadge: some View {
        switch session.phase {
        case .processing, .compacting, .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 8, weight: .black))
                .foregroundColor(statusAccentColor)
                .frame(width: 14, height: 14)
                .background(Color.black.opacity(0.92))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(statusAccentColor.opacity(0.35), lineWidth: 1)
                )
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(statusAccentColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.8), lineWidth: 2)
                )
        case .idle, .ended:
            EmptyView()
        }
    }

    private var statusAccentColor: Color {
        if session.needsQuestionResponse {
            return TerminalColors.blue
        }
        if isWaitingForApproval {
            return TerminalColors.amber
        }
        switch session.phase {
        case .processing:
            return providerColor
        case .compacting:
            return TerminalColors.magenta
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return Color.white.opacity(0.28)
        case .waitingForApproval:
            return TerminalColors.amber
        }
    }

    private var timeLabel: String {
        SessionPhaseHelpers.timeBadgeLabel(for: session.attentionRequestedAt ?? session.lastActivity)
    }

    private var ideHostBadgeTint: Color {
        if session.ideHostBadgeLabel?.contains("Qoder") == true {
            return Color(red: 0.12, green: 0.88, blue: 0.56).opacity(0.2)
        }
        return Color.white.opacity(0.1)
    }

    private var terminalBadgeTint: Color {
        Color.white.opacity(0.1)
    }

    private var rowBackgroundColor: Color {
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.2 : 0.16)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.18 : 0.13)
            }
            return Color.white.opacity(isHovered ? 0.1 : 0.07)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(isHovered ? 0.16 : 0.11)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(isHovered ? 0.15 : 0.09)
        }
        if session.phase.isActive {
            return Color.white.opacity(isHovered ? 0.08 : 0.04)
        }
        return isHovered ? Color.white.opacity(0.06) : Color.clear
    }

    private var rowBorderColor: Color {
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.28)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.26)
            }
            return Color.white.opacity(isHovered ? 0.16 : 0.12)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(0.16)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(0.16)
        }
        return Color.white.opacity(isHovered ? 0.08 : 0.04)
    }

    private var shouldShowExpandedDetails: Bool {
        !isMinimalCompactPresentation || isExpanded
    }

    private var compactMetaLine: some View {
        HStack(spacing: 5) {
            metaBadge(
                timeLabel,
                tint: Color.white.opacity(0.08),
                foreground: .white.opacity(0.6),
                fontDesign: .monospaced,
                compact: true
            )

            metaBadge(
                providerLabel,
                tint: providerColor.opacity(0.18),
                foreground: .white.opacity(0.86),
                compact: true
            )

            if let terminalSourceLabel {
                metaBadge(
                    terminalSourceLabel,
                    tint: terminalBadgeTint,
                    foreground: .white.opacity(0.82),
                    compact: true
                )
            }
        }
    }

    @ViewBuilder
    private var previewLinesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let prefix = line.prefix {
                        Text(prefix)
                            .font(.system(size: detailFontSize, weight: .semibold))
                            .foregroundColor(line.prefixColor)
                    }

                    Text(line.text)
                        .font(.system(size: detailFontSize, weight: .medium))
                        .foregroundColor(line.textColor)
                        .lineLimit(1)
                }
            }
        }
    }

    private var previewLines: [QueuePreviewLine] {
        var lines: [QueuePreviewLine] = []

        if let userLine = latestUserLine {
            lines.append(
                QueuePreviewLine(
                    id: "user",
                    prefix: AppLocalization.string("你："),
                    prefixColor: .white.opacity(0.52),
                    text: userLine,
                    textColor: .white.opacity(0.62)
                )
            )
        }

        if let assistantLine = latestAssistantLine {
            lines.append(
                QueuePreviewLine(
                    id: "assistant",
                    prefix: previewAssistantPrefix,
                    prefixColor: assistantPrefixColor,
                    text: assistantLine,
                    textColor: assistantTextColor
                )
            )
        }

        if lines.isEmpty, let fallback = compactDetailSummary {
            lines.append(
                QueuePreviewLine(
                    id: "fallback",
                    prefix: AppLocalization.string("状态："),
                    prefixColor: .white.opacity(0.48),
                    text: fallback,
                    textColor: .white.opacity(0.56)
                )
            )
        }

        return Array(lines.prefix(detailsEnabled ? 2 : 1))
    }

    private var assistantPrefixLabel: String {
        if session.needsQuestionResponse || isWaitingForApproval {
            return interactionLabel
        }
        return session.providerDisplayName
    }

    private var previewAssistantPrefix: String? {
        let badgeLabel = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLabel = assistantPrefixLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixLabel.isEmpty, prefixLabel.caseInsensitiveCompare(badgeLabel) == .orderedSame {
            return nil
        }
        return prefixLabel.isEmpty ? nil : prefixLabel + "："
    }

    private var assistantPrefixColor: Color {
        providerColor.opacity(session.phase.isActive ? 0.96 : 0.92)
    }

    private var assistantTextColor: Color {
        if session.needsQuestionResponse {
            return .white.opacity(0.88)
        }
        if isWaitingForApproval {
            return .white.opacity(0.74)
        }
        if session.phase.isActive {
            return .white.opacity(0.66)
        }
        return .white.opacity(0.52)
    }

    private var latestUserLine: String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    private var latestAssistantLine: String? {
        if session.needsQuestionResponse {
            return sanitized(session.intervention?.summaryText) ?? AppLocalization.string("需要你的输入")
        }

        if isWaitingForApproval {
            if isInteractiveTool {
                return AppLocalization.string("等待你补充输入")
            }
            if let toolName = session.pendingToolName {
                return AppLocalization.format(
                    "等待批准 %@",
                    MCPToolFormatter.formatToolName(toolName)
                )
            }
            return AppLocalization.string("等待批准")
        }

        if session.phase == .processing {
            return sanitized(session.lastMessage) ?? AppLocalization.string("工作中...")
        }

        if session.phase == .compacting {
            return AppLocalization.string("正在压缩上下文...")
        }

        if session.phase == .waitingForInput, session.intervention == nil {
            return sanitized(session.lastMessage) ?? AppLocalization.string("等待你的下一条消息")
        }

        if let lastMessage = sanitized(session.lastMessage) {
            return lastMessage
        }

        return compactDetailSummary
    }

    @ViewBuilder
    private var trailingActions: some View {
        if session.needsQuestionResponse {
            HStack(spacing: 6) {
                IconButton(icon: "bubble.left") {
                    onChat()
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "terminal") {
                        onFocus()
                    }
                }
            }
        } else if isWaitingForApproval {
            InlineApprovalButtons(
                sessionAction: session.scopedApprovalAction,
                onChat: onChat,
                onApprove: onApprove,
                onApproveForSession: onApproveForSession,
                onReject: onReject
            )
        } else {
            HStack(spacing: 6) {
                IconButton(icon: "bubble.left") {
                    onChat()
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "eye") {
                        onFocus()
                    }
                }

                if session.shouldShowArchiveActionInPrimaryUI {
                    IconButton(icon: "archivebox") {
                        onArchive()
                    }
                }
            }
        }
    }

    private func metaBadge(
        _ text: String,
        tint: Color,
        foreground: Color = .white.opacity(0.92),
        fontDesign: Font.Design = .default,
        compact: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background(tint)
            .clipShape(Capsule())
    }

    private var compactDetailSummary: String? {
        switch session.phase {
        case .processing:
            return AppLocalization.string("工作中...")
        case .compacting:
            return AppLocalization.string("正在压缩上下文...")
        case .waitingForApproval:
            return session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待批准")
        case .waitingForInput:
            return session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待你的下一条消息")
        case .ended:
            return AppLocalization.string("会话已结束")
        case .idle:
            return sanitized(session.lastMessage) ?? session.projectName
        }
    }

    private func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

}

private struct QueuePreviewLine: Identifiable {
    let id: String
    let prefix: String?
    let prefixColor: Color
    let text: String
    let textColor: Color
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let sessionAction: SessionScopedApprovalAction?
    let onChat: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var showSessionButton = false

    var body: some View {
        HStack(spacing: 5) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            if let sessionAction {
                Button {
                    onApproveForSession()
                } label: {
                    Text(AppLocalization.string(sessionAction.compactButtonTitleKey))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TerminalColors.blue.opacity(0.24))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showSessionButton ? 1 : 0)
                .scaleEffect(showSessionButton ? 1 : 0.8)
            }

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showSessionButton = sessionAction != nil
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
