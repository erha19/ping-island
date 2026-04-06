//
//  SessionMonitor.swift
//  PingIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class SessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var allSessions: [SessionState] = []

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshVisibleSessions()
                Task {
                    await SessionStore.shared.process(
                        .pruneTimedOutExternalContinuations(now: Date())
                    )
                }
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))

                    if let autoAnswer = await MainActor.run(body: { Self.defaultQoderWorkAutoAnswer(for: event) }) {
                        await MainActor.run {
                            HookSocketServer.shared.respondToIntervention(
                                toolUseId: autoAnswer.toolUseId,
                                decision: "answer",
                                updatedInput: autoAnswer.updatedInput
                            )
                        }
                        await SessionStore.shared.process(
                            .interventionResolved(sessionId: event.sessionId, nextPhase: .processing)
                        )
                    }

                    if event.event == "PostToolUse",
                       let toolUseId = event.toolUseId,
                       let session = await SessionStore.shared.session(for: event.sessionId),
                       session.activePermission?.toolUseId != toolUseId {
                        await MainActor.run {
                            HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                        }
                    }
                }

                if event.provider == .claude, event.sessionPhase == .processing {
                    Task {
                        let session = await SessionStore.shared.session(for: event.sessionId)
                        await MainActor.run {
                            InterruptWatcherManager.shared.startWatching(
                                sessionId: event.sessionId,
                                cwd: event.cwd,
                                explicitFilePath: session?.clientInfo.sessionFilePath
                            )
                        }
                    }
                }

                if event.provider == .claude, event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )

        Task {
            await CodexAppServerMonitor.shared.start()
        }
    }

    func stopMonitoring() {
        hasStarted = false
        HookSocketServer.shared.stop()
        Task {
            await CodexAppServerMonitor.shared.stop()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String, forSession: Bool = false) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .codexAppServer {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                await CodexAppServerMonitor.shared.approve(threadId: resolvedSessionId, forSession: forSession)
                return
            }

            guard let permission = session.activePermission else { return }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .codexAppServer {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                await CodexAppServerMonitor.shared.deny(threadId: resolvedSessionId)
                return
            }

            guard let permission = session.activePermission else { return }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    func answerIntervention(sessionId: String, answers: [String: [String]]) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .codexAppServer {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                await CodexAppServerMonitor.shared.answer(threadId: resolvedSessionId, answers: answers)
                return
            }

            guard let intervention = session.intervention,
                  intervention.kind == .question,
                  let updatedInput = updatedHookToolInput(for: intervention, answers: answers)
            else {
                return
            }

            HookSocketServer.shared.respondToIntervention(
                toolUseId: intervention.id,
                decision: "answer",
                updatedInput: updatedInput
            )

            await SessionStore.shared.process(
                .interventionResolved(sessionId: sessionId, nextPhase: .processing)
            )
        }
    }

    func loadCodexThread(sessionId: String) async throws -> CodexThreadSnapshot {
        let session = await SessionStore.shared.session(for: sessionId)
        let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)

        do {
            let snapshot = try await CodexAppServerMonitor.shared.readThread(
                threadId: resolvedSessionId,
                includeTurns: true
            )
            if !snapshot.historyItems.isEmpty || session?.clientInfo.sessionFilePath == nil {
                return snapshot
            }
        } catch {
            if let fallback = await loadCodexRolloutFallback(sessionId: sessionId, session: session) {
                return fallback
            }
            throw error
        }

        if let fallback = await loadCodexRolloutFallback(sessionId: sessionId, session: session) {
            return fallback
        }

        throw NSError(
            domain: "PingIsland.Codex",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "No Codex thread details available yet."]
        )
    }

    func continueCodexThread(sessionId: String, expectedTurnId: String, text: String) async throws {
        let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
        try await CodexAppServerMonitor.shared.continueThread(
            threadId: resolvedSessionId,
            expectedTurnId: expectedTurnId,
            text: text
        )
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionArchived(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        allSessions = sessions
        refreshVisibleSessions()
    }

    private func refreshVisibleSessions() {
        let visibleSessions = filteredVisibleSessions(from: allSessions)
        instances = visibleSessions
        pendingInstances = visibleSessions.filter { $0.needsAttention }
    }

    private func filteredVisibleSessions(from sessions: [SessionState]) -> [SessionState] {
        let primaryVisibleSessions = sessions.filter { !$0.shouldHideFromPrimaryUI }
        return primaryVisibleSessions.filter { candidate in
            !primaryVisibleSessions.contains { other in
                candidate.shouldHideAsDuplicateCodexPlaceholder(comparedTo: other)
            }
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private nonisolated static func updatedHookToolInput(rawJSON: String, answers: [String: [String]]) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var updated = payload
        let questions = payload["questions"] as? [[String: Any]] ?? []
        var encodedAnswers: [String: Any] = [:]

        for (index, question) in questions.enumerated() {
            let keys = [
                question["id"] as? String,
                question["question"] as? String,
                "\(index)"
            ].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            guard let values = keys.compactMap({ answers[$0] }).first, !values.isEmpty else { continue }
            let encodedValue: Any = values.count == 1 ? values[0] : values
            for key in keys {
                encodedAnswers[key] = encodedValue
            }
        }

        updated["answers"] = encodedAnswers
        return updated
    }

    private func updatedHookToolInput(for intervention: SessionIntervention, answers: [String: [String]]) -> [String: Any]? {
        guard let rawJSON = intervention.metadata["toolInputJSON"] else {
            return nil
        }

        return Self.updatedHookToolInput(rawJSON: rawJSON, answers: answers)
    }

    nonisolated static func defaultAnswers(for intervention: SessionIntervention) -> [String: [String]] {
        intervention.questions.reduce(into: [String: [String]]()) { partial, question in
            guard let firstOption = question.options.first?.title, !firstOption.isEmpty else { return }
            partial[question.id] = [firstOption]
        }
    }

    nonisolated static func defaultQoderWorkAutoAnswer(
        for event: HookEvent
    ) -> (toolUseId: String, updatedInput: [String: Any])? {
        let isQoderWork =
            event.clientInfo.profileID == "qoderwork"
            || event.clientInfo.bundleIdentifier == "com.qoder.work"

        guard isQoderWork,
              let toolUseId = event.toolUseId,
              let intervention = event.intervention,
              intervention.kind == .question,
              let rawJSON = intervention.metadata["toolInputJSON"]
        else {
            return nil
        }

        let answers = defaultAnswers(for: intervention)
        guard !answers.isEmpty,
              let updatedInput = updatedHookToolInput(rawJSON: rawJSON, answers: answers)
        else {
            return nil
        }

        return (toolUseId, updatedInput)
    }

    private func loadCodexRolloutFallback(
        sessionId: String,
        session: SessionState?
    ) async -> CodexThreadSnapshot? {
        guard let session else { return nil }

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: sessionId,
            fallbackCwd: session.cwd,
            clientInfo: session.clientInfo
        )

        if let snapshot {
            await SessionStore.shared.syncCodexThreadSnapshot(snapshot, ingress: .hookBridge)
        }

        return snapshot
    }
}

// MARK: - Interrupt Watcher Delegate

extension SessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }

    nonisolated func didObserveFileChange(sessionId: String) {
        Task {
            await SessionStore.shared.requestFileSync(for: sessionId)
        }
    }
}
