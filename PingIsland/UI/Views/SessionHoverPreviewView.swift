import SwiftUI

enum HoverPreviewDensity: Equatable {
    case regular
    case detachedCompact

    var containerSpacing: CGFloat {
        switch self {
        case .regular: 18
        case .detachedCompact: 12
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: 16
        case .detachedCompact: 12
        }
    }

    var topPadding: CGFloat {
        switch self {
        case .regular: 12
        case .detachedCompact: 10
        }
    }

    var bottomPadding: CGFloat {
        switch self {
        case .regular: 18
        case .detachedCompact: 12
        }
    }

    var itemHorizontalPadding: CGFloat {
        switch self {
        case .regular: 14
        case .detachedCompact: 12
        }
    }

    var itemVerticalPadding: CGFloat {
        switch self {
        case .regular: 12
        case .detachedCompact: 10
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .regular: 12
        case .detachedCompact: 10
        }
    }

    var rowDetailSpacing: CGFloat {
        switch self {
        case .regular: 6
        case .detachedCompact: 4
        }
    }

    var badgeSpacing: CGFloat {
        switch self {
        case .regular: 8
        case .detachedCompact: 6
        }
    }

    var badgeHorizontalPadding: CGFloat {
        switch self {
        case .regular: 8
        case .detachedCompact: 7
        }
    }

    var badgeVerticalPadding: CGFloat {
        switch self {
        case .regular: 4
        case .detachedCompact: 3
        }
    }

    var badgeFontSize: CGFloat {
        switch self {
        case .regular: 9
        case .detachedCompact: 8
        }
    }

    var remoteBadgeSize: CGFloat {
        switch self {
        case .regular: 20
        case .detachedCompact: 18
        }
    }
}

struct SessionHoverDashboardView: View {
    let sessions: [SessionState]
    let sessionMonitor: SessionMonitor
    var density: HoverPreviewDensity = .regular
    var suppressInAppPromptControls = false
    var onQuestionInteractionStateChanged: (Bool) -> Void = { _ in }

