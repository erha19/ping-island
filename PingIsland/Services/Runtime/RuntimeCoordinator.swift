//
//  RuntimeCoordinator.swift
//  PingIsland
//
//  Lifecycle coordinator for isolated native runtimes.
//

import Foundation
import os.log

protocol RuntimeCoordinating: Sendable {
    func start() async
    func stop() async
    func startSession(
        provider: SessionProvider,
        cwd: String,
        preferredSessionID: String?,
        metadata: [String: String]
    ) async throws -> SessionRuntimeHandle
    func terminateSession(provider: SessionProvider, sessionID: String) async throws
    func sendUserInput(provider: SessionProvider, sessionID: String, text: String) async throws
    func approveSession(provider: SessionProvider, sessionID: String, forSession: Bool) async throws
    func denySession(provider: SessionProvider, sessionID: String, reason: String?) async throws
    func answerSession(provider: SessionProvider, sessionID: String, answers: [String: [String]]) async throws
    func continueSession(provider: SessionProvider, sessionID: String, expectedTurnId: String?, text: String) async throws
    func managesNativeSession(sessionID: String, provider: SessionProvider?) async -> Bool
    func launchPreferredSession(provider: SessionProvider, cwd: String) async throws -> SessionRuntimeHandle
}

actor RuntimeCoordinator {
    static let shared = RuntimeCoordinator()

    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "NativeRuntime")

    private let registry: RuntimeSessionRegistry
    private var runtimes: [SessionProvider: any SessionRuntime] = [:]
    private var listenerTasks: [SessionProvider: Task<Void, Never>] = [:]
    private var started = false

    init(
        registry: RuntimeSessionRegistry = .shared,
        runtimes: [SessionProvider: any SessionRuntime] = [:]
    ) {
        self.registry = registry
        self.runtimes = runtimes
    }

    func start() async {
        guard !started else { return }
        started = true

        if runtimes.isEmpty {
            runtimes[.claude] = await MainActor.run { ClaudeRuntime() }
            runtimes[.codex] = await MainActor.run { CodexRuntime() }
        }

        for flag in RuntimeFeatureFlag.allCases where FeatureFlags.isEnabled(flag) {
            if let provider = provider(for: flag), let runtime = runtimes[provider] {
                if listenerTasks[provider] == nil {
                    let events = await runtime.events
                    listenerTasks[provider] = Task { [weak self] in
                        for await event in events {
                            await self?.handleRuntimeEvent(event)
                        }
                    }
                }
                await runtime.prepare()
                Self.logger.info("Prepared native runtime for \(provider.rawValue, privacy: .public)")
            }
        }
    }

    func stop() async {
        guard started else { return }
        started = false

        for (_, task) in listenerTasks {
            task.cancel()
        }
        listenerTasks.removeAll()

        for (_, runtime) in runtimes {
            await runtime.shutdown()
        }
    }

    func isRuntimeEnabled(for provider: SessionProvider) -> Bool {
        switch provider {
        case .claude:
            return FeatureFlags.nativeClaudeRuntime
        case .codex:
            return FeatureFlags.nativeCodexRuntime
        case .copilot:
            return false
        }
    }

    func isRuntimeAvailable(for provider: SessionProvider) async -> Bool {
        guard let runtime = runtimes[provider] else { return false }
        return await runtime.isAvailable()
    }

    @discardableResult
    func startSession(
        provider: SessionProvider,
        cwd: String,
        preferredSessionID: String? = nil,
        metadata: [String: String] = [:]
    ) async throws -> SessionRuntimeHandle {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }

        let handle = try await runtime.startSession(
            SessionRuntimeLaunchRequest(
                provider: provider,
                cwd: cwd,
                preferredSessionID: preferredSessionID,
                metadata: metadata
            )
        )
        await registry.upsert(handle: handle)
        return handle
    }

    @discardableResult
    func resumeSession(provider: SessionProvider, sessionID: String) async throws -> SessionRuntimeHandle {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }

        let handle = try await runtime.resumeSession(id: sessionID)
        await registry.upsert(handle: handle)
        return handle
    }

    func terminateSession(provider: SessionProvider, sessionID: String) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }

        try await runtime.terminateSession(id: sessionID)
        await registry.remove(sessionID: sessionID)
    }

    func sendUserInput(provider: SessionProvider, sessionID: String, text: String) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        try await runtime.sendUserInput(sessionId: sessionID, text: text)
    }

    func approveSession(provider: SessionProvider, sessionID: String, forSession: Bool) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        try await runtime.approve(sessionId: sessionID, forSession: forSession)
    }

    func denySession(provider: SessionProvider, sessionID: String, reason: String?) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        try await runtime.deny(sessionId: sessionID, reason: reason)
    }

    func answerSession(provider: SessionProvider, sessionID: String, answers: [String: [String]]) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        try await runtime.answer(sessionId: sessionID, answers: answers)
    }

    func continueSession(provider: SessionProvider, sessionID: String, expectedTurnId: String?, text: String) async throws {
        guard let runtime = runtimes[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        try await runtime.continueSession(sessionId: sessionID, expectedTurnId: expectedTurnId, text: text)
    }

    func sessionRecords() async -> [String: RuntimeSessionRecord] {
        await registry.allRecords()
    }

    func managesNativeSession(sessionID: String, provider: SessionProvider? = nil) async -> Bool {
        guard let record = await registry.record(for: sessionID) else {
            return false
        }
        if let provider {
            return record.provider == provider
        }
        return true
    }

    @discardableResult
    func launchPreferredSession(provider: SessionProvider, cwd: String) async throws -> SessionRuntimeHandle {
        try await startSession(provider: provider, cwd: cwd, preferredSessionID: nil, metadata: [:])
    }

    private func handleRuntimeEvent(_ event: SessionRuntimeEvent) async {
        switch event {
        case .started(let handle):
            await registry.upsert(handle: handle)
            await SessionStore.shared.process(.runtimeSessionStarted(handle))
        case .stopped(let sessionID, let reason):
            await registry.remove(sessionID: sessionID)
            await SessionStore.shared.process(.runtimeSessionStopped(sessionId: sessionID, reason: reason))
        case .availabilityChanged(let isAvailable):
            Self.logger.info("Native runtime availability changed: \(isAvailable, privacy: .public)")
        }
    }

    private func provider(for flag: RuntimeFeatureFlag) -> SessionProvider? {
        switch flag {
        case .nativeClaudeRuntime:
            return .claude
        case .nativeCodexRuntime:
            return .codex
        }
    }
}

extension RuntimeCoordinator: RuntimeCoordinating {}
