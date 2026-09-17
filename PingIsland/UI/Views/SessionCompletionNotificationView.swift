import SwiftUI

private struct SessionCompletionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

nonisolated struct SessionCompletionNotification: Equatable, Identifiable {
    enum Kind: String, Hashable, Sendable {
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
    let session: SessionState
    let kind: Kind
    let queuedAt: Date
    let identity: Identity

    enum Identity: Hashable {
        case completed(SessionCompletionKey)
        case compacted(sessionId: String, incarnationID: UUID, sequence: UInt64)
        case lifecycle(kind: Kind, sessionId: String, sequence: UInt64, turnId: String?)
    }

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
        if kind == .completed, let key = SessionCompletionKey.make(for: session) {
            self.identity = .completed(key)
        } else if kind == .compacted {
            self.identity = .compacted(
                sessionId: session.sessionId,
                incarnationID: session.lifecycleIncarnationID,
                sequence: session.compactionSequence
            )
        } else {
            self.identity = .lifecycle(
                kind: kind,
                sessionId: session.sessionId,
                sequence: session.completionSequence,
                turnId: session.latestTurnId
            )
        }
    }
}

enum SessionCompletionPreviewBuilder {
    static func latestUserText(for session: SessionState) -> String? {
        let isRemoteCodex = session.provider == .codex && session.ingress == .remoteBridge
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                // An empty prompt still advances this boundary without adding
                // a chat item. Do not pair an older question with the new reply.
                if isRemoteCodex {
                    guard let submittedAt = session.conversationInfo.lastUserMessageDate,
                          item.timestamp >= submittedAt else { return nil }
                }
                return sanitized(text)
            }
        }
        return isRemoteCodex ? nil : sanitized(session.firstUserMessage)
    }

    static func latestAssistantText(for session: SessionState) -> String? {
        // A remote turn can complete without a prompt or reply body. Keep the
        // notification, but do not present an earlier turn's text as its result.
        if session.provider == .codex,
           session.ingress == .remoteBridge,
           session.lastMessageRole != "assistant" {
            return nil
        }

        var activityFallback: String?
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                if let text = sanitized(text) { return text }
            case .thinking(let text):
                activityFallback = activityFallback ?? sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                activityFallback = activityFallback ?? (preview.map { "\(label) \($0)" } ?? label)
            case .interrupted:
                activityFallback = activityFallback ?? "已中断"
            case .user:
                return activityFallback
            }
        }

        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage) ?? activityFallback
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