    private var displayedSessions: [SessionState] {
        Array(sessions.prefix(3))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: density.containerSpacing) {
                if displayedSessions.isEmpty {
                    HoverEmptyPreviewView(density: density)
                }

                ForEach(displayedSessions) { session in
                    let isHighlighted = session.needsApprovalResponse || session.needsQuestionResponse
                    if isHighlighted {
                        HoverSessionCard(
                            session: session,
                            sessionMonitor: sessionMonitor,
                            opensOnTap: false,
                            isHighlighted: isHighlighted,
                            density: density,
                            suppressInAppPromptControls: suppressInAppPromptControls,
                            onQuestionInteractionStateChanged: onQuestionInteractionStateChanged
                        )
                    } else {
                        SessionHoverCompactRow(
                            session: session,
                            isHighlighted: isHighlighted,
                            density: density
                        ) {
                            guard !session.clientInfo.suppressesActivationNavigation else { return }
                            Task {
                                _ = await SessionLauncher.shared.activate(session)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, density.horizontalPadding)
            .padding(.top, density.topPadding)
            .padding(.bottom, density.bottomPadding)
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
}

struct SessionAttentionNotificationView: View {
    let session: SessionState
    let sessionMonitor: SessionMonitor
    var density: HoverPreviewDensity = .regular
    var suppressInAppPromptControls = false
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onQuestionInteractionStateChanged: (Bool) -> Void = { _ in }
    var onActionCompleted: () -> Void = {}

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: density.containerSpacing) {
                HoverSessionCard(
                    session: session,
                    sessionMonitor: sessionMonitor,
                    opensOnTap: false,
                    isHighlighted: session.needsPromptNotification,
                    density: density,
                    suppressInAppPromptControls: suppressInAppPromptControls,
                    onQuestionInteractionStateChanged: onQuestionInteractionStateChanged,
                    onActionCompleted: onActionCompleted
                )
            }
            .padding(.horizontal, density.horizontalPadding)
            .padding(.top, density.topPadding)
            .padding(.bottom, density.bottomPadding)
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
        .onHover(perform: onHoverChanged)
    }
}

struct SessionHoverPreviewView: View {
    let session: SessionState
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HoverSessionHeader(session: session)

            HoverSessionPreviewLines(session: session)

            if !session.shouldHideProjectContextInUI,
               !session.cwd.isEmpty,
               session.cwd != "/" {
                Text(session.cwd)
                    .font(.system(size: max(11, settings.contentFontSize - 2), weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.36))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverConversationSnapshot {
    let userText: String?
    let assistantText: String?
}

private struct SessionHoverCompactRow: View {
    let session: SessionState
    var isHighlighted = false
    var density: HoverPreviewDensity = .regular
    let onOpen: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovered = false

    private var usesTitleOnlySubagentPresentation: Bool {
        session.usesTitleOnlySubagentPresentation
    }

    var body: some View {
        Group {
            if session.clientInfo.suppressesActivationNavigation {
                cardContent
            } else {
                Button(action: onOpen) {
                    cardContent
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var cardContent: some View {
        rowContent
            .padding(.horizontal, density.itemHorizontalPadding)
            .padding(.vertical, density.itemVerticalPadding)
            .background(
                HoverPreviewRowBackground(
                    accentColor: HoverPreviewStyle.emphasisColor(for: session),
                    isHighlighted: isHighlighted,
                    isHovered: isHovered,
                    density: density
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: density == .detachedCompact ? 18 : 20, style: .continuous))
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: density.rowSpacing) {
            HoverProviderGlyph(session: session)

            VStack(alignment: .leading, spacing: density.rowDetailSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: density.badgeSpacing) {
                    if !usesTitleOnlySubagentPresentation && !session.shouldHideProjectContextInUI {
                        Text(session.projectName)
                            .font(.system(size: max(12, settings.contentFontSize), weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))

                        Text("·")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.36))
                    }

                    Text(usesTitleOnlySubagentPresentation ? session.titleOnlySubagentDisplayTitle : session.displayTitle)
                        .font(.system(size: max(14, settings.contentFontSize + 2), weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                if !usesTitleOnlySubagentPresentation {
                    HoverSessionPreviewLines(session: session, compact: true)
                }
            }

            Spacer(minLength: 0)

            if usesTitleOnlySubagentPresentation {
                HoverSubagentBadges(session: session, density: density)
            } else {
                HoverSessionBadges(session: session, density: density)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HoverSessionCard: View {
    let session: SessionState
    let sessionMonitor: SessionMonitor
    var opensOnTap: Bool = true
    var isHighlighted = false
    var density: HoverPreviewDensity = .regular
    var suppressInAppPromptControls = false
    var onQuestionInteractionStateChanged: (Bool) -> Void = { _ in }
    var onActionCompleted: () -> Void = {}
    @State private var isHovered = false

    private var snapshot: HoverConversationSnapshot {
        HoverConversationSnapshotBuilder.snapshot(for: session)
    }

    private var shouldSuppressPromptControls: Bool {
        session.shouldSuppressInAppPromptControls(
            routePromptsToTerminal: suppressInAppPromptControls
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.needsApprovalResponse {
                HoverSessionHeader(session: session)

                HoverApprovalCard(
                    session: session,
                    sessionMonitor: sessionMonitor,
                    suppressControls: shouldSuppressPromptControls,
                    onActionCompleted: onActionCompleted
                )
            } else if let intervention = session.intervention, intervention.kind == .question {
                HoverSessionHeader(session: session)

                HoverQuestionInterventionCard(
                    session: session,
                    intervention: intervention,
                    sessionMonitor: sessionMonitor,
                    suppressControls: shouldSuppressPromptControls,
                    onQuestionInteractionStateChanged: onQuestionInteractionStateChanged,
                    onActionCompleted: onActionCompleted
                )
            } else {
                HoverSessionHeader(session: session)

                HoverConversationCard(session: session, snapshot: snapshot)
            }
        }
        .padding(.horizontal, density.itemHorizontalPadding)
        .padding(.vertical, density.itemVerticalPadding)
        .background(
            HoverPreviewRowBackground(
                accentColor: HoverPreviewStyle.emphasisColor(for: session),
                isHighlighted: isHighlighted,
                isHovered: isHovered,
                density: density
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: density == .detachedCompact ? 18 : 20, style: .continuous))
        .onTapGesture {
            guard opensOnTap else { return }
            activateSession()
        }
        .onHover { isHovered = $0 }
    }

    private func activateSession() {
        guard !session.clientInfo.suppressesActivationNavigation else { return }
        Task {
            _ = await SessionLauncher.shared.activate(session)
        }
    }
}

private enum HoverSessionLayout {
    static let glyphSize: CGFloat = 26
    static let headerSpacing: CGFloat = 12
    static let headerContentInset: CGFloat = glyphSize + headerSpacing
}

private struct HoverConversationCard: View {
    let session: SessionState
    let snapshot: HoverConversationSnapshot
    var compact = false
    @ObservedObject private var settings = AppSettings.shared

    private var userFontSize: CGFloat {
        compact ? max(11, settings.contentFontSize - 1) : max(12, settings.contentFontSize)
    }

    private var assistantFontSize: CGFloat {
        compact ? max(11, settings.contentFontSize - 2) : max(12, settings.contentFontSize - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if let userText = snapshot.userText {
                HoverConversationLine(
                    label: "你：",
                    labelColor: .white.opacity(0.54),
                    text: userText,
                    textColor: .white.opacity(0.84),
                    fontSize: userFontSize,
                    lineLimit: compact ? 1 : 2
                )
            }

            if let assistantText = snapshot.assistantText {
                HoverConversationLine(
                    label: HoverPreviewStyle.assistantPrefixLabel(for: session) + "：",
                    labelColor: HoverPreviewStyle.assistantPrefixColor(for: session),
                    text: assistantText,
                    textColor: HoverPreviewStyle.assistantTextColor(for: session, compact: false),
                    fontSize: assistantFontSize,
                    lineLimit: compact ? 2 : 3
                )
            } else {
                HoverSessionPreviewLines(session: session, compact: compact)
            }

            if !session.shouldHideProjectContextInUI,
               !session.cwd.isEmpty,
               session.cwd != "/" {
                Text(session.cwd)
                    .font(.system(size: max(10, settings.contentFontSize - 2), weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, compact ? 0 : 16)
        .padding(.top, compact ? 0 : 4)
        .padding(.bottom, compact ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverApprovalCard: View {
    let session: SessionState
    let sessionMonitor: SessionMonitor
    var suppressControls = false
    let onActionCompleted: () -> Void

    private var providerLabel: String {
        session.messageBadgeDisplayName
    }

    private var toolLabel: String {
        guard let toolName = session.pendingToolName else { return AppLocalization.string("当前操作") }
        if session.activePermission != nil {
            return MCPToolFormatter.formatToolName(toolName)
        }
        return toolName
    }

    private var detailText: String {
        if let input = session.pendingToolInput, !input.isEmpty {
            return input
        }
        if let intervention = session.intervention, !intervention.message.isEmpty {
            return intervention.message
        }
        return AppLocalization.string("批准后会继续执行当前会话。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: AppLocalization.format("%@ 请求批准", providerLabel))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Text(toolLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TerminalColors.amber.opacity(0.95))

                Text(detailText)
                    .font(.system(size: 11, weight: .medium, design: session.pendingToolInput == nil ? .default : .monospaced))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if suppressControls {
                HoverTerminalRoutedPromptNotice(session: session)
            } else {
                HStack(spacing: 8) {
                    Button(AppLocalization.string("Deny")) {
                        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
                        onActionCompleted()
                    }
                    .buttonStyle(HoverApprovalButtonStyle(background: Color.white.opacity(0.1)))

                    if let sessionAction = session.scopedApprovalAction {
                        Button(AppLocalization.string(sessionAction.buttonTitleKey)) {
                            sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
                            onActionCompleted()
                        }
                        .buttonStyle(
                            HoverApprovalButtonStyle(
                                background: TerminalColors.blue.opacity(0.26),
                                foreground: .white.opacity(0.95)
                            )
                        )
                    }

                    Button(AppLocalization.string("Allow")) {
                        sessionMonitor.approvePermission(sessionId: session.sessionId)
                        onActionCompleted()
                    }
                    .buttonStyle(HoverApprovalButtonStyle(background: Color.white.opacity(0.92), foreground: .black))
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverQuestionInterventionCard: View {
    let session: SessionState
    let intervention: SessionIntervention
    let sessionMonitor: SessionMonitor
    var suppressControls = false
    var onQuestionInteractionStateChanged: (Bool) -> Void = { _ in }
    let onActionCompleted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(intervention.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(intervention.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer(minLength: 0)
            }

            if suppressControls {
                HoverTerminalRoutedPromptNotice(session: session)
            } else if intervention.awaitsExternalContinuation,
               session.clientInfo.prefersAnsweredQuestionFollowupAction {
                VStack(alignment: .leading, spacing: 10) {
                    SessionQuestionForm(
                        intervention: intervention,
                        initialAnswers: intervention.submittedAnswers,
                        onSubmit: { _ in },
                        onInteractionStateChanged: onQuestionInteractionStateChanged,
                        secondaryActionTitle: AppLocalization.format("打开 %@", session.interactionDisplayName),
                        onSecondaryAction: {
                            Task {
                                _ = await SessionLauncher.shared.activateClientApplication(session)
                            }
                        },
                        isEditable: false
                    )

                    if let statusMessage = intervention.externalContinuationStatusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if intervention.metadata["responseMode"] == "external_only" {
                Button {
                    Task {
                        _ = await SessionLauncher.shared.activate(session)
                    }
                }
                label: {
                    Text(verbatim: AppLocalization.format("打开 %@", session.interactionDisplayName))
                }
                .buttonStyle(HoverApprovalButtonStyle(background: Color.white.opacity(0.9), foreground: .black))
            } else if intervention.supportsInlineResponse {
                let secondaryActionTitle: String? = if session.clientInfo.prefersAnsweredQuestionFollowupAction {
                    AppLocalization.format("打开 %@", session.interactionDisplayName)
                } else {
                    nil
                }

                SessionQuestionForm(
                    intervention: intervention,
                    submitLabel: "提交所有回答",
                    initialDraft: sessionMonitor.questionDraft(
                        sessionId: session.sessionId,
                        interventionId: intervention.id
                    ),
                    onSubmit: { payload in
                        sessionMonitor.answerIntervention(sessionId: session.sessionId, answers: payload)
                        onActionCompleted()
                    },
                    onInteractionStateChanged: onQuestionInteractionStateChanged,
                    onDraftChanged: { draft in
                        sessionMonitor.updateQuestionDraft(
                            sessionId: session.sessionId,
                            interventionId: intervention.id,
                            draft: draft
                        )
                    },
                    onDraftCleared: {
                        sessionMonitor.clearQuestionDraft(
                            sessionId: session.sessionId,
                            interventionId: intervention.id
                        )
                    },
                    secondaryActionTitle: secondaryActionTitle,
                    onSecondaryAction: secondaryActionTitle == nil ? nil : {
                        Task {
                            _ = await SessionLauncher.shared.activateClientApplication(session)
                        }
                    }
                )
            } else {
                Button {
                    Task {
                        _ = await SessionLauncher.shared.activateClientApplication(session)
                    }
                }
                label: {
                    Text(verbatim: AppLocalization.format("打开 %@ 回答", session.interactionDisplayName))
                }
                .buttonStyle(HoverApprovalButtonStyle(background: Color.white.opacity(0.9), foreground: .black))
            }
        }
        .padding(.top, 12)
        .padding(.bottom, intervention.metadata["responseMode"] == "external_only" ? 12 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverTerminalRoutedPromptNotice: View {
    let session: SessionState

    var body: some View {
        Text(verbatim: AppLocalization.format(
            "已保留在%@中处理。Ping Island 只提醒，不接管此处响应。",
            session.isInTmux ? AppLocalization.string("终端") : session.interactionDisplayName
        ))
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.64))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoverApprovalButtonStyle: ButtonStyle {
    let background: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(foreground.opacity(configuration.isPressed ? 0.75 : 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(background.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

private struct HoverSessionHeader: View {
    let session: SessionState
    var showPath: Bool = false
    @ObservedObject private var settings = AppSettings.shared

    private var usesCodexSubagentTitleOnlyPresentation: Bool {
        session.usesTitleOnlySubagentPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showPath ? 8 : 0) {
            HStack(alignment: .center, spacing: HoverSessionLayout.headerSpacing) {
                HoverProviderGlyph(session: session)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !usesCodexSubagentTitleOnlyPresentation && !session.shouldHideProjectContextInUI {
                            Text(session.projectName)
                                .font(.system(size: max(13, settings.contentFontSize), weight: .semibold))
                                .foregroundColor(.white.opacity(0.88))

                            Text("·")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.42))
                        }

                        Text(usesCodexSubagentTitleOnlyPresentation ? session.titleOnlySubagentDisplayTitle : session.displayTitle)
                            .font(.system(size: max(15, settings.contentFontSize + 3), weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }

                    if usesCodexSubagentTitleOnlyPresentation {
                        HoverSubagentBadges(session: session)
                    } else {
                        HoverSessionBadges(session: session)
                    }
                }

                Spacer(minLength: 0)
            }

            if showPath,
               !usesCodexSubagentTitleOnlyPresentation,
               !session.shouldHideProjectContextInUI,
               !session.cwd.isEmpty,
               session.cwd != "/" {
                Text(session.cwd)
                    .font(.system(size: max(11, settings.contentFontSize - 2), weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.36))
                    .lineLimit(1)
            }
        }
    }
}

private struct HoverSessionPreviewLines: View {
    let session: SessionState
    var compact = false
    @ObservedObject private var settings = AppSettings.shared

    private var lines: [HoverPreviewLine] {
        if session.shouldUseMinimalCompactPresentation || session.usesTitleOnlySubagentPresentation {
            return []
        }
        return HoverPreviewLineBuilder.previewLines(
            for: session,
            compact: compact,
            detailsEnabled: settings.showAgentDetail
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let prefix = line.prefix {
                        Text(prefix)
                            .font(.system(size: compact ? max(10, settings.contentFontSize - 2) : max(11, settings.contentFontSize - 1), weight: .semibold))
                            .foregroundColor(line.prefixColor)
                    }

                    Text(line.text)
                        .font(.system(size: compact ? max(10, settings.contentFontSize - 2) : max(11, settings.contentFontSize - 1), weight: .medium))
                        .foregroundColor(line.color)
                        .lineLimit(compact ? 1 : 2)
                }
            }
        }
    }
}

private struct HoverSessionBadges: View {
    let session: SessionState
    var density: HoverPreviewDensity = .regular

    private var timeLabel: String {
        SessionPhaseHelpers.timeBadgeLabel(for: session.lastActivity)
    }

    var body: some View {
        HStack(spacing: density.badgeSpacing) {
            previewBadge(
                timeLabel,
                tint: .white.opacity(0.08),
                foreground: .white.opacity(0.72),
                fontDesign: .monospaced
            )
            previewBadge(
                HoverPreviewStyle.providerLabel(for: session),
                tint: HoverPreviewStyle.providerBadgeFill(for: session),
                foreground: .white.opacity(0.95)
            )
            if let primarySupplementaryBadge {
                supplementaryBadgeView(primarySupplementaryBadge)
            }
        }
    }

    private enum SupplementaryBadge {
        case text(String, tint: Color, foreground: Color, fontDesign: Font.Design)
        case remote
    }

    private var primarySupplementaryBadge: SupplementaryBadge? {
        if let codexSubagentBadgeText = session.codexSubagentBadgeText {
            return .text(
                codexSubagentBadgeText,
                tint: .white.opacity(0.12),
                foreground: .white.opacity(0.92),
                fontDesign: .monospaced
            )
        }
        if session.isRemoteSession {
            return .remote
        }
        if let ideHostBadgeLabel = session.ideHostBadgeLabel {
            return .text(
                ideHostBadgeLabel,
                tint: HoverPreviewStyle.ideHostBadgeFill(for: session),
                foreground: .white.opacity(0.92),
                fontDesign: .default
            )
        }
        if let terminalSourceBadgeLabel = session.terminalSourceBadgeLabel {
            return .text(
                terminalSourceBadgeLabel,
                tint: .white.opacity(0.08),
                foreground: .white.opacity(0.9),
                fontDesign: .default
            )
        }
        return nil
    }

    private func previewBadge(
        _ text: String,
        tint: Color,
        foreground: Color = .white.opacity(0.92),
        fontDesign: Font.Design = .default
    ) -> some View {
        Text(text)
            .font(.system(size: density.badgeFontSize, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, density.badgeHorizontalPadding)
            .padding(.vertical, density.badgeVerticalPadding)
            .background(tint)
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private func remoteSessionBadge() -> some View {
        Image(systemName: "cloud.fill")
            .font(.system(size: density.badgeFontSize, weight: .semibold))
            .foregroundColor(.white.opacity(0.92))
            .frame(width: density.remoteBadgeSize, height: density.remoteBadgeSize)
            .background(Color(red: 0.42, green: 0.70, blue: 0.98).opacity(0.26))
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(Circle())
            .help(AppLocalization.string("远程连接"))
    }

    @ViewBuilder
    private func supplementaryBadgeView(_ badge: SupplementaryBadge) -> some View {
        switch badge {
        case .text(let text, let tint, let foreground, let fontDesign):
            previewBadge(
                text,
                tint: tint,
                foreground: foreground,
                fontDesign: fontDesign
            )
        case .remote:
            remoteSessionBadge()
        }
    }
}

private struct HoverSubagentBadges: View {
    let session: SessionState
    var density: HoverPreviewDensity = .regular

    var body: some View {
        HStack(spacing: density.badgeSpacing) {
            if let subagentClientTypeBadgeText = session.subagentClientTypeBadgeText {
                previewBadge(
                    subagentClientTypeBadgeText,
                    tint: HoverPreviewStyle.providerBadgeFill(for: session),
                    foreground: .white.opacity(0.95)
                )
            }

            if let codexSubagentBadgeText = session.codexSubagentBadgeText {
                previewBadge(
                    codexSubagentBadgeText,
                    tint: .white.opacity(0.12),
                    foreground: .white.opacity(0.92),
                    fontDesign: .monospaced
                )
            }
        }
    }

    private func previewBadge(
        _ text: String,
        tint: Color,
        foreground: Color = .white.opacity(0.92),
        fontDesign: Font.Design = .default
    ) -> some View {
        Text(text)
            .font(.system(size: density.badgeFontSize, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, density.badgeHorizontalPadding)
            .padding(.vertical, density.badgeVerticalPadding)
            .background(tint)
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}

private struct HoverProviderGlyph: View {
    let session: SessionState
    @ObservedObject private var settings = AppSettings.shared

    private var attentionTone: NotchIndicatorTone? {
        if session.needsQuestionResponse {
            return .intervention
        }
        if session.needsApprovalResponse {
            return .warning
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MascotView(
                kind: settings.mascotKind(for: session.mascotClient),
                status: MascotStatus(session: session),
                size: 18,
                animationTime: 0
            )
            .frame(width: HoverSessionLayout.glyphSize, height: HoverSessionLayout.glyphSize)
            .background(attentionTone == nil ? Color.white.opacity(0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let attentionTone {
                PermissionIndicatorIcon(size: 11, color: attentionTone.emphasisColor)
                    .offset(x: 2, y: -2)
            }
        }
    }
}

private struct HoverPreviewLine: Identifiable {
    let id: String
    let prefix: String?
    let prefixColor: Color
    let text: String
    let color: Color
}

private struct HoverConversationLine: View {
    let label: String
    let labelColor: Color
    let text: String
    let textColor: Color
    let fontSize: CGFloat
    let lineLimit: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: max(11, fontSize - 1), weight: .semibold))
                .foregroundColor(labelColor)

            MarkdownText(text, color: textColor, fontSize: fontSize)
                .lineLimit(lineLimit)
        }
    }
}

private struct HoverPreviewRowBackground: View {
    let accentColor: Color
    let isHighlighted: Bool
    let isHovered: Bool
    let density: HoverPreviewDensity

    private var cornerRadius: CGFloat {
        density == .detachedCompact ? 18 : 20
    }

    private var fillColor: Color {
        if isHighlighted {
            return accentColor.opacity(isHovered ? 0.24 : 0.18)
        }
        if isHovered {
            return Color.white.opacity(0.08)
        }
        return Color.white.opacity(0.04)
    }

    private var borderColor: Color {
        if isHighlighted {
            return accentColor.opacity(isHovered ? 0.34 : 0.26)
        }
        if isHovered {
            return Color.white.opacity(0.12)
        }
        return Color.white.opacity(0.05)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

private enum HoverPreviewStyle {
    static func providerLabel(for session: SessionState) -> String {
        session.messageBadgeDisplayName
    }

    static func assistantPrefixLabel(for session: SessionState) -> String {
        if session.needsApprovalResponse {
            return session.messageBadgeDisplayName
        }
        if session.needsQuestionResponse {
            return session.interactionDisplayName
        }
        return session.providerDisplayName
    }

    static func previewAssistantPrefix(for session: SessionState) -> String? {
        let badgeLabel = providerLabel(for: session).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLabel = assistantPrefixLabel(for: session).trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixLabel.isEmpty, prefixLabel.caseInsensitiveCompare(badgeLabel) == .orderedSame {
            return nil
        }
        return prefixLabel.isEmpty ? nil : prefixLabel + "："
    }

    static func providerColor(for session: SessionState) -> Color {
        session.clientTintColor
    }

    static func providerBadgeFill(for session: SessionState) -> Color {
        providerColor(for: session).opacity(session.clientInfo.brand == .qoder || session.provider == .claude ? 0.26 : 0.22)
    }

    static func ideHostBadgeFill(for session: SessionState) -> Color {
        if session.ideHostBadgeLabel?.contains("Qoder") == true {
            return TerminalColors.qoder.opacity(0.24)
        }
        return .white.opacity(0.08)
    }

    static func emphasisColor(for session: SessionState) -> Color {
        if session.needsQuestionResponse {
            return TerminalColors.blue
        }
        if session.needsApprovalResponse {
            return TerminalColors.amber
        }
        return providerColor(for: session)
    }

    static func assistantPrefixColor(for session: SessionState) -> Color {
        return providerColor(for: session).opacity(session.phase.isActive ? 0.96 : 0.9)
    }

    static func assistantTextColor(for session: SessionState, compact: Bool) -> Color {
        if session.needsQuestionResponse {
            return .white.opacity(compact ? 0.82 : 0.88)
        }
        if session.needsApprovalResponse {
            return .white.opacity(compact ? 0.74 : 0.8)
        }
        if session.phase.isActive {
            return .white.opacity(compact ? 0.68 : 0.78)
        }
        return .white.opacity(compact ? 0.58 : 0.68)
    }
}

@MainActor
private enum HoverPreviewLineBuilder {
    static func previewLines(for session: SessionState, compact: Bool, detailsEnabled: Bool) -> [HoverPreviewLine] {
        var lines: [HoverPreviewLine] = []

        if let userLine = latestUserLine(for: session) {
            lines.append(
                HoverPreviewLine(
                    id: "user",
                    prefix: AppLocalization.string("你："),
                    prefixColor: .white.opacity(compact ? 0.44 : 0.52),
                    text: userLine,
                    color: .white.opacity(compact ? 0.68 : 0.76)
                )
            )
        }

        if let assistantLine = latestAssistantLine(for: session, detailsEnabled: detailsEnabled) {
            lines.append(
                HoverPreviewLine(
                    id: "assistant",
                    prefix: HoverPreviewStyle.previewAssistantPrefix(for: session),
                    prefixColor: HoverPreviewStyle.assistantPrefixColor(for: session),
                    text: assistantLine,
                    color: HoverPreviewStyle.assistantTextColor(for: session, compact: compact)
                )
            )
        }

        if lines.isEmpty, let fallback = fallbackPreview(for: session) {
            lines.append(
                HoverPreviewLine(
                    id: "fallback",
                    prefix: nil,
                    prefixColor: .clear,
                    text: fallback,
                    color: .white.opacity(0.64)
                )
            )
        }

        return Array(lines.prefix(compact ? 2 : 3))
    }

    private static func latestUserLine(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    private static func latestAssistantLine(for session: SessionState, detailsEnabled: Bool) -> String? {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                return session.codexSubagentSummaryText(for: sanitized(text))
            case .thinking(let text):
                return detailsEnabled ? session.codexSubagentSummaryText(for: sanitized(text)) : nil
            case .toolCall(let tool):
                guard detailsEnabled else { continue }
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                return session.codexSubagentSummaryText(for: preview.map { "\(label) \($0)" } ?? label)
            case .interrupted, .user:
                continue
            }
        }

        if let intervention = session.intervention {
            return session.codexSubagentSummaryText(for: sanitized(intervention.summaryText))
        }

        return session.codexSubagentSummaryText(for: sanitized(session.lastMessage))
    }

    private static func fallbackPreview(for session: SessionState) -> String? {
        session.codexSubagentSummaryText(for: sanitized(session.previewText) ?? sanitized(session.lastMessage))
    }

    private static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? nil : collapsed
    }
}

@MainActor
private enum HoverConversationSnapshotBuilder {
    static func snapshot(for session: SessionState) -> HoverConversationSnapshot {
        let snapshot = SessionConversationPreviewBuilder.snapshot(for: session)
        return HoverConversationSnapshot(
            userText: snapshot.userText,
            assistantText: snapshot.assistantText
        )
    }
}

struct HoverEmptyPreviewView: View {
    var density: HoverPreviewDensity = .regular

    @ObservedObject private var settings = AppSettings.shared

    private var visibleShortcutActions: [(GlobalShortcutAction, GlobalShortcut)] {
        let actions: [GlobalShortcutAction] = [.openActiveSession, .openSessionList]
        return actions.compactMap { action in
            guard let shortcut = settings.shortcut(for: action) else { return nil }
            return (action, shortcut)
        }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    TerminalColors.green.opacity(0.16),
                    Color.clear
                ],
                center: .center,
                startRadius: 18,
                endRadius: density == .detachedCompact ? 120 : 210
            )
            .allowsHitTesting(false)

            VStack(alignment: .center, spacing: density == .detachedCompact ? 10 : 14) {
                VStack(alignment: .center, spacing: density == .detachedCompact ? 6 : 9) {
                    Text(appLocalized: "No active session")
                        .font(.system(size: density == .detachedCompact ? 17 : 24, weight: .heavy))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.30), radius: 6, y: 3)

                    Text(appLocalized: "Hover to preview active sessions. Click the Island to open the session list.")
                        .font(.system(size: density == .detachedCompact ? 10 : 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                interactionHints

                if !visibleShortcutActions.isEmpty {
                    VStack(alignment: .center, spacing: density == .detachedCompact ? 6 : 8) {
                        HoverEmptySectionDivider(title: "快捷键")
                        shortcutHints
                    }
                }

                HoverEmptyFooterNote()
            }
            .padding(.horizontal, density == .detachedCompact ? 8 : 14)
            .padding(.vertical, density == .detachedCompact ? 10 : 16)
        }
        .frame(maxWidth: .infinity, minHeight: density == .detachedCompact ? 190 : 260, alignment: .center)
    }

    @ViewBuilder
    private var interactionHints: some View {
        if density == .detachedCompact {
            VStack(alignment: .center, spacing: 6) {
                HoverEmptyInteractionHint(
                    icon: "cursorarrow",
                    label: "Hover",
                    title: "快速预览当前会话",
                    density: density
                )
                HoverEmptyInteractionHint(
                    icon: "cursorarrow.rays",
                    label: "Click",
                    title: "展开全部会话列表",
                    density: density
                )
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                HoverEmptyInteractionHint(
                    icon: "cursorarrow",
                    label: "Hover",
                    title: "快速预览当前会话",
                    density: density
                )
                HoverEmptyInteractionHint(
                    icon: "cursorarrow.rays",
                    label: "Click",
                    title: "展开全部会话列表",
                    density: density
                )
            }
        }
    }

    @ViewBuilder
    private var shortcutHints: some View {
        if density == .detachedCompact {
            VStack(alignment: .center, spacing: 6) {
                shortcutHintRows
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                shortcutHintRows
            }
        }
    }

    @ViewBuilder
    private var shortcutHintRows: some View {
        ForEach(visibleShortcutActions, id: \.0.id) { action, shortcut in
            HoverEmptyShortcutHint(action: action, shortcut: shortcut, density: density)
        }
    }
}

private struct HoverEmptyInteractionHint: View {
    let icon: String
    let label: String
    let title: String
    var density: HoverPreviewDensity = .regular

    private var iconCircleSize: CGFloat {
        density == .detachedCompact ? 28 : 38
    }

    var body: some View {
        HStack(spacing: density == .detachedCompact ? 7 : 9) {
            ZStack {
                Circle()
                    .fill(TerminalColors.green.opacity(0.10))
                    .overlay(
                        Circle()
                            .strokeBorder(TerminalColors.green.opacity(0.26), lineWidth: 1)
                    )
                    .shadow(color: TerminalColors.green.opacity(0.20), radius: 18)

                Image(systemName: icon)
                    .font(.system(size: density == .detachedCompact ? 12 : 16, weight: .bold))
                    .foregroundStyle(TerminalColors.green)
            }
            .frame(width: iconCircleSize, height: iconCircleSize)

            VStack(alignment: .leading, spacing: density == .detachedCompact ? 2 : 3) {
                Text(appLocalized: label)
                    .font(.system(size: density == .detachedCompact ? 11 : 13, weight: .bold))
                    .foregroundColor(TerminalColors.green)

                Text(appLocalized: title)
                    .font(.system(size: density == .detachedCompact ? 10 : 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, density == .detachedCompact ? 8 : 10)
        .padding(.vertical, density == .detachedCompact ? 6 : 8)
        .frame(maxWidth: .infinity, minHeight: density == .detachedCompact ? 40 : 52)
        .background(HoverEmptyGlassCardBackground(cornerRadius: 12, borderOpacity: 0.12))
    }
}

private struct HoverEmptyShortcutHint: View {
    let action: GlobalShortcutAction
    let shortcut: GlobalShortcut
    var density: HoverPreviewDensity = .regular

    var body: some View {
        HStack(spacing: density == .detachedCompact ? 6 : 8) {
            Image(systemName: iconName)
                .font(.system(size: density == .detachedCompact ? 10 : 12, weight: .bold))
                .foregroundColor(TerminalColors.green)
                .frame(width: density == .detachedCompact ? 14 : 16)

            Text(appLocalized: action.shortTitle)
                .font(.system(size: density == .detachedCompact ? 10 : 12, weight: .bold))
                .foregroundColor(.white.opacity(0.9))

            Spacer(minLength: 6)

            ShortcutVisualLabel(
                shortcut: shortcut,
                fontSize: density == .detachedCompact ? 9 : 10,
                foregroundColor: TerminalColors.green.opacity(0.95),
                keyBackground: TerminalColors.green.opacity(0.12),
                keyBorder: TerminalColors.green.opacity(0.28),
                keyMinWidth: density == .detachedCompact ? 16 : 18,
                keyHorizontalPadding: density == .detachedCompact ? 4 : 5,
                keyVerticalPadding: density == .detachedCompact ? 2 : 3,
                keyCornerRadius: 7
            )
        }
        .padding(.horizontal, density == .detachedCompact ? 8 : 10)
        .padding(.vertical, density == .detachedCompact ? 5 : 7)
        .frame(maxWidth: .infinity, minHeight: density == .detachedCompact ? 32 : 38)
        .background(HoverEmptyGlassCardBackground(cornerRadius: 11, borderOpacity: 0.24))
    }

    private var iconName: String {
        switch action {
        case .openActiveSession:
            return "bolt.fill"
        case .openSessionList:
            return "list.bullet"
        }
    }
}

private struct HoverEmptySectionDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            HoverEmptyDividerLine()
            Circle()
                .fill(TerminalColors.green.opacity(0.5))
                .frame(width: 2.5, height: 2.5)
            Text(appLocalized: title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(TerminalColors.green)
            Circle()
                .fill(TerminalColors.green.opacity(0.5))
                .frame(width: 2.5, height: 2.5)
            HoverEmptyDividerLine()
        }
    }
}

private struct HoverEmptyFooterNote: View {
    var body: some View {
        HStack(spacing: 6) {
            HoverEmptyDividerLine()
            Image(systemName: "lightbulb")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.green.opacity(0.86))
            Text(appLocalized: "新会话会显示在这里")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            HoverEmptyDividerLine()
        }
    }
}

private struct HoverEmptyDividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 1)
    }
}

private struct HoverEmptyGlassCardBackground: View {
    let cornerRadius: CGFloat
    let borderOpacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(borderOpacity),
                                TerminalColors.green.opacity(borderOpacity),
                                Color.white.opacity(borderOpacity * 0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: TerminalColors.green.opacity(0.10), radius: 18, y: 8)
    }
}
