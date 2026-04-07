import Foundation
import IslandShared

actor SessionStore {
    private var sessions: [String: AgentSession] = [:]
    private var selectedSessionID: String?
    private var isExpanded = false
    private let snapshotDidChange: @MainActor (SessionSnapshot) -> Void

    init(snapshotDidChange: @escaping @MainActor (SessionSnapshot) -> Void) {
        self.snapshotDidChange = snapshotDidChange
    }

    func ingest(_ envelope: BridgeEnvelope) async {
        var session = sessions[envelope.sessionKey] ?? AgentSession(
            id: envelope.sessionKey,
            provider: envelope.provider,
            title: envelope.title ?? defaultTitle(for: envelope.provider),
            preview: envelope.preview ?? "Waiting for activity",
            cwd: envelope.cwd,
            status: envelope.status ?? SessionStatus(kind: .active),
            terminalContext: envelope.terminalContext
        )

        session.title = envelope.title ?? session.title
        session.preview = envelope.preview ?? session.preview
        session.cwd = envelope.cwd ?? session.cwd
        session.status = envelope.status ?? session.status
        session.updatedAt = envelope.sentAt
        session.terminalContext = envelope.terminalContext
        session.metadata.merge(envelope.metadata) { _, new in new }
        session.intervention = envelope.intervention
        sessions[envelope.sessionKey] = session

        if selectedSessionID == nil {
            selectedSessionID = session.id
        }
        await publish()
    }

    func ingestCodexStatus(
        sessionID: String,
        title: String?,
        preview: String?,
        status: SessionStatus,
        metadata: [String: String] = [:]
    ) async {
        var session = sessions[sessionID] ?? AgentSession(
            id: sessionID,
            provider: .codex,
            title: title ?? "Codex Session",
            preview: preview ?? "Waiting for activity",
            status: status
        )
        session.title = title ?? session.title
        session.preview = preview ?? session.preview
        session.status = status
        session.updatedAt = .now
        session.metadata.merge(metadata) { _, new in new }
        sessions[sessionID] = session
        if selectedSessionID == nil {
            selectedSessionID = sessionID
        }
        await publish()
    }

    func clearIntervention(for sessionID: String) async {
        guard var session = sessions[sessionID] else { return }
        session.intervention = nil
        if session.status.kind == .waitingForApproval || session.status.kind == .waitingForInput {
            session.status = SessionStatus(kind: .active)
        }
        sessions[sessionID] = session
        await publish()
    }

    func select(sessionID: String) async {
        selectedSessionID = sessionID
        await publish()
    }

    func setExpanded(_ expanded: Bool) async {
        isExpanded = expanded
        await publish()
    }

    private func publish() async {
        let orderedSessions = sessions.values.sorted { lhs, rhs in
            if lhs.status.requiresAttention != rhs.status.requiresAttention {
                return lhs.status.requiresAttention
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        let snapshot = SessionSnapshot(
            sessions: orderedSessions,
            selectedSessionID: selectedSessionID ?? orderedSessions.first?.id,
            isExpanded: isExpanded || orderedSessions.contains(where: { $0.intervention != nil })
        )
        await snapshotDidChange(snapshot)
    }

    private func defaultTitle(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: "Claude Session"
        case .codex: "Codex Session"
        case .copilot: "Copilot Session"
        }
    }
}