nonisolated enum SessionCompletionStateEvaluator {
    /// A Stop or completed idle turn is authoritative even if its final text is
    /// written to the transcript later, or never sent by a remote hook.
    static func isCompletedReadySession(_ session: SessionState) -> Bool {
        guard session.connectionState == .connected else { return false }
        guard case nil = session.intervention else { return false }
        guard !session.needsPromptNotification else { return false }
        if session.provider == .codex {
            // Remote discovery reports idle metadata before any Stop is observed.
            if session.ingress == .remoteBridge, !session.hasRemoteCodexTurnCompletion {
                return false
            }
            return session.phase == .idle && !session.isCodexTurnInterrupted
        }
        return session.phase == .waitingForInput || isCompletedOpenCodeIdleSession(session)
    }

    private static func isCompletedOpenCodeIdleSession(_ session: SessionState) -> Bool {
        session.phase == .idle && session.clientInfo.brand == .opencode
    }

    static func allowsEndedNotificationAfterWaitingForInput(_ session: SessionState) -> Bool {
        guard session.phase == .ended else { return false }
        guard case nil = session.intervention else { return false }
        // Qoder CLI and Kimi both use "Stop" for turn-end (goes to .waitingForInput)
        // and "SessionEnd" for actual session closure.
        return session.clientInfo.isQoderCLIClient
            || session.clientInfo.isKimiClient
    }

    /// Transcript evidence remains useful for previews, but is not a completion gate.
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

@MainActor
final class SessionCompletionNotificationRegistry {
    static let shared = SessionCompletionNotificationRegistry()

    private var consumedIdentities = Set<SessionCompletionNotification.Identity>()
    private var pending: [SessionCompletionNotification] = []

    var pendingNotifications: [SessionCompletionNotification] { pending }

    func isConsumed(session: SessionState) -> Bool {
        guard let key = SessionCompletionKey.make(for: session) else { return false }
        return consumedIdentities.contains(.completed(key))
    }

    func markConsumed(session: SessionState) {
        guard let key = SessionCompletionKey.make(for: session) else { return }
        consumedIdentities.insert(.completed(key))
    }

    func isConsumed(_ notification: SessionCompletionNotification) -> Bool {
        consumedIdentities.contains(notification.identity)
    }

    func markConsumed(_ notification: SessionCompletionNotification) {
        consumedIdentities.insert(notification.identity)
    }

    func enqueue(_ notification: SessionCompletionNotification) {
        guard !isConsumed(notification),
              !pending.contains(where: { $0.identity == notification.identity }) else { return }
        pending.append(notification)
    }

    func dequeueNext() -> SessionCompletionNotification? {
        pending.removeAll(where: isConsumed)
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        markConsumed(next)
        return next
    }

    func removePending(matching predicate: (SessionCompletionNotification.Kind) -> Bool) {
        let removed = pending.filter { predicate($0.kind) }
        pending.removeAll { predicate($0.kind) }
        for notification in removed {
            markConsumed(notification)
        }
    }
}

enum SessionCompletionNotificationPolicy {
    private static let notificationRecencyWindow: TimeInterval = 60

    static func trackingStates(
        for sessions: [SessionState]
    ) -> [String: (phase: SessionPhase, completionKey: SessionCompletionKey?)] {
        Dictionary(uniqueKeysWithValues: sessions.map {
            (trackingID(for: $0), trackingState(for: $0))
        })
    }

    static func trackingState(
        for session: SessionState
    ) -> (phase: SessionPhase, completionKey: SessionCompletionKey?) {
        var snapshot = session
        if snapshot.provider == .codex, snapshot.ingress == .remoteBridge {
            // Losing transport must not erase the observed turn identity.
            // Notification eligibility still checks the actual connection state.
            snapshot.connectionState = .connected
        }
        return (phase: session.phase, completionKey: SessionCompletionKey.make(for: snapshot))
    }

    static func trackingID(for session: SessionState) -> String {
        // Remote discovery omits the PID that hooks may report or change.
        if session.provider == .codex, session.ingress == .remoteBridge {
            return session.sessionId
        }
        return session.stableId
    }

    static func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        previousCompletionKey: SessionCompletionKey? = nil,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }

        if session.provider == .codex {
            guard session.phase == .idle, let previousPhase else { return false }
            if session.ingress == .remoteBridge, previousPhase == .idle {
                // Discovery and Stop can both be idle; only a new Stop key queues a popup.
                guard SessionCompletionKey.make(for: session) != previousCompletionKey else {
                    return false
                }
            } else if !isCodexCompletionSourcePhase(previousPhase) {
                return false
            }
            return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
        }

        // A question can be resolved without changing waitingForInput; the
        // completion identity, not the phase alone, deduplicates that transition.
        return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
    }

    static func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now) else {
            return false
        }
        if previousPhase == .waitingForInput {
            return SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(session)
        }
        return true
    }

    static func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard previousPhase == .compacting else { return false }
        guard session.phase != .compacting else { return false }
        return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
    }

    static func hasRecentNotificationActivity(
        _ session: SessionState,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(session.lastActivity) <= notificationRecencyWindow
    }

    private static func isCodexCompletionSourcePhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .processing, .waitingForInput, .waitingForApproval:
            return true
        case .idle, .ended, .compacting:
            return false
        }
    }

    private static func wasTrackedOrRecentlyCreated(
        _ session: SessionState,
        previousPhase: SessionPhase?,
        now: Date
    ) -> Bool {
        guard hasRecentNotificationActivity(session, now: now) else {
            return false
        }

        if previousPhase != nil {
            return true
        }

        return now.timeIntervalSince(session.createdAt) <= notificationRecencyWindow
    }
}

struct SessionCompletionNotificationView: View {
    static let minimumContentHeight: CGFloat = 172
    static let maximumAssistantContentHeight: CGFloat = 300
    static let bubbleAssistantLineLimit = 9

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
        let text = SessionCompletionPreviewBuilder.latestUserText(for: session)
        if session.provider == .codex, session.ingress == .remoteBridge {
            return text
        }
        return text ?? session.titleOnlySubagentDisplayTitle
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
            .lineLimit(assistantLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        } else {
            Text(appLocalized: notification.kind.fallbackAssistantMessageKey)
                .font(.system(size: bodyFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(assistantLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        }
    }

    private var assistantLineLimit: Int? {
        switch presentationStyle {
        case .panel:
            return nil
        case .bubble:
            return Self.bubbleAssistantLineLimit
        }
    }

    @ViewBuilder
    private var assistantMessageView: some View {
        switch presentationStyle {
        case .panel:
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
        case .bubble:
            assistantContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var assistantSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(assistantLabelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(assistantPrefixColor)

            assistantMessageView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var containerCornerRadius: CGFloat { 16 }

    @ViewBuilder
    private var contentCard: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let userText {
                    Text(appLocalized: "你：")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))

                    Text(userText)
                        .font(.system(size: bodyFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

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
