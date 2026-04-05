//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

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
                        onActivate: { activateSession(session) },
                        onFocus: { activateSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
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
    }

    // MARK: - Actions

    private func activateSession(_ session: SessionState) {
        Task {
            _ = await SessionLauncher.shared.activate(session)
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
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
    let onActivate: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isYabaiAvailable = false
    @ObservedObject private var settings = AppSettings.shared

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let codexBlue = Color(red: 0.36, green: 0.62, blue: 1.0)
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
        session.clientDisplayName
    }

    private var providerColor: Color {
        if session.clientInfo.brand == .qoder {
            return Color(red: 0.12, green: 0.88, blue: 0.56)
        }
        return session.provider == .claude ? claudeOrange : codexBlue
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingContent

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    metaBadge(providerLabel, tint: providerColor.opacity(0.2))
                    metaBadge(
                        timeLabel,
                        tint: Color.white.opacity(0.1),
                        foreground: .white.opacity(0.64),
                        fontDesign: .monospaced
                    )
                }

                trailingActions
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.phase)
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
        HStack(alignment: .top, spacing: 10) {
            avatarView

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: max(11, titleFontSize - 1), weight: .semibold))
                        .foregroundColor(.white.opacity(0.84))
                        .lineLimit(1)

                    Text("·")
                        .font(.system(size: max(11, titleFontSize - 1), weight: .bold))
                        .foregroundColor(.white.opacity(0.34))

                    Text(session.displayTitle)
                        .font(.system(size: max(12, titleFontSize + 1), weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                previewLinesView
            }

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { onChat() }
                .exclusively(
                    before: TapGesture()
                        .onEnded { onActivate() }
                )
        )
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))

            NotchPetIcon(
                style: settings.notchPetStyle,
                size: 18,
                tone: avatarTone,
                isProcessing: session.phase.isActive
            )
            .padding(6)

            avatarStatusBadge
                .offset(x: 2, y: 2)
        }
        .frame(width: 34, height: 34)
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

    private var avatarTone: NotchIndicatorTone {
        if session.needsQuestionResponse {
            return .intervention
        }
        if isWaitingForApproval {
            return .warning
        }
        if session.clientInfo.brand == .qoder {
            return .qoder
        }
        return session.provider == .codex ? .codex : .claude
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

    private var rowBackgroundColor: Color {
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
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(0.16)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(0.16)
        }
        return Color.white.opacity(isHovered ? 0.08 : 0.04)
    }

    @ViewBuilder
    private var previewLinesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(line.prefix)
                        .font(.system(size: detailFontSize, weight: .semibold))
                        .foregroundColor(line.prefixColor)

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
                    prefix: "你：",
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
                    prefix: session.providerDisplayName + "：",
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
                    prefix: "状态：",
                    prefixColor: .white.opacity(0.48),
                    text: fallback,
                    textColor: .white.opacity(0.56)
                )
            )
        }

        return Array(lines.prefix(detailsEnabled ? 2 : 1))
    }

    private var assistantPrefixColor: Color {
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(0.96)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(0.96)
        }
        return providerColor.opacity(0.92)
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
            return sanitized(session.intervention?.summaryText) ?? "需要你的输入"
        }

        if isWaitingForApproval {
            if isInteractiveTool {
                return "等待你补充输入"
            }
            if let toolName = session.pendingToolName {
                return "等待批准 " + MCPToolFormatter.formatToolName(toolName)
            }
            return "等待批准"
        }

        if session.phase == .processing {
            return sanitized(session.lastMessage) ?? "工作中..."
        }

        if session.phase == .compacting {
            return "正在压缩上下文..."
        }

        if session.phase == .waitingForInput, session.intervention == nil {
            return sanitized(session.lastMessage) ?? "等待你的下一条消息"
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
                onChat: onChat,
                onApprove: onApprove,
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

                if session.phase == .idle || (session.phase == .waitingForInput && session.intervention == nil) {
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
        fontDesign: Font.Design = .default
    ) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint)
            .clipShape(Capsule())
    }

    private var compactDetailSummary: String? {
        switch session.phase {
        case .processing:
            return "工作中..."
        case .compacting:
            return "正在压缩上下文..."
        case .waitingForApproval:
            return session.needsQuestionResponse ? "需要你的输入" : "等待批准"
        case .waitingForInput:
            return session.needsQuestionResponse ? "需要你的输入" : "等待你的下一条消息"
        case .ended:
            return "会话已结束"
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
    let prefix: String
    let prefixColor: Color
    let text: String
    let textColor: Color
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

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
