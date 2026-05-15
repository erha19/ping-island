//
//  ChatView.swift
//  PingIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI
import os.log

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var displayedHistory: [ChatHistoryItem] = []
    @State private var latestUserMessageId: String = ""
    @State private var historyRevision: Int = 0
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, initialSession: SessionState, sessionMonitor: SessionMonitor, viewModel: NotchViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._displayedHistory = State(initialValue: cachedHistory.reversedForChatDisplay())
        self._latestUserMessageId = State(initialValue: cachedHistory.latestUserMessageId)
        self._historyRevision = State(initialValue: ChatHistoryManager.shared.revision(for: sessionId))
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    private var activeQuestionIntervention: SessionIntervention? {
        guard session.intervention?.kind == .question else { return nil }
        return session.intervention
    }

    private var shouldShowCompletedFollowupPrompt: Bool {
        guard session.phase != .ended else { return false }
        guard session.clientInfo.prefersAnsweredQuestionFollowupAction else { return false }
        guard let latestTool = displayedHistory.compactMap({ item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool
        }).first else { return false }

        let normalizedName = latestTool.name
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        let isRelevantStatus = latestTool.status == .success || latestTool.status == .running
        return normalizedName == "askfollowupquestion" && isRelevantStatus
    }

    /// When an external client like Qoder is waiting for input, top-align sparse
    /// history so the reminder area doesn't leave a large empty gap above it.
    private var shouldTopAlignMessages: Bool {
        activeQuestionIntervention != nil
    }

    /// Initial AskUserQuestion popups usually have only a few history rows.
    /// Cap the transcript region so the panel hugs the content instead of
    /// reserving a large empty column above the question form.
    private var compactTranscriptMaxHeight: CGFloat? {
        guard activeQuestionIntervention != nil else { return nil }
        return 300
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                        .frame(maxHeight: compactTranscriptMaxHeight, alignment: .top)
                }

                // Approval bar, question form, or Input bar
                if shouldShowCompletedFollowupPrompt {
                    completedFollowupPromptBar
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else if let intervention = activeQuestionIntervention {
                    questionForm(intervention)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else if let tool = approvalTool {
                    approvalBar(tool: tool)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else if canSendMessages {
                    inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                replaceHistoryWithoutListAnimation(
                    ChatHistoryManager.shared.history(for: sessionId),
                    revision: ChatHistoryManager.shared.revision(for: sessionId)
                )
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            replaceHistoryWithoutListAnimation(
                ChatHistoryManager.shared.history(for: sessionId),
                revision: ChatHistoryManager.shared.revision(for: sessionId)
            )

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let newRevision = ChatHistoryManager.shared.revision(for: sessionId)
                guard newRevision != historyRevision else { return }
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    replaceHistoryWithoutListAnimation(newHistory, revision: newRevision)

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                } else {
                    historyRevision = newRevision
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               !session.matchesChatPresentation(of: updated) {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            syncSessionFromMonitor()

            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.exitChat()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                        .frame(width: 24, height: 24)

                    Text(session.titleOnlySubagentDisplayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }

            Spacer()

            if session.isNativeRuntimeSession, session.phase != .ended {
                Button {
                    sessionMonitor.terminateNativeSession(sessionId: session.sessionId)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Stop native runtime session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    private var assistantAccentColor: Color {
        session.clientTintColor
    }

    private var assistantTextColor: Color {
        .white.opacity(0.9)
    }

    private var processingAccentColor: Color {
        session.clientTintColor
    }

    private var assistantStyleID: String {
        [
            session.provider.rawValue,
            session.clientInfo.brand.rawValue,
            session.clientInfo.profileID ?? "",
            session.clientInfo.name ?? ""
        ].joined(separator: "|")
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ChatTranscriptView(
            items: displayedHistory,
            sessionId: sessionId,
            isProcessing: isProcessing,
            latestUserMessageId: latestUserMessageId,
            assistantStyleID: assistantStyleID,
            assistantAccentColor: assistantAccentColor,
            assistantTextColor: assistantTextColor,
            processingAccentColor: processingAccentColor,
            shouldTopAlignMessages: shouldTopAlignMessages,
            shouldScrollToBottom: $shouldScrollToBottom,
            isAutoscrollPaused: $isAutoscrollPaused,
            newMessageCount: $newMessageCount,
            onResumeAutoscroll: { resumeAutoscroll() },
            onActivateSession: { focusTerminal() }
        )
    }

    // MARK: - Input Bar

    /// Inline follow-up is available for native runtime sessions and terminal-backed tmux sessions.
    private var canSendMessages: Bool {
        session.isNativeRuntimeSession || session.supportsTmuxCLIMessaging
    }

    private var messagePlaceholder: String {
        AppLocalization.format("Message %@...", session.providerDisplayName)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(messagePlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            sessionAction: session.scopedApprovalAction,
            onApprove: { approvePermission() },
            onApproveForSession: { approvePermissionForSession() },
            onDeny: { denyPermission() }
        )
    }

    private var completedFollowupPromptBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    openClientApplication()
                } label: {
                    Text(verbatim: AppLocalization.format("打开 %@", session.interactionDisplayName))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.9)))

                if session.isInTmux {
                    Button {
                        focusTerminal()
                    } label: {
                        Text(appLocalized: "打开终端")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }

            Text(AppLocalization.format("%@ 已在客户端中发起追问，请打开并继续回答。", session.interactionDisplayName))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24)
            .allowsHitTesting(false)
        }
        .zIndex(1)
    }

    // MARK: - Question Form

    private func questionForm(_ intervention: SessionIntervention) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(intervention.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(intervention.message)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if intervention.awaitsExternalContinuation,
               session.clientInfo.prefersAnsweredQuestionFollowupAction {
                VStack(alignment: .leading, spacing: 10) {
                    SessionQuestionForm(
                        intervention: intervention,
                        initialAnswers: intervention.submittedAnswers,
                        onSubmit: { _ in },
                        onInteractionStateChanged: { viewModel.setInlineTextInputActive($0) },
                        secondaryActionTitle: AppLocalization.format("打开 %@", session.interactionDisplayName),
                        onSecondaryAction: { openClientApplication() },
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
                HStack(spacing: 8) {
                    Button {
                        Task {
                            _ = await SessionLauncher.shared.activate(session)
                        }
                    }
                    label: {
                        Text(verbatim: AppLocalization.format("打开 %@", session.interactionDisplayName))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
                }
            } else if intervention.supportsInlineResponse {
                let secondaryActionTitle: String? = if session.clientInfo.prefersAnsweredQuestionFollowupAction {
                    AppLocalization.format("打开 %@", session.interactionDisplayName)
                } else if session.isInTmux {
                    AppLocalization.string("打开终端")
                } else {
                    nil
                }

                let onSecondaryAction: (() -> Void)? = if session.clientInfo.prefersAnsweredQuestionFollowupAction {
                    { openClientApplication() }
                } else if session.isInTmux {
                    { focusTerminal() }
                } else {
                    nil
                }

                SessionQuestionForm(
                    intervention: intervention,
                    submitLabel: "提交所有回答",
                    initialDraft: sessionMonitor.questionDraft(
                        sessionId: sessionId,
                        interventionId: intervention.id
                    ),
                    onSubmit: { payload in
                        sessionMonitor.answerIntervention(sessionId: sessionId, answers: payload)
                    },
                    onInteractionStateChanged: { viewModel.setInlineTextInputActive($0) },
                    onDraftChanged: { draft in
                        sessionMonitor.updateQuestionDraft(
                            sessionId: sessionId,
                            interventionId: intervention.id,
                            draft: draft
                        )
                    },
                    onDraftCleared: {
                        sessionMonitor.clearQuestionDraft(
                            sessionId: sessionId,
                            interventionId: intervention.id
                        )
                    },
                    secondaryActionTitle: secondaryActionTitle,
                    onSecondaryAction: onSecondaryAction
                )
            } else {
                HStack(spacing: 8) {
                    Button {
                        openClientApplication()
                    }
                    label: {
                        Text(verbatim: AppLocalization.format("打开 %@ 回答", session.interactionDisplayName))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.9)))

                    if session.isInTmux {
                        Button {
                            focusTerminal()
                        }
                        label: {
                            Text(appLocalized: "打开终端")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, intervention.metadata["responseMode"] == "external_only" ? 10 : 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24)
            .allowsHitTesting(false)
        }
        .zIndex(1)
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    private func replaceHistoryWithoutListAnimation(_ newHistory: [ChatHistoryItem], revision: Int? = nil) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            history = newHistory
            displayedHistory = newHistory.reversedForChatDisplay()
            latestUserMessageId = newHistory.latestUserMessageId
            if let revision {
                historyRevision = revision
            }
        }
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            _ = await SessionLauncher.shared.activate(session)
        }
    }

    private func openClientApplication() {
        Task {
            _ = await SessionLauncher.shared.activateClientApplication(session)
        }
    }

    private func syncSessionFromMonitor() {
        if let liveSession = sessionMonitor.instances.first(where: { $0.sessionId == sessionId }),
           liveSession != session {
            session = liveSession
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func approvePermissionForSession() {
        sessionMonitor.approvePermission(sessionId: sessionId, forSession: true)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task {
            await sendToSession(text)
        }
    }

    private func sendToSession(_ text: String) async {
        try? await sessionMonitor.sendSessionMessage(
            sessionId: session.sessionId,
            text: text
        )
    }
}

private extension SessionState {
    func matchesChatPresentation(of other: SessionState) -> Bool {
        sessionId == other.sessionId
            && cwd == other.cwd
            && provider == other.provider
            && clientInfo == other.clientInfo
            && ingress == other.ingress
            && titleOnlySubagentDisplayTitle == other.titleOnlySubagentDisplayTitle
            && interactionDisplayName == other.interactionDisplayName
            && phase == other.phase
            && intervention == other.intervention
            && pid == other.pid
            && tty == other.tty
            && isInTmux == other.isInTmux
            && autoApprovePermissions == other.autoApprovePermissions
    }
}

private extension Array where Element == ChatHistoryItem {
    func reversedForChatDisplay() -> [ChatHistoryItem] {
        Array(reversed())
    }

    var latestUserMessageId: String {
        for item in reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }
}

// MARK: - Transcript View

private struct ChatTranscriptView: View {
    let items: [ChatHistoryItem]
    let sessionId: String
    let isProcessing: Bool
    let latestUserMessageId: String
    let assistantStyleID: String
    let assistantAccentColor: Color
    let assistantTextColor: Color
    let processingAccentColor: Color
    let shouldTopAlignMessages: Bool
    @Binding var shouldScrollToBottom: Bool
    @Binding var isAutoscrollPaused: Bool
    @Binding var newMessageCount: Int
    let onResumeAutoscroll: () -> Void
    let onActivateSession: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 16) {
                        // Invisible anchor at bottom (first due to flip)
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")

                        // Processing indicator at bottom (first due to flip)
                        if isProcessing {
                            ProcessingIndicatorView(turnId: latestUserMessageId, color: processingAccentColor)
                                .padding(.horizontal, 16)
                                .scaleEffect(x: 1, y: -1)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                    removal: .opacity
                                ))
                        }

                        ForEach(items) { item in
                            MessageItemView(
                                item: item,
                                sessionId: sessionId,
                                assistantStyleID: assistantStyleID,
                                assistantAccentColor: assistantAccentColor,
                                assistantTextColor: assistantTextColor,
                                onActivateSession: onActivateSession
                            )
                            .equatable()
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                        }
                    }
                    .padding(.top, shouldTopAlignMessages ? 10 : 20)
                    .padding(.bottom, shouldTopAlignMessages ? 12 : 20)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        // The scroll view is vertically flipped below. `.top` keeps sparse
                        // chats visually anchored near the footer, while `.bottom` moves
                        // intervention reminders upward so they don't leave a large blank area.
                        alignment: shouldTopAlignMessages ? .bottom : .top
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                }
                .scaleEffect(x: 1, y: -1)
                .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                    if shouldScroll {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        shouldScrollToBottom = false
                        onResumeAutoscroll()
                    }
                }
                // New messages indicator overlay
                .overlay(alignment: .bottom) {
                    if isAutoscrollPaused && newMessageCount > 0 {
                        NewMessagesIndicator(count: newMessageCount) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            onResumeAutoscroll()
                        }
                        .padding(.bottom, 16)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
            }
        }
    }
}

