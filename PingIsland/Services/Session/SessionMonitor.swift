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
    @Published private(set) var claudeUsageSnapshot: ClaudeUsageSnapshot?
    @Published private(set) var codexUsageSnapshot: CodexUsageSnapshot?

    nonisolated static var isRunningUnderXCTest: Bool {
        Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private let runtimeCoordinator: any RuntimeCoordinating
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var allSessions: [SessionState] = []
    private var usageRefreshTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private let shouldRefreshUsage: Bool
    private var questionDraftCache = SessionQuestionDraftCache()
    private var telemetryPendingAttentionSessionIDs: Set<String> = []

    init(
        runtimeCoordinator: any RuntimeCoordinating = RuntimeCoordinator.shared,
        observeSharedState: Bool = true
    ) {
        self.runtimeCoordinator = runtimeCoordinator
        self.shouldRefreshUsage = !Self.isRunningUnderXCTest
        guard observeSharedState else { return }
        if shouldRefreshUsage {
            claudeUsageSnapshot = UsageSnapshotCacheStore.loadClaude()
            codexUsageSnapshot = UsageSnapshotCacheStore.loadCodex()
        }

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        startEnergyAwareMaintenanceLoop()

        InterruptWatcherManager.shared.delegate = self

        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisibleSessions()
            }
            .store(in: &cancellables)

        if shouldRefreshUsage {
            refreshUsageState()
        }
    }

    deinit {
        maintenanceTask?.cancel()
        usageRefreshTask?.cancel()
    }

    // MARK: - Monitoring Lifecycle

    func questionDraft(sessionId: String, interventionId: String) -> SessionQuestionFormDraft? {
        questionDraftCache.draft(sessionId: sessionId, interventionId: interventionId)
    }

    func updateQuestionDraft(
        sessionId: String,
        interventionId: String,
        draft: SessionQuestionFormDraft
    ) {
        questionDraftCache.update(
            sessionId: sessionId,
            interventionId: interventionId,
            draft: draft
        )
    }

    func clearQuestionDraft(sessionId: String, interventionId: String) {
        questionDraftCache.clear(sessionId: sessionId, interventionId: interventionId)
    }

    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true
        if maintenanceTask == nil {
            startEnergyAwareMaintenanceLoop()
        }

        // Periodic liveness sweep: removes sessions whose Claude process has
        // died without delivering SessionEnd, plus garbage-collects sessions
        // already in .ended phase. See SessionStore.startLivenessSweep for
        // details.
        Task {
            await SessionStore.shared.startLivenessSweep()
        }

        let handleHookEvent: @Sendable (HookEvent) -> Void = { [self] event in
            Task { @MainActor in
                await self.handleIncomingHookEvent(event)
            }
        }

        HookSocketServer.shared.start(
            onEvent: handleHookEvent,
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

        Task {
            await ClaudeDesktopWatcher.shared.start()
        }

        Task {
            await runtimeCoordinator.start()
        }
        RemoteConnectorManager.shared.start(
            onEvent: handleHookEvent,
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func handleIncomingHookEvent(_ event: HookEvent) async {
        let effectiveEvent: HookEvent
        if await runtimeCoordinator.managesNativeSession(sessionID: event.sessionId, provider: event.provider) {
            effectiveEvent = event.withIngress(.nativeRuntime)
        } else {
            effectiveEvent = event
        }

        let shouldAutoApprovePermission = await Self.shouldAutoApproveClaudePermission(for: effectiveEvent)

        await SessionStore.shared.process(.hookReceived(effectiveEvent))

        if shouldAutoApprovePermission,
           let approvedToolUseId = await Self.resolvePendingApprovalToolUseId(for: effectiveEvent.sessionId, fallback: effectiveEvent.toolUseId) {
            if effectiveEvent.ingress == .remoteBridge {
                RemoteConnectorManager.shared.respondToPermission(
                    toolUseId: approvedToolUseId,
                    decision: "approveForSession"
                )
            } else {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: approvedToolUseId,
                    decision: "approveForSession"
                )
            }
            await SessionStore.shared.process(
                .permissionApproved(sessionId: effectiveEvent.sessionId, toolUseId: approvedToolUseId)
            )
            return
        }

        if let autoAnswer = Self.defaultQoderAutoAnswer(for: effectiveEvent) {
            if effectiveEvent.ingress == .remoteBridge {
                RemoteConnectorManager.shared.respondToIntervention(
                    toolUseId: autoAnswer.toolUseId,
                    decision: "answer",
                    updatedInput: autoAnswer.updatedInput
                )
            } else {
                HookSocketServer.shared.respondToIntervention(
                    toolUseId: autoAnswer.toolUseId,
                    decision: "answer",
                    updatedInput: autoAnswer.updatedInput
                )
            }
            await SessionStore.shared.process(
                .interventionResolved(
                    sessionId: effectiveEvent.sessionId,
                    nextPhase: .processing,
                    submittedAnswers: autoAnswer.answers
                )
            )
        }

        if effectiveEvent.event == "PostToolUse",
           let toolUseId = effectiveEvent.toolUseId,
           let session = await SessionStore.shared.session(for: effectiveEvent.sessionId) {
            if session.activePermission?.toolUseId == toolUseId {
                // Tool was approved externally (e.g. terminal) and completed.
                // Resolve the pending Island-side intervention.
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: effectiveEvent.sessionId, toolUseId: toolUseId)
                )
            } else if session.activePermission?.toolUseId != toolUseId {
                if effectiveEvent.ingress == .remoteBridge {
                    RemoteConnectorManager.shared.respondToPermission(
                        toolUseId: toolUseId,
                        decision: "cancel"
                    )
                } else {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            }
        }

        let sessionPhase = effectiveEvent.sessionPhase
        if Self.shouldWatchTranscript(for: effectiveEvent, phase: sessionPhase) {
            let session = await SessionStore.shared.session(for: effectiveEvent.sessionId)
            InterruptWatcherManager.shared.startWatching(
                sessionId: effectiveEvent.sessionId,
                cwd: effectiveEvent.cwd,
                explicitFilePath: session?.clientInfo.sessionFilePath
            )
        }

        if Self.shouldStopWatchingTranscript(for: effectiveEvent) {
            InterruptWatcherManager.shared.stopWatching(sessionId: effectiveEvent.sessionId)
        }

        if effectiveEvent.event == "Stop", effectiveEvent.ingress != .remoteBridge {
            HookSocketServer.shared.cancelPendingPermissions(sessionId: effectiveEvent.sessionId)
        }
    }

    func stopMonitoring() {
        hasStarted = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
        Task {
            await SessionStore.shared.stopLivenessSweep()
        }
        HookSocketServer.shared.stop()
        RemoteConnectorManager.shared.stop()
        Task {
            await CodexAppServerMonitor.shared.stop()
        }
        Task {
            await ClaudeDesktopWatcher.shared.stop()
        }
        Task {
            await runtimeCoordinator.stop()
        }
    }

    private func startEnergyAwareMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let policy = await MainActor.run {
                    EnergyGovernor.shared.policy
                }

                guard let interval = policy.sessionMaintenanceInterval else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }

                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    guard let self else { return }
                    self.refreshVisibleSessions()
                    if self.shouldRefreshUsage,
                       EnergyGovernor.shared.policy.usageRefreshInterval != nil {
                        self.refreshUsageState()
                    }
                }

                await SessionStore.shared.process(
                    .pruneTimedOutExternalContinuations(now: Date())
                )
                await SessionStore.shared.pruneOrphanedSessions()
            }
        }
    }

    func refreshUsageState() {
        usageRefreshTask?.cancel()
        usageRefreshTask = Task { [weak self] in
            guard let self else { return }

            let cachedClaudeSnapshot = UsageSnapshotCacheStore.loadClaude()
            let cachedCodexSnapshot = UsageSnapshotCacheStore.loadCodex()

            let claudeSnapshot = await Task.detached(priority: .utility) {
                try? ClaudeUsageLoader.load()
            }.value

            let codexSnapshot = await Task.detached(priority: .utility) {
                try? CodexUsageLoader.load()
            }.value

            guard !Task.isCancelled else { return }

            if let claudeSnapshot {
                UsageSnapshotCacheStore.saveClaude(claudeSnapshot)
            }
            if let codexSnapshot {
                UsageSnapshotCacheStore.saveCodex(codexSnapshot)
                await AgentUsageStore.shared.recordCodexUsageSnapshot(codexSnapshot)
            }

            self.claudeUsageSnapshot = claudeSnapshot ?? cachedClaudeSnapshot
            self.codexUsageSnapshot = codexSnapshot ?? cachedCodexSnapshot
            self.syncCodexThreadDiscovery(using: self.codexUsageSnapshot)
        }
    }

    // MARK: - Native Runtime

    func startNativeSession(provider: SessionProvider, cwd: String, preferredSessionID: String? = nil) {
        Task {
            _ = try? await runtimeCoordinator.startSession(
                provider: provider,
                cwd: cwd,
                preferredSessionID: preferredSessionID,
                metadata: [:]
            )
        }
    }

    func terminateNativeSession(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.ingress == .nativeRuntime else {
                return
            }

            try? await runtimeCoordinator.terminateSession(
                provider: session.provider,
                sessionID: session.sessionId
            )
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String, forSession: Bool = false) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .nativeRuntime {
                try? await runtimeCoordinator.approveSession(
                    provider: session.provider,
                    sessionID: session.sessionId,
                    forSession: forSession
                )
                await TelemetryService.shared.recordAttentionResolved(
                    session,
                    resolution: forSession ? "approve_for_session" : "approve"
                )
                return
            }

            let shouldRespondToHookPermission = session.intervention?.metadata["source"] == "codex_hook_permission"
                && session.activePermission != nil

            if session.ingress == .codexAppServer, !shouldRespondToHookPermission {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                await CodexAppServerMonitor.shared.approve(threadId: resolvedSessionId, forSession: forSession)
                await TelemetryService.shared.recordAttentionResolved(
                    session,
                    resolution: forSession ? "approve_for_session" : "approve"
                )
                return
            }

            guard let permission = session.activePermission else { return }

            if forSession, session.scopedApprovalAction == .autoApprove {
                await SessionStore.shared.process(
                    .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
                )
                if session.ingress == .remoteBridge {
                    RemoteConnectorManager.shared.respondToPermission(
                        toolUseId: permission.toolUseId,
                        decision: "approveForSession"
                    )
                } else {
                    HookSocketServer.shared.respondToPermission(
                        toolUseId: permission.toolUseId,
                        decision: "approveForSession"
                    )
                }
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                )
                await TelemetryService.shared.recordAttentionResolved(session, resolution: "approve_for_session")
                return
            }

            if session.ingress == .remoteBridge {
                RemoteConnectorManager.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "allow"
                )
            } else {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "allow"
                )
            }

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
            await TelemetryService.shared.recordAttentionResolved(session, resolution: "approve")
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .nativeRuntime {
                try? await runtimeCoordinator.denySession(
                    provider: session.provider,
                    sessionID: session.sessionId,
                    reason: reason
                )
                await TelemetryService.shared.recordAttentionResolved(session, resolution: "deny")
                return
            }

            let shouldRespondToHookPermission = session.intervention?.metadata["source"] == "codex_hook_permission"
                && session.activePermission != nil

            if session.ingress == .codexAppServer, !shouldRespondToHookPermission {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                await CodexAppServerMonitor.shared.deny(threadId: resolvedSessionId)
                await TelemetryService.shared.recordAttentionResolved(session, resolution: "deny")
                return
            }

            guard let permission = session.activePermission else { return }

            if session.ingress == .remoteBridge {
                RemoteConnectorManager.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            } else {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            }

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
            await TelemetryService.shared.recordAttentionResolved(session, resolution: "deny")
        }
    }

    func answerIntervention(sessionId: String, answers: [String: [String]]) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            if session.ingress == .nativeRuntime {
                try? await runtimeCoordinator.answerSession(
                    provider: session.provider,
                    sessionID: session.sessionId,
                    answers: answers
                )
                await TelemetryService.shared.recordAttentionResolved(session, resolution: "answer")
                return
            }

            if session.ingress == .codexAppServer {
                let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
                if await CodexAppServerMonitor.shared.answer(threadId: resolvedSessionId, answers: answers) {
                    await TelemetryService.shared.recordAttentionResolved(session, resolution: "answer")
                    return
                }
                guard let intervention = session.intervention,
                      Self.shouldSubmitCodexRolloutUserInput(intervention),
                      let callId = Self.codexRolloutUserInputCallId(for: intervention) else {
                    return
                }
                do {
                    try await CodexAppServerMonitor.shared.submitRequestUserInputOutput(
                        threadId: resolvedSessionId,
                        callId: callId,
                        answers: answers
                    )
                    await SessionStore.shared.process(
                        .interventionResolved(
                            sessionId: sessionId,
                            nextPhase: .processing,
                            submittedAnswers: answers
                        )
                    )
                    await TelemetryService.shared.recordAttentionResolved(session, resolution: "answer")
                } catch {
                    NSLog("Failed to submit Codex request_user_input answer: \(error.localizedDescription)")
                }
                return
            }

            guard let intervention = session.intervention,
                  intervention.kind == .question,
                  let updatedInput = updatedHookToolInput(
                    for: intervention,
                    answers: answers,
                    clientInfo: session.clientInfo
                  )
            else {
                return
            }

            // 使用正确的 toolUseId：优先使用 metadata 中保存的原始值
            let toolUseId = intervention.metadata["originalToolUseId"] ?? intervention.id
            if session.ingress == .remoteBridge {
                RemoteConnectorManager.shared.respondToIntervention(
                    toolUseId: toolUseId,
                    decision: "answer",
                    updatedInput: updatedInput
                )
            } else {
                HookSocketServer.shared.respondToIntervention(
                    toolUseId: toolUseId,
                    decision: "answer",
                    updatedInput: updatedInput
                )
            }

            await SessionStore.shared.process(
                .interventionResolved(
                    sessionId: sessionId,
                    nextPhase: .processing,
                    submittedAnswers: answers
                )
            )
            await TelemetryService.shared.recordAttentionResolved(session, resolution: "answer")
            HookWalkthroughDemoRunner.shared.completeIfNeeded(
                sessionId: sessionId,
                intervention: intervention
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
        if let session = await SessionStore.shared.session(for: sessionId),
           session.ingress == .nativeRuntime {
            try await runtimeCoordinator.continueSession(
                provider: session.provider,
                sessionID: session.sessionId,
                expectedTurnId: expectedTurnId,
                text: text
            )
            return
        }

        let resolvedSessionId = await SessionStore.shared.resolvedCodexSessionId(for: sessionId)
        try await CodexAppServerMonitor.shared.continueThread(
            threadId: resolvedSessionId,
            expectedTurnId: expectedTurnId,
            text: text
        )
    }

    func sendSessionMessage(sessionId: String, text: String, expectedTurnId: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let session = await SessionStore.shared.session(for: sessionId) else {
            throw NSError(
                domain: "PingIsland.SessionMonitor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Session not found."]
            )
        }

        if session.provider == .codex,
           session.ingress == .nativeRuntime {
            try await continueCodexThread(
                sessionId: sessionId,
                expectedTurnId: expectedTurnId ?? "",
                text: trimmed
            )
            return
        }

        if session.ingress == .nativeRuntime {
            try await runtimeCoordinator.sendUserInput(
                provider: session.provider,
                sessionID: session.sessionId,
                text: trimmed
            )
            return
        }

        if session.supportsTmuxCLIMessaging {
            guard let target = await findTmuxTarget(for: session) else {
                throw NSError(
                    domain: "PingIsland.SessionMonitor",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Could not find the terminal pane for this session."]
                )
            }

            guard await ToolApprovalHandler.shared.sendMessage(trimmed, to: target) else {
                throw NSError(
                    domain: "PingIsland.SessionMonitor",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to send the follow-up message to the terminal session."]
                )
            }

            return
        }

        if session.provider == .codex,
           session.ingress == .codexAppServer {
            try await continueCodexThread(
                sessionId: sessionId,
                expectedTurnId: expectedTurnId ?? "",
                text: trimmed
            )
            return
        }

        guard session.isInTmux, let tty = session.tty else {
            throw NSError(
                domain: "PingIsland.SessionMonitor",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Inline follow-up requires an active tmux-backed terminal session."]
            )
        }

        guard let target = await findTmuxTarget(tty: tty) else {
            throw NSError(
                domain: "PingIsland.SessionMonitor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Could not find the terminal pane for this session."]
            )
        }

        guard await ToolApprovalHandler.shared.sendMessage(trimmed, to: target) else {
            throw NSError(
                domain: "PingIsland.SessionMonitor",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to send the follow-up message to the terminal session."]
            )
        }
    }

    func sendNativeSessionInput(sessionId: String, text: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  session.ingress == .nativeRuntime else {
                return
            }

            try? await runtimeCoordinator.sendUserInput(
                provider: session.provider,
                sessionID: session.sessionId,
                text: text
            )
        }
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
        let pendingSessions = visibleSessions.filter { $0.needsAttention }
        recordNewAttentionRequests(in: pendingSessions)
        instances = visibleSessions
        pendingInstances = pendingSessions
    }

    private func recordNewAttentionRequests(in pendingSessions: [SessionState]) {
        let currentIDs = Set(pendingSessions.map(\.sessionId))
        let newSessions = pendingSessions.filter { !telemetryPendingAttentionSessionIDs.contains($0.sessionId) }
        telemetryPendingAttentionSessionIDs = currentIDs

        for session in newSessions {
            Task {
                await TelemetryService.shared.recordAttentionRequested(session)
            }
        }
    }

    private func filteredVisibleSessions(from sessions: [SessionState]) -> [SessionState] {
        let visibilityMode = AppSettings.subagentVisibilityMode
        let primaryVisibleSessions = sessions.filter {
            !$0.shouldHideFromPrimaryUI && $0.shouldDisplaySubagent(in: visibilityMode)
        }
        let dedupedSessions = deduplicateSameProjectClaudeSessions(from: primaryVisibleSessions)
        return dedupedSessions.filter { candidate in
            guard shouldCheckDuplicateVisibility(for: candidate) else {
                return true
            }

            return !dedupedSessions.contains { other in
                candidate.shouldHideAsDuplicateCodexPlaceholder(comparedTo: other)
                    || candidate.shouldHideAsDuplicateOpenCodeChildSession(comparedTo: other)
            }
        }
    }

    /// When Claude is resumed or restarted, concurrent hook events can create multiple
    /// sessions for the same project before endOrphanedSessions has a chance to clean up.
    /// Keep only the most recently active session per provider + cwd pair.
    private func deduplicateSameProjectClaudeSessions(
        from sessions: [SessionState]
    ) -> [SessionState] {
        var bestByKey: [String: SessionState] = [:]
        var order: [String] = []

        for session in sessions {
            guard session.provider == .claude else { continue }
            let cwd = session.cwd
            guard !cwd.isEmpty else { continue }
            let key = "\(session.provider.rawValue):\(cwd)"
            if let existing = bestByKey[key] {
                if session.lastActivity > existing.lastActivity {
                    bestByKey[key] = session
                }
            } else {
                bestByKey[key] = session
                order.append(key)
            }
        }

        var keep = Set(bestByKey.values.map(\.sessionId))
        return sessions.filter { session in
            guard session.provider == .claude, !session.cwd.isEmpty else { return true }
            return keep.contains(session.sessionId)
        }
    }

    private func shouldCheckDuplicateVisibility(for session: SessionState) -> Bool {
        session.isLikelyEmptyCodexPlaceholderForUI
            || session.isLikelyTransientCodexContinuationPlaceholder
            || session.isLikelyOpenCodeChildSessionPlaceholderForUI
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTTY = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTTY == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func findTmuxTarget(for session: SessionState) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        let normalizedTTY = session.tty?
            .replacingOccurrences(of: "/dev/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPaneID = session.clientInfo.tmuxPaneIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: [
                    "list-panes",
                    "-a",
                    "-F",
                    "#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_tty}"
                ]
            )

            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneID = parts[1]
                let paneTTY = parts.count >= 3
                    ? parts[2].replacingOccurrences(of: "/dev/", with: "")
                    : ""

                if normalizedPaneID?.isEmpty == false,
                   paneID == normalizedPaneID,
                   let target = TmuxTarget(from: target) {
                    return target
                }

                if normalizedTTY?.isEmpty == false,
                   paneTTY == normalizedTTY,
                   let target = TmuxTarget(from: target) {
                    return target
                }
            }
        } catch {
            // Fall back to the older pid/cwd matching path below.
        }

        if let pid = session.pid,
           let target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
            return target
        }

        return nil
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private enum HookAnswerEncodingStrategy {
        case lookupAliases
        case codeBuddyCLI
        case questionText
        case questionIndex
    }

    private nonisolated static func answerEncodingStrategy(for clientInfo: SessionClientInfo?) -> HookAnswerEncodingStrategy {
        let normalizedClientInfo = clientInfo?.normalizedForClaudeRouting()
        let profileID = normalizedClientInfo?.profileID?.lowercased()
        let bundleIdentifier = normalizedClientInfo?.bundleIdentifier?.lowercased()

        if profileID == "qoder-cli" {
            return .questionText
        }

        if profileID == "codebuddy-cli" {
            return .codeBuddyCLI
        }

        if profileID == "qoder"
            || profileID == "qoderwork"
            || profileID == "codebuddy"
            || profileID == "workbuddy"
            || bundleIdentifier == "com.qoder.ide"
            || bundleIdentifier == "com.qoder.work"
            || bundleIdentifier == "com.tencent.codebuddy"
            || bundleIdentifier == "com.codebuddy.app"
            || bundleIdentifier == "com.workbuddy.workbuddy" {
            return .lookupAliases
        }

        if clientInfo?.isQwenCodeClient == true {
            return .questionIndex
        }

        return .questionText
    }

    nonisolated static func updatedHookToolInput(
        rawJSON: String,
        answers: [String: [String]],
        clientInfo: SessionClientInfo? = nil
    ) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var updated = payload
        let questions = payload["questions"] as? [[String: Any]] ?? []
        var encodedAnswers: [String: Any] = [:]

        let encodingStrategy = answerEncodingStrategy(for: clientInfo)

        for (index, question) in questions.enumerated() {
            let lookupKeys = [
                question["id"] as? String,
                question["question"] as? String,
                "\(index)"
            ].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            guard let values = lookupKeys.compactMap({ answers[$0] }).first, !values.isEmpty else { continue }
            let encodedValue: Any = values.count == 1 ? values[0] : values
            switch encodingStrategy {
            case .lookupAliases:
                for key in lookupKeys {
                    encodedAnswers[key] = encodedValue
                }
            case .codeBuddyCLI:
                for key in lookupKeys + ["q_\(index)"] {
                    encodedAnswers[key] = encodedValue
                }
            case .questionIndex:
                encodedAnswers["\(index)"] = encodedValue
            case .questionText:
                let outputKey = (question["question"] as? String)
                    ?? (question["prompt"] as? String)
                    ?? (question["id"] as? String)
                    ?? "\(index)"
                guard !outputKey.isEmpty else { continue }
                encodedAnswers[outputKey] = encodedValue
            }
        }

        updated["answers"] = encodedAnswers
        return updated
    }

    private func updatedHookToolInput(
        for intervention: SessionIntervention,
        answers: [String: [String]],
        clientInfo: SessionClientInfo
    ) -> [String: Any]? {
        guard let rawJSON = intervention.metadata["toolInputJSON"] else {
            return nil
        }

        var updatedInput = Self.updatedHookToolInput(rawJSON: rawJSON, answers: answers, clientInfo: clientInfo)
        if let transcriptCallId = intervention.metadata["transcriptCallId"], !transcriptCallId.isEmpty {
            updatedInput?["tool_call_id"] = transcriptCallId
            updatedInput?["call_id"] = transcriptCallId
        }
        return updatedInput
    }

    nonisolated static func defaultAnswers(for intervention: SessionIntervention) -> [String: [String]] {
        intervention.questions.reduce(into: [String: [String]]()) { partial, question in
            guard let firstOption = question.options.first?.title, !firstOption.isEmpty else { return }
            partial[question.id] = [firstOption]
        }
    }

    nonisolated static func shouldSubmitCodexRolloutUserInput(_ intervention: SessionIntervention) -> Bool {
        intervention.kind == .question
            && intervention.metadata["source"] == "codex_rollout_request_user_input"
            && intervention.metadata["responseMode"] == "external_only"
    }

    nonisolated static func codexRolloutUserInputCallId(for intervention: SessionIntervention) -> String? {
        [
            intervention.metadata["toolUseId"],
            intervention.metadata["callId"],
            intervention.metadata["call_id"],
            intervention.id
        ]
        .compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .first
    }

    nonisolated static func defaultQoderAutoAnswer(
        for event: HookEvent
    ) -> (toolUseId: String, answers: [String: [String]], updatedInput: [String: Any])? {
        let normalizedClientInfo = event.clientInfo.normalizedForClaudeRouting()
        let isManagedQuestion =
            normalizedClientInfo.profileID == "qoder"
            || normalizedClientInfo.profileID == "qoderwork"
            || normalizedClientInfo.profileID == "codebuddy"
            || normalizedClientInfo.profileID == "codebuddy-cli"
            || normalizedClientInfo.profileID == "workbuddy"
            || normalizedClientInfo.bundleIdentifier == "com.qoder.ide"
            || normalizedClientInfo.bundleIdentifier == "com.qoder.work"
            || normalizedClientInfo.bundleIdentifier == "com.tencent.codebuddy"
            || normalizedClientInfo.bundleIdentifier == "com.codebuddy.app"
            || normalizedClientInfo.bundleIdentifier == "com.workbuddy.workbuddy"

        guard isManagedQuestion,
              let toolUseId = event.toolUseId,
              let intervention = event.intervention,
              intervention.kind == .question,
              let rawJSON = intervention.metadata["toolInputJSON"]
        else {
            return nil
        }

        let resolvedQuestions = intervention.resolvedQuestions
        guard !resolvedQuestions.isEmpty else {
            return nil
        }

        let answers = defaultAnswers(for: intervention)
        guard answers.count == resolvedQuestions.count,
              let updatedInput = updatedHookToolInput(
                rawJSON: rawJSON,
                answers: answers,
                clientInfo: event.clientInfo
              )
        else {
            return nil
        }

        return (toolUseId, answers, updatedInput)
    }

    private nonisolated static func shouldAutoApproveClaudePermission(for event: HookEvent) async -> Bool {
        guard event.provider == .claude,
              event.event == "PermissionRequest",
              event.status == "waiting_for_approval"
        else {
            return false
        }

        guard let session = await SessionStore.shared.session(for: event.sessionId) else {
            return false
        }

        return session.autoApprovePermissions
            && session.provider == .claude
            && session.clientInfo.kind == .claudeCode
    }

    private nonisolated static func resolvePendingApprovalToolUseId(
        for sessionId: String,
        fallback: String?
    ) async -> String? {
        if let toolUseId = await SessionStore.shared.session(for: sessionId)?.activePermission?.toolUseId,
           !toolUseId.isEmpty {
            return toolUseId
        }

        guard let fallback, !fallback.isEmpty else { return nil }
        return fallback
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

    private func syncCodexThreadDiscovery(using snapshot: CodexUsageSnapshot?) {
        guard let threadID = snapshot?.threadID else { return }

        Task {
            let alreadyTracked = await SessionStore.shared.containsSession(threadID)
            guard !alreadyTracked else { return }
            await CodexAppServerMonitor.shared.refreshThreadDiscovery(threadId: threadID)
        }
    }

    nonisolated static func shouldWatchTranscript(for event: HookEvent, phase: SessionPhase) -> Bool {
        guard event.ingress != .remoteBridge else { return false }
        switch event.provider {
        case .claude:
            guard !event.clientInfo.isOpenClawGatewayClient else { return false }
            return phase == .processing
        case .codex:
            guard event.ingress == .hookBridge else { return false }
            switch event.event {
            case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse":
                return event.status != "ended"
            default:
                return phase == .processing || phase == .waitingForInput || phase.isWaitingForApproval
            }
        default:
            return false
        }
    }

    nonisolated static func shouldStopWatchingTranscript(for event: HookEvent) -> Bool {
        guard event.ingress != .remoteBridge else { return true }
        switch event.provider {
        case .claude:
            return event.status == "ended"
        case .codex:
            return event.status == "ended" || event.event == "Stop"
        case .gemini:
            return event.status == "ended"
        default:
            return false
        }
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
