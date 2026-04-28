//
//  ClaudeRuntime.swift
//  PingIsland
//
//  Isolated native runtime scaffold for Claude sessions.
//

import Foundation

actor ClaudeRuntime: SessionRuntime {
    nonisolated let provider: SessionProvider = .claude
    nonisolated let events: AsyncStream<SessionRuntimeEvent>

    private let featureFlag: RuntimeFeatureFlag = .nativeClaudeRuntime
    private var continuation: AsyncStream<SessionRuntimeEvent>.Continuation?
    private struct ActiveSession {
        let handle: SessionRuntimeHandle
        let process: Process
        let inputPipe: Pipe
        let pollingTask: Task<Void, Never>
        let settingsURL: URL?
    }

    private var activeSessions: [String: ActiveSession] = [:]

    init() {
        var capturedContinuation: AsyncStream<SessionRuntimeEvent>.Continuation?
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func prepare() async {
        continuation?.yield(.availabilityChanged(await isAvailable()))
    }

    func shutdown() async {
        let sessions = activeSessions.values
        activeSessions.removeAll()
        for session in sessions {
            session.pollingTask.cancel()
            session.process.terminate()
            HookInstaller.removeTemporarySettingsFile(at: session.settingsURL)
        }
        continuation?.finish()
    }

    func isAvailable() async -> Bool {
        FeatureFlags.isEnabled(featureFlag) && Self.resolveClaudeExecutable() != nil
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

        let sessionID = request.preferredSessionID ?? UUID().uuidString
        let transcriptPath = JSONLInterruptWatcher.resolveFallbackFilePath(sessionId: sessionID, cwd: request.cwd)
        let executable = Self.resolveClaudeExecutable()!
        let settingsURL = HookInstaller.createTemporarySettingsFile(for: "claude-hooks")
        let (process, inputPipe) = try Self.makeClaudeProcess(
            executable: executable,
            sessionID: sessionID,
            cwd: request.cwd,
            resumeSessionID: request.resumeSessionID,
            settingsURL: settingsURL
        )
        try process.run()

        let handle = SessionRuntimeHandle(
            sessionID: sessionID,
            provider: provider,
            cwd: request.cwd,
            createdAt: Date(),
            resumeToken: request.resumeSessionID,
            runtimeIdentifier: "native-claude",
            sessionFilePath: transcriptPath
        )
        await ConversationParser.shared.resetState(for: sessionID)
        let pollingTask = makePollingTask(sessionID: sessionID, cwd: request.cwd, transcriptPath: transcriptPath)
        activeSessions[sessionID] = ActiveSession(
            handle: handle,
            process: process,
            inputPipe: inputPipe,
            pollingTask: pollingTask,
            settingsURL: settingsURL
        )
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.handleProcessExit(sessionID: sessionID, process: process)
            }
        }
        continuation?.yield(.started(handle))
        return handle
    }

    func resumeSession(id: String) async throws -> SessionRuntimeHandle {
        guard FeatureFlags.isEnabled(featureFlag) else {
            throw SessionRuntimeError.runtimeDisabled(provider)
        }
        if let existing = activeSessions[id]?.handle {
            return existing
        }
        return try await startSession(
            SessionRuntimeLaunchRequest(
                provider: provider,
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                resumeSessionID: id,
                preferredSessionID: id
            )
        )
    }

    func terminateSession(id: String) async throws {
        guard let session = activeSessions.removeValue(forKey: id) else {
            throw SessionRuntimeError.sessionNotFound(id)
        }
        session.pollingTask.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        HookInstaller.removeTemporarySettingsFile(at: session.settingsURL)
        continuation?.yield(.stopped(sessionID: id, reason: .cancelled))
    }

    func sendUserInput(sessionId: String, text: String) async throws {
        guard let session = activeSessions[sessionId] else {
            throw SessionRuntimeError.sessionNotFound(sessionId)
        }

        guard let data = "\(text)\n".data(using: .utf8) else {
            throw SessionRuntimeError.unsupportedOperation("sendUserInputEncoding")
        }

        try session.inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func handleProcessExit(sessionID: String, process: Process) {
        guard let active = activeSessions[sessionID], active.process === process else {
            return
        }

        activeSessions.removeValue(forKey: sessionID)
        active.pollingTask.cancel()
        HookInstaller.removeTemporarySettingsFile(at: active.settingsURL)
        let reason: SessionRuntimeStopReason = process.terminationStatus == 0 ? .finished : .crashed
        continuation?.yield(.stopped(sessionID: sessionID, reason: reason))
    }

    private func makePollingTask(sessionID: String, cwd: String, transcriptPath: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let result = await ConversationParser.shared.parseIncremental(
                    sessionId: sessionID,
                    cwd: cwd,
                    explicitFilePath: transcriptPath
                )

                if result.clearDetected {
                    await SessionStore.shared.process(.clearDetected(sessionId: sessionID))
                }

                if !result.newMessages.isEmpty || result.clearDetected {
                    let payload = FileUpdatePayload(
                        sessionId: sessionID,
                        cwd: cwd,
                        messages: result.newMessages,
                        isIncremental: !result.clearDetected,
                        completedToolIds: result.completedToolIds,
                        toolResults: result.toolResults,
                        structuredResults: result.structuredResults
                    )
                    await SessionStore.shared.process(.fileUpdated(payload))
                }

                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    break
                }
            }
        }
    }

    nonisolated private static func makeClaudeProcess(
        executable: String,
        sessionID: String,
        cwd: String,
        resumeSessionID: String?,
        settingsURL: URL?
    ) throws -> (Process, Pipe) {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        var commandParts: [String] = [
            "cd \(quoteShellArg(cwd))",
            "exec \(quoteShellArg(executable))"
        ]

        if let resumeSessionID, !resumeSessionID.isEmpty {
            commandParts[1] += " --resume \(quoteShellArg(resumeSessionID))"
        } else {
            commandParts[1] += " --session-id \(quoteShellArg(sessionID))"
        }

        if let settingsURL {
            commandParts[1] += " --settings \(quoteShellArg(settingsURL.path))"
        }

        let shellCommand = commandParts.joined(separator: " && ")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", shellCommand]
        return (process, inputPipe)
    }

    nonisolated private static func quoteShellArg(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated static func resolveClaudeExecutable(
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        shellResolver: @escaping @Sendable ([String: String]) -> String? = { environment in
            probeClaudeExecutableFromShell(environment: environment)
        }
    ) -> String? {
        if let explicit = environment["PING_CLAUDE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty,
            isExecutable(explicit) {
            return explicit
        }

        let pathCandidates = environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/claude" } ?? []
        let fixedCandidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]

        if let resolved = (pathCandidates + fixedCandidates).first(where: isExecutable) {
            return resolved
        }

        guard let shellResolved = shellResolver(environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !shellResolved.isEmpty,
            isExecutable(shellResolved) else {
            return nil
        }

        return shellResolved
    }

    nonisolated private static func probeClaudeExecutableFromShell(
        environment: [String: String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", claudeDetectionScript]

        var shellEnvironment = environment
        if let home = environment["HOME"], !home.isEmpty {
            shellEnvironment["HOME"] = home
        }
        process.environment = shellEnvironment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0.hasPrefix("/") })
    }

    nonisolated private static let claudeDetectionScript = """
    if [ -n "${PING_CLAUDE_PATH:-}" ] && [ -x "${PING_CLAUDE_PATH}" ]; then
      printf '%s\n' "${PING_CLAUDE_PATH}"
      exit 0
    fi

    if [ -n "${PATH:-}" ]; then
      found="$(command -v claude 2>/dev/null || true)"
      if [ -n "${found}" ] && [ -x "${found}" ]; then
        printf '%s\n' "${found}"
        exit 0
      fi
    fi

    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "${NVM_DIR}/nvm.sh" ]; then
      . "${NVM_DIR}/nvm.sh" >/dev/null 2>&1
      found="$(command -v claude 2>/dev/null || true)"
      if [ -n "${found}" ] && [ -x "${found}" ]; then
        printf '%s\n' "${found}"
        exit 0
      fi
    fi

    exit 1
    """
}
