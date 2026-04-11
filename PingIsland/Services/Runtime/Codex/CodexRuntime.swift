//
//  CodexRuntime.swift
//  PingIsland
//
//  Isolated native runtime scaffold for Codex sessions.
//

import Foundation

actor CodexRuntime: SessionRuntime {
    let provider: SessionProvider = .codex
    nonisolated let events: AsyncStream<SessionRuntimeEvent>

    private let featureFlag: RuntimeFeatureFlag = .nativeCodexRuntime
    private let monitor: CodexAppServerMonitor
    private var continuation: AsyncStream<SessionRuntimeEvent>.Continuation?
    private var activeSessions: [String: SessionRuntimeHandle] = [:]

    init(monitor: CodexAppServerMonitor = .shared) {
        self.monitor = monitor
        var capturedContinuation: AsyncStream<SessionRuntimeEvent>.Continuation?
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func prepare() async {
        await monitor.start()
        continuation?.yield(.availabilityChanged(await isAvailable()))
    }

    func shutdown() async {
        activeSessions.removeAll()
        continuation?.finish()
    }

    func isAvailable() async -> Bool {
        FeatureFlags.isEnabled(featureFlag) && Self.resolveCodexExecutable() != nil
    }

    func startSession(_ request: SessionRuntimeLaunchRequest) async throws -> SessionRuntimeHandle {
        guard request.provider == provider else {
            throw SessionRuntimeError.unsupportedProvider(request.provider)
        }
        guard FeatureFlags.isEnabled(featureFlag) else {
            throw SessionRuntimeError.runtimeDisabled(provider)
        }
        guard await isAvailable() else {
            throw SessionRuntimeError.runtimeUnavailable(provider)
        }

        let snapshot = try await monitor.startThread(cwd: request.cwd)
        let sessionID = snapshot.threadId
        let handle = SessionRuntimeHandle(
            sessionID: sessionID,
            provider: provider,
            cwd: request.cwd,
            createdAt: Date(),
            resumeToken: sessionID,
            runtimeIdentifier: "native-codex",
            sessionFilePath: snapshot.clientInfo?.sessionFilePath
        )
        activeSessions[sessionID] = handle
        continuation?.yield(.started(handle))
        return handle
    }

    func resumeSession(id: String) async throws -> SessionRuntimeHandle {
        guard FeatureFlags.isEnabled(featureFlag) else {
            throw SessionRuntimeError.runtimeDisabled(provider)
        }
        if let existing = activeSessions[id] {
            return existing
        }

        let snapshot = try await monitor.resumeThread(threadId: id, cwd: nil)
        let handle = SessionRuntimeHandle(
            sessionID: snapshot.threadId,
            provider: provider,
            cwd: snapshot.cwd,
            createdAt: Date(),
            resumeToken: snapshot.threadId,
            runtimeIdentifier: "native-codex",
            sessionFilePath: snapshot.clientInfo?.sessionFilePath
        )
        activeSessions[handle.sessionID] = handle
        continuation?.yield(.started(handle))
        return handle
    }

    func terminateSession(id: String) async throws {
        guard activeSessions.removeValue(forKey: id) != nil else {
            throw SessionRuntimeError.sessionNotFound(id)
        }
        try? await monitor.archiveThread(threadId: id)
        continuation?.yield(.stopped(sessionID: id, reason: .cancelled))
    }

    func approve(sessionId: String, forSession: Bool) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionRuntimeError.sessionNotFound(sessionId)
        }
        await monitor.approve(threadId: sessionId, forSession: forSession)
    }

    func deny(sessionId: String, reason: String?) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionRuntimeError.sessionNotFound(sessionId)
        }
        _ = reason
        await monitor.deny(threadId: sessionId)
    }

    func answer(sessionId: String, answers: [String : [String]]) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionRuntimeError.sessionNotFound(sessionId)
        }
        await monitor.answer(threadId: sessionId, answers: answers)
    }

    func continueSession(sessionId: String, expectedTurnId: String?, text: String) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionRuntimeError.sessionNotFound(sessionId)
        }
        try await monitor.continueThread(
            threadId: sessionId,
            expectedTurnId: expectedTurnId ?? "",
            text: text
        )
    }

    nonisolated private static func resolveCodexExecutable() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