// MARK: - Message Item View

struct MessageItemView: View, Equatable {
    let item: ChatHistoryItem
    let sessionId: String
    let assistantStyleID: String
    let assistantAccentColor: Color
    let assistantTextColor: Color
    let onActivateSession: () -> Void

    static func == (lhs: MessageItemView, rhs: MessageItemView) -> Bool {
        lhs.item == rhs.item
            && lhs.sessionId == rhs.sessionId
            && lhs.assistantStyleID == rhs.assistantStyleID
    }

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text, onTap: onActivateSession)
        case .assistant(let text):
            AssistantMessageView(
                text: text,
                accentColor: assistantAccentColor,
                textColor: assistantTextColor,
                onTap: onActivateSession
            )
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String
    let onTap: () -> Void
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ChatTap")

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15))
                )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            logger.debug("User message tapped")
            onTap()
        })
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String
    let accentColor: Color
    let textColor: Color
    let onTap: () -> Void
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ChatTap")

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // White dot indicator
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: textColor, fontSize: 13)

            Spacer(minLength: 60)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            logger.debug("Assistant message tapped")
            onTap()
        })
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color: Color
    private let baseText: String

    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "", color: Color = Color(red: 0.85, green: 0.47, blue: 0.34)) {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = AppLocalization.string(baseTexts[index])
        self.color = color
    }

    var body: some View {
        if energyGovernor.policy.animationLevel == .staticFrames {
            processingBody(dotCount: 1, date: nil)
        } else {
            TimelineView(.periodic(from: .now, by: dotInterval)) { context in
                processingBody(dotCount: dotPhase(for: context.date), date: context.date)
            }
        }
    }

    private func processingBody(dotCount: Int, date: Date?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner(color: color, date: date)
                .frame(width: 6)

            Text(baseText + String(repeating: ".", count: dotCount))
                .font(.system(size: 13))
                .foregroundColor(color)

            Spacer()
        }
    }

    private var dotInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            0.4
        case .reduced:
            1.0
        case .staticFrames:
            0.4
        }
    }

    private func dotPhase(for date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / dotInterval) % 3 + 1
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false
    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.white
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        tool.name != "Task" && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusDot(size: 6, animated: tool.status == .running || tool.status == .waitingForApproval)

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.name == "Task" && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? AppLocalization.string("Running agent...")
                    Text(verbatim: AppLocalization.format("%@ (%lld tools)", taskDesc, tool.subagentTools.count))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    @ViewBuilder
    private func statusDot(size: CGFloat, animated: Bool) -> some View {
        if animated && energyGovernor.policy.animationLevel != .staticFrames {
            TimelineView(.periodic(from: .now, by: pulseInterval)) { context in
                Circle()
                    .fill(statusColor.opacity(pulseOpacity(for: context.date)))
                    .frame(width: size, height: size)
            }
        } else {
            Circle()
                .fill(statusColor.opacity(0.6))
                .frame(width: size, height: size)
        }
    }

    private var pulseInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            1.0 / 12.0
        case .reduced:
            1.0 / 4.0
        case .staticFrames:
            1.0 / 12.0
        }
    }

    private var pulseDuration: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            1.2
        case .reduced:
            2.4
        case .staticFrames:
            1.2
        }
    }

    private func pulseOpacity(for date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pulseDuration) / pulseDuration
        let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2
        return 0.15 + wave * 0.45
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text(verbatim: AppLocalization.format("+%lld more tool uses", hiddenCount))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return AppLocalization.string("Interrupted")
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            statusDot

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if tool.status == .running && energyGovernor.policy.animationLevel != .staticFrames {
            TimelineView(.periodic(from: .now, by: pulseInterval)) { context in
                Circle()
                    .fill(statusColor.opacity(dotOpacity(for: context.date)))
                    .frame(width: 4, height: 4)
            }
        } else {
            Circle()
                .fill(statusColor.opacity(0.6))
                .frame(width: 4, height: 4)
        }
    }

    private var pulseInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            1.0 / 12.0
        case .reduced:
            1.0 / 4.0
        case .staticFrames:
            1.0 / 12.0
        }
    }

    private var pulseDuration: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            1.0
        case .reduced:
            2.0
        case .staticFrames:
            1.0
        }
    }

    private func dotOpacity(for date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pulseDuration) / pulseDuration
        let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2
        return 0.2 + wave * 0.4
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: AppLocalization.format("Subagent used %lld tools:", tools.count))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .italic()
                .lineLimit(isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let isInTmux: Bool
    let onGoToTerminal: () -> Void

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text("Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let sessionAction: SessionScopedApprovalAction?
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onDeny: () -> Void

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false
    @State private var showSessionButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text(AppLocalization.string("Deny"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
                    Text(AppLocalization.string(sessionAction.buttonTitleKey))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(TerminalColors.blue.opacity(0.26))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showSessionButton ? 1 : 0)
                .scaleEffect(showSessionButton ? 1 : 0.8)
            }

            // Allow button
            Button {
                onApprove()
            } label: {
                Text(AppLocalization.string("Allow"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.95))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showSessionButton = sessionAction != nil
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.2)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(verbatim: count == 1
                    ? AppLocalization.string("1 new message")
                    : AppLocalization.format("%lld new messages", count)
                )
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
