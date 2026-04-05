import SwiftUI

struct CodexSessionView: View {
    let session: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard

                if let intervention = session.intervention {
                    interventionCard(intervention)
                } else {
                    CodexThreadInspectorView(
                        session: session,
                        sessionMonitor: sessionMonitor,
                        mode: .chat
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.displayTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            HStack(spacing: 8) {
                providerBadge

                Text(session.phase.description)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            if let summary = session.clientInfo.terminalContextSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }

            if let preview = session.previewText ?? session.lastMessage {
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(3)
            }

            if !session.cwd.isEmpty && session.cwd != "/" {
                Text(session.cwd)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func interventionCard(_ intervention: SessionIntervention) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(intervention.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            MarkdownText(intervention.message, color: .white.opacity(0.72), fontSize: 12)

            if intervention.kind == .approval {
                approvalButtons(intervention)
            } else {
                questionForm(intervention)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func approvalButtons(_ intervention: SessionIntervention) -> some View {
        HStack(spacing: 8) {
            Button("Allow Once") {
                sessionMonitor.approvePermission(sessionId: session.sessionId)
                viewModel.exitChat()
            }
            .buttonStyle(CodexCapsuleButtonStyle(background: Color.white.opacity(0.9), foreground: .black))

            if intervention.supportsSessionScope {
                Button("Allow Session") {
                    sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
                    viewModel.exitChat()
                }
                .buttonStyle(CodexCapsuleButtonStyle(background: TerminalColors.blue.opacity(0.28)))
            }

            Button("Deny") {
                sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
                viewModel.exitChat()
            }
            .buttonStyle(CodexCapsuleButtonStyle(background: Color.white.opacity(0.1)))
        }
    }

    private func questionForm(_ intervention: SessionIntervention) -> some View {
        SessionQuestionForm(
            intervention: intervention,
            submitLabel: "Submit",
            onSubmit: { payload in
                sessionMonitor.answerIntervention(sessionId: session.sessionId, answers: payload)
                viewModel.exitChat()
            },
            secondaryActionTitle: "Cancel",
            onSecondaryAction: {
                viewModel.exitChat()
            }
        )
    }

    private var providerBadge: some View {
        Text(session.clientDisplayName.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(TerminalColors.blue.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(TerminalColors.blue.opacity(0.14))
            .clipShape(Capsule())
    }
}

enum CodexThreadInspectorMode {
    case chat
    case hover

    var historyLimit: Int {
        switch self {
        case .chat:
            return 6
        case .hover:
            return 3
        }
    }

    var resultLineLimit: Int? {
        switch self {
        case .chat:
            return nil
        case .hover:
            return 5
        }
    }
}

struct CodexThreadInspectorView: View {
    let session: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    let mode: CodexThreadInspectorMode

    @ObservedObject private var settings = AppSettings.shared
    @State private var snapshot: CodexThreadSnapshot?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var inputText = ""
    @State private var isSending = false
    @State private var sendError: String?
    @FocusState private var isInputFocused: Bool

    private var primaryResultText: String? {
        snapshot?.displayResultText ?? session.previewText ?? session.lastMessage
    }

    private var recentItems: [ChatHistoryItem] {
        let source = snapshot?.historyItems ?? session.chatItems
        let filtered = source.filter {
            switch $0.type {
            case .user, .assistant, .thinking:
                return true
            case .toolCall, .interrupted:
                return false
            }
        }
        return Array(filtered.suffix(mode.historyLimit))
    }

    private var canSendMessages: Bool {
        snapshot?.latestTurnId != nil && session.intervention == nil && session.phase != .ended
    }

    private var isInputDisabled: Bool {
        isSending || session.phase == .processing || !canSendMessages
    }

    private var inputPlaceholder: String {
        if session.phase == .processing {
            return "Codex is still working..."
        }
        if canSendMessages {
            return "Continue this thread..."
        }
        return "Thread is not ready for input"
    }

    private var bodyFontSize: CGFloat {
        CGFloat(settings.contentFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: mode == .hover ? 12 : 14) {
            HStack(spacing: 8) {
                Text(sectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                Text(SessionPhaseHelpers.phaseDescription(for: session.phase))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(SessionPhaseHelpers.phaseColor(for: session.phase).opacity(0.9))
            }

            if let text = primaryResultText {
                MarkdownText(
                    text,
                    color: .white.opacity(0.82),
                    fontSize: mode == .hover ? max(11, bodyFontSize - 1) : bodyFontSize
                )
                    .lineLimit(mode.resultLineLimit)
                    .fixedSize(horizontal: false, vertical: mode == .chat)
            } else if isLoading {
                loadingText
            } else {
                Text("No thread details yet. Once Codex responds, the latest result will show here.")
                    .font(.system(size: max(11, bodyFontSize - 1), weight: .medium))
                    .foregroundColor(.white.opacity(0.56))
            }

            if !recentItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(recentItems.enumerated()), id: \.offset) { _, item in
                        conversationRow(for: item)
                    }
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.system(size: max(10, bodyFontSize - 2), weight: .medium))
                    .foregroundColor(TerminalColors.amber.opacity(0.95))
            }

            if let sendError {
                Text(sendError)
                    .font(.system(size: max(10, bodyFontSize - 2), weight: .medium))
                    .foregroundColor(TerminalColors.amber.opacity(0.95))
            }

            composer
        }
        .padding(mode == .hover ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundView)
        .task(id: session.sessionId) {
            await reloadThread()
        }
        .onChange(of: session.phase) { _, newPhase in
            if newPhase != .processing {
                Task {
                    await reloadThread()
                }
            }
        }
    }

    private var sectionTitle: String {
        switch mode {
        case .chat:
            return "Latest thread result"
        case .hover:
            return "Session result"
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if mode == .chat {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        } else {
            Color.clear
        }
    }

    private var loadingText: some View {
        Text("Loading thread details...")
            .font(.system(size: max(11, bodyFontSize - 1), weight: .medium))
            .foregroundColor(.white.opacity(0.56))
    }

    private func conversationRow(for item: ChatHistoryItem) -> some View {
        let row = rowContent(for: item)
        return HStack(alignment: .top, spacing: 8) {
            Text(row.prefix)
                .font(.system(size: max(10, bodyFontSize - 2), weight: .semibold))
                .foregroundColor(row.prefixColor)
                .frame(width: 18, alignment: .leading)
                .padding(.top, 2)

            MarkdownText(row.text, color: row.textColor, fontSize: max(10, bodyFontSize - 2))
                .lineLimit(mode == .hover ? 2 : nil)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(inputPlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: bodyFontSize))
                .foregroundColor(isInputDisabled ? .white.opacity(0.4) : .white)
                .focused($isInputFocused)
                .disabled(isInputDisabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(isInputDisabled ? 0.04 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: isSending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(sendButtonColor)
            }
            .buttonStyle(.plain)
            .disabled(isInputDisabled || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var sendButtonColor: Color {
        if isSending {
            return TerminalColors.blue.opacity(0.95)
        }
        if isInputDisabled || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .white.opacity(0.2)
        }
        return .white.opacity(0.9)
    }

    private func rowContent(for item: ChatHistoryItem) -> (prefix: String, prefixColor: Color, text: String, textColor: Color) {
        switch item.type {
        case .user(let text):
            return ("你", .white.opacity(0.72), text, .white.opacity(0.72))
        case .assistant(let text):
            return ("答", .white, text, .white.opacity(0.82))
        case .thinking(let text):
            return ("注", TerminalColors.blue.opacity(0.9), text, .white.opacity(0.58))
        case .toolCall, .interrupted:
            return ("", .clear, "", .clear)
        }
    }

    @MainActor
    private func reloadThread() async {
        guard session.provider == .codex else { return }
        isLoading = true
        loadError = nil

        do {
            snapshot = try await sessionMonitor.loadCodexThread(sessionId: session.sessionId)
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let expectedTurnId = snapshot?.latestTurnId else {
            return
        }

        sendError = nil
        isSending = true

        Task {
            do {
                try await sessionMonitor.continueCodexThread(
                    sessionId: session.sessionId,
                    expectedTurnId: expectedTurnId,
                    text: trimmed
                )

                await MainActor.run {
                    inputText = ""
                    isSending = false
                }

                try? await Task.sleep(for: .milliseconds(350))
                await reloadThread()
            } catch {
                await MainActor.run {
                    sendError = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}

private struct CodexCapsuleButtonStyle: ButtonStyle {
    var background: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(foreground.opacity(configuration.isPressed ? 0.8 : 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(background.opacity(configuration.isPressed ? 0.72 : 1))
            )
    }
}
