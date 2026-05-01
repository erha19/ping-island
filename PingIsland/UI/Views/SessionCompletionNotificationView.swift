import SwiftUI

private struct SessionCompletionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SessionCompletionNotification: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case completed
        case ended
        case compacted

        var statusLabelKey: String {
            switch self {
            case .completed:
                return "完成"
            case .ended:
                return "结束"
            case .compacted:
                return "已压缩"
            }
        }

        var fallbackAssistantMessageKey: String {
            switch self {
            case .completed:
                return "会话已完成，点击查看完整结果。"
            case .ended:
                return "会话已结束"
            case .compacted:
                return "上下文已压缩"
            }
        }

        var usesAssistantPreview: Bool {
            switch self {
            case .completed, .ended:
                return true
            case .compacted:
                return false
            }
        }
    }

    let id: UUID
    var session: SessionState
    let kind: Kind
    let queuedAt: Date

    init(
        id: UUID = UUID(),
        session: SessionState,
        kind: Kind,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.queuedAt = queuedAt
    }
}

enum SessionCompletionPreviewBuilder {
    static func latestUserText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    static func latestAssistantText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                return sanitized(text)
            case .thinking(let text):
                return sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                return preview.map { "\(label) \($0)" } ?? label
            case .interrupted:
                return "已中断"
            case .user:
                continue
            }
        }

        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage)
    }

    static func latestAssistantText(
        for session: SessionState,
        notificationKind: SessionCompletionNotification.Kind
    ) -> String? {
        guard notificationKind.usesAssistantPreview else { return nil }
        return latestAssistantText(for: session)
    }

    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

enum SessionCompletionStateEvaluator {
    static func isCompletedReadySession(_ session: SessionState) -> Bool {
        guard session.phase == .waitingForInput else { return false }
        guard session.intervention == nil else { return false }
        return hasCompletedAssistantReply(for: session)
    }

    static func allowsEndedNotificationAfterWaitingForInput(_ session: SessionState) -> Bool {
        guard session.phase == .ended else { return false }
        guard session.intervention == nil else { return false }
        return session.clientInfo.normalizedForClaudeRouting().profileID == "qoder-cli"
    }

    /// Treat tool-only or commentary-only updates as in-progress. A completion notification
    /// should only fire once the session has an actual assistant reply ready for the user.
    static func hasCompletedAssistantReply(for session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return session.lastMessageRole == "assistant"
    }
}

struct SessionCompletionNotificationView: View {
    static let minimumContentHeight: CGFloat = 172
    static let maximumAssistantContentHeight: CGFloat = 300

    let notification: SessionCompletionNotification
    let presentationStyle: SessionCompletionNotificationPresentationStyle
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var measuredAssistantContentHeight: CGFloat = 0

    init(
        notification: SessionCompletionNotification,
        presentationStyle: SessionCompletionNotificationPresentationStyle = .panel,
        onHoverChanged: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.notification = notification
        self.presentationStyle = presentationStyle
        self.onHoverChanged = onHoverChanged
        self.onDismiss = onDismiss
    }

    private var session: SessionState { notification.session }

    private var assistantLabel: String {
        session.providerDisplayName
    }

    private var providerTint: Color {
        session.clientTintColor
    }

    private var assistantPrefixColor: Color {
        providerTint.opacity(session.phase.isActive ? 0.96 : 0.9)
    }

    private var assistantTextColor: Color {
        .white.opacity(0.82)
    }

    private var bodyFontSize: CGFloat {
        max(12, CGFloat(settings.contentFontSize))
    }

    private var userText: String? {
        SessionCompletionPreviewBuilder.latestUserText(for: session)
    }

    private var assistantText: String? {
        SessionCompletionPreviewBuilder.latestAssistantText(
            for: session,
            notificationKind: notification.kind
        )
    }

    private var assistantContentHeight: CGFloat? {
        guard measuredAssistantContentHeight > 0 else { return nil }
        return min(measuredAssistantContentHeight, Self.maximumAssistantContentHeight)
    }

    private var assistantLabelText: String {
        assistantLabel + "："
    }

    @ViewBuilder
    private var assistantContent: some View {
        if let assistantText {
            MarkdownText(
                assistantText,
                color: assistantTextColor,
                fontSize: bodyFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(appLocalized: notification.kind.fallbackAssistantMessageKey)
                .font(.system(size: bodyFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var assistantScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            assistantContent
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SessionCompletionContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .frame(height: assistantContentHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(assistantLabelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(assistantPrefixColor)

            assistantScrollView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var containerCornerRadius: CGFloat { 16 }

    @ViewBuilder
    private var contentCard: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(appLocalized: "你：")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.48))

                Text(userText ?? session.titleOnlySubagentDisplayTitle)
                    .font(.system(size: bodyFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(AppLocalization.string(notification.kind.statusLabelKey))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            assistantSection
        }

        switch presentationStyle {
        case .panel:
            content
                .background(
                    RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
        case .bubble:
            content
        }
    }

    private var outerHorizontalPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 14
        case .bubble:
            return 0
        }
    }

    private var outerTopPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 8
        case .bubble:
            return 0
        }
    }

    private var outerBottomPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 12
        case .bubble:
            return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contentCard
        }
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.top, outerTopPadding)
        .padding(.bottom, outerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(
            presentationStyle == .bubble
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .onPreferenceChange(SessionCompletionContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            measuredAssistantContentHeight = height
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onDisappear {
            onHoverChanged(false)
        }
        .onTapGesture {
            onDismiss()
        }
    }
}

enum SessionCompletionNotificationPresentationStyle: Equatable {
    case panel
    case bubble
}
