import Combine
import CryptoKit
import Darwin
import Foundation
import os.log
import Security

private struct RemoteBridgeInstallationStatus {
    let binaryURL: URL
    let isCurrent: Bool
}

/// Serial, bounded control-frame writes never block the UI actor. The duplicated
/// descriptor belongs to this writer; cancellation stops a partial frame and the
/// connection is discarded rather than continuing a corrupted stream.
nonisolated final class RemoteControlWriter: @unchecked Sendable {
    enum Failure: Error, Equatable { case closed, bufferLimitExceeded, timedOut }
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.remote-control-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int
    private let maximumMessages: Int
    private let timeout: TimeInterval
    private var cancelled = false
    private var pendingBytes = 0
    private var pendingMessages = 0

    init(handle: FileHandle, maximumBytes: Int = 16 * 1_024 * 1_024, maximumMessages: Int = 4_096, timeout: TimeInterval = 5) throws {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumMessages = max(1, maximumMessages)
        self.timeout = max(0.001, timeout)
    }

    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBytes
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                guard data.count <= maximumBytes - pendingBytes, pendingMessages < maximumMessages else {
                    lock.unlock()
                    continuation.resume(throwing: Failure.bufferLimitExceeded)
                    return
                }
                pendingBytes += data.count
                pendingMessages += 1
                lock.unlock()
                queue.async { [self] in
                    let result = Result { try writeFrame(data) }
                    lock.lock()
                    pendingBytes -= data.count
                    pendingMessages -= 1
                    lock.unlock()
                    if case .failure = result { cancel() }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        queue.async { [self] in try? handle.close() }
    }

    private func checkOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw Failure.closed }
    }

    private func writeFrame(_ data: Data) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var offset = 0
        while offset < data.count {
            try checkOpen()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timedOut }
            let count = data.withUnsafeBytes {
                Darwin.write(handle.fileDescriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let result = poll(&descriptor, 1, 50)
                if result < 0, errno != EINTR { throw POSIXError(.EIO) }
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

@MainActor
final class RemoteConnectorManager: ObservableObject {
    static let shared = RemoteConnectorManager()

    @Published private(set) var endpoints: [RemoteEndpoint] = []
    @Published private(set) var runtimeStates: [UUID: RemoteEndpointRuntimeState] = [:]

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Remote")
    private let persistenceKey = "RemoteConnectorManager.endpoints.v1"

    private var eventHandler: (@Sendable (HookEvent) async -> Void)?
    private var codexUsageHandler: (@Sendable (CodexUsageSnapshot) -> Void)?
    private var permissionFailureHandler: (@Sendable (_ sessionId: String, _ toolUseId: String) -> Void)?
    private var connectors: [UUID: RemoteAttachConnector] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var connectionAttempts = RemoteConnectionAttemptRegistry()
    private let processedEvents = RemoteProcessedEventLedger()
    private var pendingRequests = RemotePendingRequestStore()
    private var ephemeralPasswords: [UUID: String] = [:]
    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()
    private let assetResolver = RemoteBridgeAssetResolver()
    private let credentialStore = RemoteEndpointCredentialStore()

    private init() {
        loadPersistedEndpoints()
        observeBridgeRuntimeConfigChanges()
    }

    func start(
        onEvent: @escaping @Sendable (HookEvent) async -> Void,
        onCodexUsage: (@Sendable (CodexUsageSnapshot) -> Void)? = nil,
        onPermissionFailure: (@Sendable (_ sessionId: String, _ toolUseId: String) -> Void)? = nil
    ) {
        eventHandler = onEvent
        codexUsageHandler = onCodexUsage
        permissionFailureHandler = onPermissionFailure

        guard !hasStarted else { return }
        hasStarted = true

        for endpoint in endpoints where shouldAutoReconnectOnStart(endpoint: endpoint) {
            connect(endpointID: endpoint.id, password: nil, forceBootstrap: false)
        }
    }

    func stop() {
        hasStarted = false
        connectionAttempts.invalidateAll()
        for task in reconnectTasks.values {
            task.cancel()
        }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        for connector in connectors.values {
            connector.stop()
        }
        connectors.removeAll()
        pendingRequests.removeAll()
    }

    private func observeBridgeRuntimeConfigChanges() {
        NotificationCenter.default.publisher(for: .bridgeRuntimeConfigDidChange)
            .compactMap { $0.userInfo?["config"] as? BridgeRuntimeConfigSnapshot }
            .removeDuplicates()
            .sink { [weak self] config in
                self?.syncRuntimeConfigToConnectedEndpoints(config: config)
            }
            .store(in: &cancellables)
    }

    private func syncRuntimeConfigToConnectedEndpoints(config: BridgeRuntimeConfigSnapshot) {
        for endpointID in connectors.keys {
            let password = resolvedCredential(for: endpointID, requestedPassword: nil).password
            Task { [weak self] in
                do {
                    try await self?.writeRemoteRuntimeConfig(
                        endpointID: endpointID,
                        password: password,
                        config: config
                    )
                } catch {
                    await MainActor.run {
                        self?.logger.error(
                            "Remote runtime config sync failed endpoint=\(endpointID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    @discardableResult
    func addEndpoint(displayName: String, sshTarget: String, sshPort: Int = RemoteSSHLink.defaultPort) -> RemoteEndpoint {
        let trimmedTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedLink = RemoteSSHLink(sshTarget: trimmedTarget)
        let effectivePort = sshPort == RemoteSSHLink.defaultPort
            ? (parsedLink?.port ?? RemoteSSHLink.defaultPort)
            : sshPort
        let endpoint = RemoteEndpoint(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            sshTarget: parsedLink?.commandTarget ?? trimmedTarget,
            sshPort: effectivePort
        )
        endpoints.append(endpoint)
        persistEndpoints()
        runtimeStates[endpoint.id] = RemoteEndpointRuntimeState()
        return endpoint
    }

    func removeEndpoint(id: UUID) {
        disconnect(endpointID: id)
        endpoints.removeAll { $0.id == id }
        runtimeStates.removeValue(forKey: id)
        ephemeralPasswords.removeValue(forKey: id)
        credentialStore.deletePassword(for: id)
        pendingRequests.removeAll(for: id)
        persistEndpoints()
    }

    func connect(endpointID: UUID, password: String?, forceBootstrap: Bool = false) {
        guard let endpoint = endpoint(for: endpointID) else { return }
        cancelReconnect(endpointID: endpointID, resetAttempt: true)
        let generation = connectionAttempts.begin(endpointID: endpointID, explicit: true)

        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPassword = trimmedPassword?.isEmpty == false ? trimmedPassword : nil
        let credential = resolvedCredential(for: endpointID, requestedPassword: requestedPassword)
        let effectivePassword = credential.password
        logger.notice(
            "Remote connect requested endpoint=\(endpoint.id.uuidString, privacy: .public) title=\(endpoint.resolvedTitle, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) authMode=\(endpoint.authMode.rawValue, privacy: .public) forceBootstrap=\(forceBootstrap, privacy: .public) hasPassword=\(effectivePassword != nil, privacy: .public)"
        )
        setState(
            for: endpointID,
            phase: .probing,
            detail: "正在检测远程主机能力…",
            lastError: nil,
            requiresPassword: effectivePassword == nil && endpoint.authMode == .passwordSession
        )

        Task {
            var stage = "probe"
            do {
                let probe = try await RemoteSSHCommandRunner.probe(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    password: effectivePassword
                )
                await MainActor.run {
                    self.logger.notice(
                        "Remote probe succeeded endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) os=\(probe.operatingSystem, privacy: .public) arch=\(probe.architecture, privacy: .public) home=\(probe.homeDirectory, privacy: .public) hasClaude=\(probe.hasClaude, privacy: .public) hasTmux=\(probe.hasTmux, privacy: .public) fingerprintPresent=\(probe.fingerprint != nil, privacy: .public)"
                    )
                    self.applyProbe(probe, to: endpointID, passwordWasUsed: effectivePassword != nil)
                }

                var shouldBootstrap = await MainActor.run {
                    self.shouldBootstrapRemoteAgent(endpointID: endpointID, forceBootstrap: forceBootstrap)
                }
                var bridgeInstallationStatus: RemoteBridgeInstallationStatus?

                if !shouldBootstrap {
                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "bridge-version-check"
                    do {
                        bridgeInstallationStatus = try await remoteBridgeInstallationStatus(
                            endpointID: endpointID,
                            password: effectivePassword,
                            probe: probe
                        )
                        if bridgeInstallationStatus?.isCurrent == false {
                            shouldBootstrap = true
                            logger.notice(
                                "Remote bridge checksum mismatch endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public); scheduling bootstrap"
                            )
                        }
                    } catch {
                        shouldBootstrap = true
                        logger.error(
                            "Remote bridge version check failed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public); bootstrap required error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                if shouldBootstrap {
                    await MainActor.run {
                        self.setState(
                            for: endpointID,
                            phase: .bootstrapping,
                            detail: AppLocalization.format(
                                "正在安装远程桥接… %@ (%@)",
                                probe.operatingSystem,
                                probe.architecture
                            )
                        )
                    }
                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = forceBootstrap ? "bootstrap-forced" : "bootstrap-required"
                    try await bootstrapRemoteAgent(
                        endpointID: endpointID,
                        password: effectivePassword,
                        probe: probe,
                        installationStatus: bridgeInstallationStatus
                    )
                } else {
                    logger.notice(
                        "Remote bootstrap skipped endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) reason=reuse_existing_install"
                    )
                }

                try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                stage = "runtime-config"
                try await writeRemoteRuntimeConfig(
                    endpointID: endpointID,
                    password: effectivePassword,
                    config: AppSettings.shared.bridgeRuntimeConfigSnapshot
                )

                do {
                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "ensure-remote-agent"
                    try await ensureRemoteAgentRunning(endpointID: endpointID, password: effectivePassword)

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "attach-cleanup-local"
                    try await cleanupLocalAttachProcesses(endpointID: endpointID)

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "attach-cleanup"
                    try await cleanupRemoteAttachProcesses(endpointID: endpointID, password: effectivePassword)

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "attach"
                    try await attach(endpointID: endpointID, password: effectivePassword, generation: generation)
                } catch {
                    guard !shouldBootstrap else {
                        throw error
                    }

                    logger.notice(
                        "Remote reuse failed, retrying bootstrap endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) failedStage=\(stage, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    await MainActor.run {
                        self.setState(
                            for: endpointID,
                            phase: .bootstrapping,
                            detail: AppLocalization.format(
                                "正在安装远程桥接… %@ (%@)",
                                probe.operatingSystem,
                                probe.architecture
                            )
                        )
                    }

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "bootstrap-retry"
                    try await bootstrapRemoteAgent(
                        endpointID: endpointID,
                        password: effectivePassword,
                        probe: probe,
                        installationStatus: bridgeInstallationStatus
                    )

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "runtime-config-retry"
                    try await writeRemoteRuntimeConfig(
                        endpointID: endpointID,
                        password: effectivePassword,
                        config: AppSettings.shared.bridgeRuntimeConfigSnapshot
                    )

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "ensure-remote-agent"
                    try await ensureRemoteAgentRunning(endpointID: endpointID, password: effectivePassword)

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "attach-cleanup"
                    try await cleanupRemoteAttachProcesses(endpointID: endpointID, password: effectivePassword)

                    try checkConnectionAttempt(endpointID: endpointID, generation: generation)
                    stage = "attach"
                    try await attach(endpointID: endpointID, password: effectivePassword, generation: generation)
                }
                await MainActor.run {
                    self.persistCredentialAfterSuccessfulConnection(
                        endpointID: endpointID,
                        password: effectivePassword
                    )
                }
            } catch {
                guard !Task.isCancelled, connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return }
                if suspendAfterAuthenticationFailure(endpointID: endpointID, error: error) { return }
                await MainActor.run {
                    let errorDescription = Self.presentableConnectionError(
                        stage: stage,
                        errorDescription: error.localizedDescription
                    )
                    self.handleConnectionFailure(
                        endpointID: endpointID,
                        credentialSource: credential.source
                    )
                    self.logger.error(
                        "Remote connect failed endpoint=\(endpoint.id.uuidString, privacy: .public) title=\(endpoint.resolvedTitle, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) stage=\(stage, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.setState(
                        for: endpointID,
                        phase: .failed,
                        detail: Self.connectionFailureDetail(for: stage),
                        lastError: errorDescription,
                        requiresPassword: shouldRequirePasswordAfterConnectionFailure(
                            endpointID: endpointID,
                            credentialSource: credential.source
                        )
                    )
                    self.scheduleReconnect(endpointID: endpointID)
                }
            }
        }
    }

    func disconnect(endpointID: UUID) {
        stopLocalConnection(
            endpointID: endpointID,
            updateState: true,
            detail: "已断开远程转发连接"
        )
    }

    func uninstallBridge(endpointID: UUID, password: String?) {
        guard let endpoint = endpoint(for: endpointID) else { return }

        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPassword = trimmedPassword?.isEmpty == false ? trimmedPassword : nil
        let credential = resolvedCredential(for: endpointID, requestedPassword: requestedPassword)
        let effectivePassword = credential.password

        logger.notice(
            "Remote bridge uninstall requested endpoint=\(endpoint.id.uuidString, privacy: .public) title=\(endpoint.resolvedTitle, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) authMode=\(endpoint.authMode.rawValue, privacy: .public) hasPassword=\(effectivePassword != nil, privacy: .public)"
        )
        setState(
            for: endpointID,
            phase: .uninstalling,
            detail: "正在卸载远程 bridge…",
            lastError: nil,
            requiresPassword: effectivePassword == nil && endpoint.authMode == .passwordSession
        )
        stopLocalConnection(endpointID: endpointID, updateState: false)

        Task {
            var stage = "probe"
            do {
                let probe = try await RemoteSSHCommandRunner.probe(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    password: effectivePassword
                )
                await MainActor.run {
                    self.applyProbe(probe, to: endpointID, passwordWasUsed: effectivePassword != nil)
                }

                stage = "attach-cleanup-local"
                try await cleanupLocalAttachProcesses(endpointID: endpointID)

                stage = "attach-cleanup-remote"
                try await cleanupRemoteAttachProcesses(endpointID: endpointID, password: effectivePassword)

                stage = "uninstall"
                try await uninstallRemoteAgent(endpointID: endpointID, password: effectivePassword, probe: probe)

                await MainActor.run {
                    self.clearUninstalledRemoteAgentMetadata(endpointID: endpointID)
                    self.setState(
                        for: endpointID,
                        phase: .disconnected,
                        detail: "远程 bridge 已卸载",
                        lastError: nil,
                        requiresPassword: false,
                        agentVersion: nil
                    )
                }
            } catch {
                await MainActor.run {
                    let errorDescription = stage == "probe"
                        ? Self.presentableConnectionError(
                            stage: stage,
                            errorDescription: error.localizedDescription
                        )
                        : error.localizedDescription
                    self.handleConnectionFailure(
                        endpointID: endpointID,
                        credentialSource: credential.source
                    )
                    self.logger.error(
                        "Remote bridge uninstall failed endpoint=\(endpoint.id.uuidString, privacy: .public) title=\(endpoint.resolvedTitle, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) stage=\(stage, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.setState(
                        for: endpointID,
                        phase: .failed,
                        detail: "远程卸载失败",
                        lastError: errorDescription,
                        requiresPassword: self.shouldRequirePasswordAfterConnectionFailure(
                            endpointID: endpointID,
                            credentialSource: credential.source
                        )
                    )
                }
            }
        }
    }

    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        let requests = self.pendingRequests.removeAll(for: toolUseId)
        guard !requests.isEmpty else {
            return
        }

        for pending in requests {
            guard let connector = connectors[pending.endpointID] else {
                permissionFailureHandler?(pending.sessionID, toolUseId)
                continue
            }

            Task {
                do {
                    try await connector.sendDecision(
                        requestID: pending.requestID,
                        decision: decision,
                        reason: reason,
                        updatedInput: nil
                    )
                } catch {
                    await MainActor.run {
                        self.permissionFailureHandler?(pending.sessionID, toolUseId)
                    }
                }
            }
        }
    }

    func respondToIntervention(
        toolUseId: String,
        decision: String,
        updatedInput: [String: Any]?,
        reason: String? = nil
    ) {
        let requests = self.pendingRequests.removeAll(for: toolUseId)
        guard !requests.isEmpty else {
            return
        }

        let encodedInput = updatedInput?.mapValues { RemoteJSONValue.fromFoundationObject($0) }
        for pending in requests {
            guard let connector = connectors[pending.endpointID] else {
                permissionFailureHandler?(pending.sessionID, toolUseId)
                continue
            }

            Task {
                do {
                    try await connector.sendDecision(
                        requestID: pending.requestID,
                        decision: decision,
                        reason: reason,
                        updatedInput: encodedInput
                    )
                } catch {
                    await MainActor.run {
                        self.permissionFailureHandler?(pending.sessionID, toolUseId)
                    }
                }
            }
        }
    }

    private func attach(endpointID: UUID, password: String?, generation: UUID) async throws {
        try checkConnectionAttempt(endpointID: endpointID, generation: generation)
        guard let endpoint = endpoint(for: endpointID) else { return }

        connectors.removeValue(forKey: endpointID)?.stop()
        logger.notice(
            "Remote attach starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
        setState(for: endpointID, phase: .connecting, detail: "正在建立远程转发通道…")

        let connector = RemoteAttachConnector(
            endpoint: endpoint,
            password: password,
            onMessage: { [weak self] message in
                await self?.handle(message: message, endpointID: endpointID, generation: generation)
            },
            onDisconnect: { [weak self] error in
                guard let manager = self else { return }
                Task { @MainActor in
                    guard manager.connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return }
                    manager.handleDisconnect(endpointID: endpointID, error: error)
                }
            }
        )

        try await connector.start()
        do { try checkConnectionAttempt(endpointID: endpointID, generation: generation) }
        catch { connector.stop(); throw error }
        connectors[endpointID] = connector
        setState(
            for: endpointID,
            phase: .connected,
            detail: "远程转发已连接",
            agentVersion: endpoint.agentVersion
        )
        logger.notice(
            "Remote attach connected endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )
    }

    private func writeRemoteRuntimeConfig(
        endpointID: UUID,
        password: String?,
        config: BridgeRuntimeConfigSnapshot
    ) async throws {
        guard let endpoint = endpoint(for: endpointID),
              let data = BridgeRuntimeConfigWriter.payloadData(config) else {
            return
        }

        let remotePath = Self.remoteBridgeRuntimeConfigPath(installRoot: endpoint.remoteInstallRoot)
        try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: remotePath,
            contents: data,
            password: password
        )
        try await writeRemoteBridgeLauncher(endpoint: endpoint, password: password)
        logger.debug(
            "Remote runtime config synced endpoint=\(endpoint.id.uuidString, privacy: .public) routePromptsToTerminal=\(config.routePromptsToTerminal, privacy: .public) debugLoggingEnabled=\(config.debugLoggingEnabled, privacy: .public)"
        )
    }

    private func writeRemoteBridgeLauncher(endpoint: RemoteEndpoint, password: String?) async throws {
        let launcherPath = "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge"
        try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: launcherPath,
            contents: Self.remoteBridgeLauncherScript().data(using: .utf8) ?? Data(),
            password: password
        )
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: "chmod 755 \(Self.shellQuote(launcherPath))",
            acceptNewHostKey: true
        )
    }

    private func cleanupRemoteAttachProcesses(endpointID: UUID, password: String?) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: """
            pkill -f \(quoted("\(endpoint.remoteInstallRoot)/bin/[P]ingIslandBridge --mode remote-agent-attach")) >/dev/null 2>&1 || true
            """,
            acceptNewHostKey: true
        )
        logger.debug(
            "Remote attach cleanup completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )
    }

    private func stopLocalConnection(
        endpointID: UUID,
        updateState: Bool,
        detail: String = "已断开远程转发连接"
    ) {
        connectionAttempts.invalidate(endpointID: endpointID)
        cancelReconnect(endpointID: endpointID, resetAttempt: true)
        connectors.removeValue(forKey: endpointID)?.stop()
        pendingRequests.removeAll(for: endpointID)
        let remoteHost = Self.resolvedRemoteHostHint(
            payloadRemoteHost: nil,
            endpoint: endpoint(for: endpointID)
        )
        Task {
            await SessionStore.shared.markRemoteSessionsDisconnected(
                endpointID: endpointID,
                legacyRemoteHost: remoteHost
            )
        }
        if updateState {
            setState(for: endpointID, phase: .disconnected, detail: detail)
        }
    }

    private func cleanupLocalAttachProcesses(endpointID: UUID) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }

        let escapedTarget = NSRegularExpression.escapedPattern(for: endpoint.sshCommandTarget)
        let escapedControlSocket = NSRegularExpression.escapedPattern(for: endpoint.remoteControlSocketPath)
        let portFragment = endpoint.sshPort == RemoteSSHLink.defaultPort ? "" : ".*-p\\s+\(endpoint.sshPort)"
        let pattern = "ssh\(portFragment) .*\(escapedTarget).*(remote-agent-attach|--mode remote-agent-attach).*\(escapedControlSocket)"

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]

        let outputPipe = Pipe()
        pgrep.standardOutput = outputPipe
        pgrep.standardError = Pipe()

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            logger.error(
                "Local attach cleanup failed to enumerate endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }

        guard !pids.isEmpty else { return }

        let currentPID = Foundation.ProcessInfo.processInfo.processIdentifier
        for pid in pids where pid != currentPID {
            kill(pid, SIGTERM)
        }
        logger.debug(
            "Local attach cleanup completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) removedCount=\(pids.filter { $0 != currentPID }.count, privacy: .public)"
        )
    }

    private func handle(message: RemoteInboundMessage, endpointID: UUID, generation: UUID) async {
        guard connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return }
        switch message {
        case .hello(let hello):
            reconnectAttempts.removeValue(forKey: endpointID)
            logger.notice(
                "Remote daemon hello endpoint=\(endpointID.uuidString, privacy: .public) hostname=\(hello.hostname, privacy: .public) version=\(hello.version, privacy: .public)"
            )
            if var currentEndpoint = endpoint(for: endpointID) {
                currentEndpoint.agentVersion = hello.version
                currentEndpoint.lastConnectedAt = Date()
                updateEndpoint(currentEndpoint)
            }
            setState(for: endpointID, phase: .connected, detail: "远程转发已连接", agentVersion: hello.version)

        case .codexUsage(let usageMessage):
            let endpoint = endpoint(for: endpointID)
            let remoteSource = Self.remoteUsageSourcePath(
                usageMessage.payload.sourceFilePath,
                endpoint: endpoint
            )
            let snapshot = CodexUsageSnapshot(
                sourceFilePath: remoteSource,
                capturedAt: usageMessage.payload.capturedAt,
                planType: usageMessage.payload.planType,
                limitID: usageMessage.payload.limitID,
                tokenUsage: usageMessage.payload.tokenUsage,
                windows: usageMessage.payload.windows
            )
            codexUsageHandler?(snapshot)

        case .hookEvent(let eventMessage):
            // Keep ACKs tied to the connection which delivered this event, even
            // when ingestion suspends long enough for a reconnect.
            let connector = connectors[endpointID]
            let payload = eventMessage.payload
            if payload.expectsResponse,
               CodexAutomaticApprovalReviewResolver.shouldDeferToCodex(
                   provider: payload.provider,
                   eventType: payload.event,
                   metadata: [
                       "approvals_reviewer": payload.approvalsReviewer ?? "",
                       "permission_mode": payload.permissionMode ?? ""
                   ]
               ) {
                // A nil-decision response releases the remote hook and lets
                // Codex run its own automatic reviewer.
                if let connector = connectors[endpointID] {
                    do {
                        try await connector.sendDecision(
                            requestID: payload.requestID,
                            decision: "defer",
                            reason: nil,
                            updatedInput: nil
                        )
                    } catch {
                        logger.error("Failed to defer remote Codex review: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return
            }
            guard let provider = SessionProvider(rawValue: payload.provider) else {
                try? await Self.deliverRemoteHookEvent(nil, onEvent: eventHandler) {
                    try await connector?.acknowledgeIgnoredEvent(payload)
                }
                return
            }
            if payload.expectsResponse,
               let decision = Self.immediateRemoteCodexPermissionDecision(
                   provider: payload.provider,
                   eventType: payload.event,
                   permissionMode: payload.permissionMode
               ) {
                // Only an explicit bypassPermissions PermissionRequest may be
                // approved without asking the user.
                await Self.deliverImmediatePermissionResponse(
                    requestID: payload.requestID, decision: decision, connector: connector
                ) { error in
                    logger.error(
                        "Failed to send immediate remote Codex response session=\(payload.sessionID.prefix(8), privacy: .public) endpoint=\(endpointID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                return
            }
            let resolvedToolUseID = Self.resolvedRemoteToolUseID(
                toolUseID: payload.toolUseID,
                expectsResponse: payload.expectsResponse,
                requestID: payload.requestID
            )
            let resolvedRemoteHost = Self.resolvedRemoteHostHint(
                payloadRemoteHost: payload.clientInfo.remoteHost,
                endpoint: endpoint(for: endpointID)
            )
            let clientInfo = SessionClientInfo(
                kind: SessionClientKind(rawValue: payload.clientInfo.kind) ?? .custom,
                profileID: payload.clientInfo.profileID,
                name: payload.clientInfo.name,
                bundleIdentifier: payload.clientInfo.bundleIdentifier,
                launchURL: payload.clientInfo.launchURL,
                origin: payload.clientInfo.origin,
                originator: payload.clientInfo.originator,
                threadSource: payload.clientInfo.threadSource,
                transport: payload.clientInfo.transport,
                remoteHost: resolvedRemoteHost,
                remoteEndpointID: endpointID,
                sessionFilePath: payload.clientInfo.sessionFilePath,
                terminalBundleIdentifier: payload.clientInfo.terminalBundleIdentifier,
                terminalProgram: payload.clientInfo.terminalProgram,
                terminalSessionIdentifier: payload.clientInfo.terminalSessionIdentifier,
                iTermSessionIdentifier: payload.clientInfo.iTermSessionIdentifier,
                tmuxSessionIdentifier: payload.clientInfo.tmuxSessionIdentifier,
                tmuxPaneIdentifier: payload.clientInfo.tmuxPaneIdentifier,
                processName: payload.clientInfo.processName
            )

            let event = HookEvent(
                sessionId: payload.sessionID,
                cwd: payload.cwd,
                event: payload.event,
                status: payload.status,
                provider: provider,
                clientInfo: clientInfo,
                pid: payload.pid,
                tty: payload.tty,
                tool: payload.tool,
                toolInput: payload.toolInput?.mapValues { AnyCodable($0.foundationObject) },
                toolUseId: resolvedToolUseID,
                notificationType: payload.notificationType,
                message: payload.message,
                ingress: .remoteBridge,
                bridgeExpectsResponse: payload.expectsResponse,
                codexBypassPermissions: Self.isRemoteCodexBypassPermissionRequest(
                    provider: payload.provider, eventType: payload.event, permissionMode: payload.permissionMode
                )
            )

            if event.shouldFilterBeforeApprovalHandling {
                try? await Self.deliverRemoteHookEvent(event, onEvent: eventHandler) {
                    try await connector?.acknowledgeIgnoredEvent(payload)
                }
                return
            }
            guard let eventHandler else { return }

            let processed = await processedEvents.processOnce(
                endpointID: endpointID, requestID: payload.requestID,
                isCurrent: { [self] in connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) }
            ) { [self] in
                guard connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return false }
                if payload.expectsResponse, let toolUseID = resolvedToolUseID {
                    pendingRequests.append(PendingRemoteRequest(
                        endpointID: endpointID,
                        requestID: payload.requestID,
                        sessionID: payload.sessionID
                    ), for: toolUseID)
                }
                await eventHandler(event)
                return true
            }
            guard processed, connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return }
            // A lost ACK may replay after reconnect. Re-ACK the request without
            // repeating state transitions, sounds, or pending-intervention inserts.
            try? await connector?.sendAcknowledgement(requestID: payload.requestID)
        }
    }

    static func deliverImmediatePermissionResponse(
        requestID: UUID,
        decision: String,
        connector: RemoteAttachConnector?,
        onFailure: (Error) -> Void
    ) async {
        do {
            try await connector?.sendDecision(requestID: requestID, decision: decision, reason: nil, updatedInput: nil)
        } catch {
            // The transport owns disconnect notification. In particular, EPIPE
            // waits for SSH's termination/authentication result; stopping/removing
            // the connector here would suppress that callback and its reconnect.
            onFailure(error)
        }
    }

    /// A processed-event ACK means ingestion completed, not merely that a Task
    /// was scheduled. Unknown/filtered events are acknowledged too so they do
    /// not poison the durable replay queue. Missing handlers remain retryable.
    static func deliverRemoteHookEvent(
        _ event: HookEvent?,
        onEvent: (@Sendable (HookEvent) async -> Void)?,
        acknowledge: () async throws -> Void
    ) async rethrows {
        if let event, !event.shouldFilterBeforeApprovalHandling {
            guard let onEvent else { return }
            await onEvent(event)
        }
        try await acknowledge()
    }

    nonisolated static func remoteUsageSourcePath(
        _ sourceFilePath: String,
        endpoint: RemoteEndpoint?
    ) -> String {
        guard let endpoint else { return sourceFilePath }
        let prefix = endpoint.sshURL?.absoluteString ?? "ssh://\(endpoint.sshDisplayTarget)"
        let separator = sourceFilePath.hasPrefix("/") ? "" : "/"
        return "\(prefix)\(separator)\(sourceFilePath)"
    }

    private func suspendAfterAuthenticationFailure(endpointID: UUID, error: Error) -> Bool {
        guard let failure = error as? RemoteConnectorError, case .authenticationRejected = failure else { return false }
        connectionAttempts.suspendAfterAuthenticationRejection(endpointID: endpointID)
        cancelReconnect(endpointID: endpointID, resetAttempt: true)
        connectors.removeValue(forKey: endpointID)?.stop()
        pendingRequests.removeAll(for: endpointID)
        ephemeralPasswords.removeValue(forKey: endpointID)
        credentialStore.deletePassword(for: endpointID)
        setState(for: endpointID, phase: .failed, detail: failure.localizedDescription,
                 lastError: failure.localizedDescription, requiresPassword: true)
        logger.notice("Remote automatic reconnect suspended after authentication rejection endpoint=\(endpointID.uuidString, privacy: .public)")
        return true
    }

    private func handleDisconnect(endpointID: UUID, error: Error?) {
        connectors.removeValue(forKey: endpointID)
        pendingRequests.removeAll(for: endpointID)
        let remoteHost = Self.resolvedRemoteHostHint(
            payloadRemoteHost: nil, endpoint: endpoint(for: endpointID)
        )
        Task {
            await SessionStore.shared.markRemoteSessionsDisconnected(
                endpointID: endpointID, legacyRemoteHost: remoteHost
            )
        }
        if let error, suspendAfterAuthenticationFailure(endpointID: endpointID, error: error) { return }
        logger.error(
            "Remote attach disconnected endpoint=\(endpointID.uuidString, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)"
        )
        setState(
            for: endpointID,
            phase: .degraded,
            detail: "远程转发已断开",
            lastError: error?.localizedDescription,
            requiresPassword: endpoint(for: endpointID)?.authMode == .passwordSession
        )
        scheduleReconnect(endpointID: endpointID)
    }

    private func scheduleReconnect(endpointID: UUID) {
        guard hasStarted,
              connectionAttempts.allowsAutomaticRetry(endpointID: endpointID),
              reconnectTasks[endpointID] == nil,
              let endpoint = endpoint(for: endpointID),
              shouldAutoReconnectOnStart(endpoint: endpoint) else {
            return
        }

        let attempt = (reconnectAttempts[endpointID] ?? 0) + 1
        reconnectAttempts[endpointID] = attempt
        let delay = Self.runtimeReconnectDelaySeconds(forAttempt: attempt)
        logger.notice(
            "Remote reconnect scheduled endpoint=\(endpointID.uuidString, privacy: .public) attempt=\(attempt, privacy: .public) delay=\(delay, privacy: .public)s"
        )
        setState(
            for: endpointID,
            phase: .degraded,
            detail: AppLocalization.format("远程转发已断开，%.0f 秒后自动重连…", delay),
            requiresPassword: false
        )

        let generation = connectionAttempts.begin(endpointID: endpointID)
        reconnectTasks[endpointID] = Task { [weak self] in
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect(endpointID: endpointID, generation: generation)
        }
    }

    private func attemptReconnect(endpointID: UUID, generation: UUID) async {
        defer {
            if connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) {
                reconnectTasks.removeValue(forKey: endpointID)
            }
        }
        guard hasStarted,
              connectionAttempts.isCurrent(endpointID: endpointID, generation: generation),
              let endpoint = endpoint(for: endpointID),
              shouldAutoReconnectOnStart(endpoint: endpoint) else { return }

        let credential = resolvedCredential(for: endpointID, requestedPassword: nil)
        let password = credential.password
        setState(for: endpointID, phase: .connecting,
                 detail: AppLocalization.string("正在自动重连远程转发…"), lastError: nil, requiresPassword: false)
        do {
            try await Self.runConnectionSteps([
                { try await self.ensureRemoteAgentRunning(endpointID: endpointID, password: password) },
                { try await self.cleanupLocalAttachProcesses(endpointID: endpointID) },
                { try await self.cleanupRemoteAttachProcesses(endpointID: endpointID, password: password) },
                { try await self.attach(endpointID: endpointID, password: password, generation: generation) }
            ], isCurrent: {
                self.hasStarted && self.connectionAttempts.isCurrent(endpointID: endpointID, generation: generation)
            })
        } catch {
            guard hasStarted, !Task.isCancelled,
                  connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else { return }
            if suspendAfterAuthenticationFailure(endpointID: endpointID, error: error) { return }
            logger.error("Remote reconnect failed endpoint=\(endpointID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            setState(for: endpointID, phase: .degraded,
                     detail: AppLocalization.string("远程自动重连失败"), lastError: error.localizedDescription,
                     requiresPassword: endpoint.authMode == .passwordSession && password == nil)
            // The attempt is finished now, not before its first await.
            reconnectTasks.removeValue(forKey: endpointID)
            scheduleReconnect(endpointID: endpointID)
        }
    }

    private func checkConnectionAttempt(endpointID: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard connectionAttempts.isCurrent(endpointID: endpointID, generation: generation) else {
            throw CancellationError()
        }
    }

    static func runConnectionSteps(
        _ steps: [() async throws -> Void], isCurrent: () -> Bool
    ) async throws {
        for step in steps {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await step()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
    }

    private func cancelReconnect(endpointID: UUID, resetAttempt: Bool) {
        reconnectTasks.removeValue(forKey: endpointID)?.cancel()
        if resetAttempt {
            reconnectAttempts.removeValue(forKey: endpointID)
        }
    }

    private func applyProbe(_ probe: RemoteHostProbe, to endpointID: UUID, passwordWasUsed: Bool) {
        guard var endpoint = endpoint(for: endpointID) else { return }
        endpoint.detectedUsername = probe.username
        endpoint.detectedHostname = probe.hostname
        endpoint.detectedHomeDirectory = probe.homeDirectory
        endpoint.hostFingerprint = probe.fingerprint
        endpoint.authMode = passwordWasUsed ? .passwordSession : .publicKey
        endpoint.remoteInstallRoot = resolvedRemotePath(endpoint.remoteInstallRoot, homeDirectory: probe.homeDirectory)
        endpoint.remoteHookSocketPath = resolvedRemotePath(endpoint.remoteHookSocketPath, homeDirectory: probe.homeDirectory)
        endpoint.remoteControlSocketPath = resolvedRemotePath(endpoint.remoteControlSocketPath, homeDirectory: probe.homeDirectory)
        updateEndpoint(endpoint)
        logger.debug(
            "Remote probe applied endpoint=\(endpoint.id.uuidString, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public) hookSocket=\(endpoint.remoteHookSocketPath, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
    }

    private func remoteBridgeInstallationStatus(
        endpointID: UUID,
        password: String?,
        probe: RemoteHostProbe
    ) async throws -> RemoteBridgeInstallationStatus? {
        guard let endpoint = endpoint(for: endpointID) else { return nil }
        let bridgeBinaryURL = try await assetResolver.resolveBinaryURL(for: probe)
        let bridgeBinaryPath = "\(endpoint.remoteInstallRoot)/bin/PingIslandBridge"
        let launcherPath = "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge"
        let bridgeExists = (try? await RemoteSSHCommandRunner.remoteFileExists(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: bridgeBinaryPath,
            password: password
        )) ?? false
        let launcherExists = (try? await RemoteSSHCommandRunner.remoteFileExists(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: launcherPath,
            password: password
        )) ?? false
        let localBridgeChecksum = try Self.sha256Hex(of: bridgeBinaryURL)
        let remoteBridgeChecksum: String? = if bridgeExists {
            try? await RemoteSSHCommandRunner.runSSH(
                target: endpoint.sshTarget,
                port: endpoint.sshPort,
                password: password,
                remoteCommand: Self.remoteBridgeChecksumCommand(path: bridgeBinaryPath),
                acceptNewHostKey: true
            ).stdout
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init)
        } else {
            nil
        }
        return RemoteBridgeInstallationStatus(
            binaryURL: bridgeBinaryURL,
            isCurrent: Self.isRemoteBridgeInstallationCurrent(
                bridgeExists: bridgeExists,
                launcherExists: launcherExists,
                localChecksum: localBridgeChecksum,
                remoteChecksum: remoteBridgeChecksum
            )
        )
    }

    private func bootstrapRemoteAgent(
        endpointID: UUID,
        password: String?,
        probe: RemoteHostProbe,
        installationStatus: RemoteBridgeInstallationStatus? = nil
    ) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let resolvedInstallationStatus: RemoteBridgeInstallationStatus
        if let installationStatus {
            resolvedInstallationStatus = installationStatus
        } else {
            guard let status = try await remoteBridgeInstallationStatus(
                endpointID: endpointID,
                password: password,
                probe: probe
            ) else {
                return
            }
            resolvedInstallationStatus = status
        }
        let bridgeBinaryURL = resolvedInstallationStatus.binaryURL
        let bridgeAlreadyInstalled = resolvedInstallationStatus.isCurrent
        let stagedBridgePath = "\(endpoint.remoteInstallRoot)/bin/PingIslandBridge.tmp"
        let bridgeBinaryPath = "\(endpoint.remoteInstallRoot)/bin/PingIslandBridge"
        let launcherPath = "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge"
        let remoteHookProfiles = Self.remoteManagedHookProfiles()
        logger.notice(
            "Remote bootstrap starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) binary=\(bridgeBinaryURL.path, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public)"
        )
        guard remoteHookProfiles.contains(where: { $0.id == "claude-hooks" }) else {
            throw RemoteConnectorError.missingClaudeHookProfile
        }

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteBootstrapPrepareCommand(
                installRoot: endpoint.remoteInstallRoot,
                controlSocketPath: endpoint.remoteControlSocketPath,
                hookSocketPath: endpoint.remoteHookSocketPath,
                homeDirectory: probe.homeDirectory,
                configDirectoryPaths: Self.remoteManagedHookConfigDirectoryPaths(
                    homeDirectory: probe.homeDirectory,
                    profiles: remoteHookProfiles
                )
            ),
            acceptNewHostKey: true
        )
        logger.debug(
            "Remote bootstrap prepared directories and stopped stale agent endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )

        if bridgeAlreadyInstalled {
            logger.notice(
                "Remote bootstrap skipped SCP — bridge checksum matches at \(bridgeBinaryPath, privacy: .public)"
            )
        } else {
            do {
                try await RemoteSSHCommandRunner.copyFile(
                    localURL: bridgeBinaryURL,
                    remoteTarget: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: stagedBridgePath,
                    password: password
                )
            } catch {
                let arch = RemoteConnectorManager.normalizedLinuxBridgeArchitecture(probe.architecture) ?? probe.architecture
                let manualHint = """
                SCP 传输失败，请在远程主机上手动安装 PingIslandBridge：
                
                  mkdir -p \(endpoint.remoteInstallRoot)/bin
                  curl -L -o /tmp/bridge.zip https://github.com/erha19/ping-island/releases/latest/download/PingIslandBridge-linux-musl-\(arch).zip
                  unzip -o /tmp/bridge.zip -d \(endpoint.remoteInstallRoot)/bin/
                  chmod 755 \(endpoint.remoteInstallRoot)/bin/PingIslandBridge
                
                安装完成后重新连接即可。
                """
                logger.error("Remote bootstrap SCP failed: \(error.localizedDescription, privacy: .public)")
                throw RemoteConnectorError.sshFailure(manualHint)
            }
            logger.debug(
                "Remote bootstrap copied staged bridge endpoint=\(endpoint.id.uuidString, privacy: .public) remotePath=\(stagedBridgePath, privacy: .public)"
            )

            try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                target: endpoint.sshTarget,
                port: endpoint.sshPort,
                remotePath: launcherPath,
                contents: Self.remoteBridgeLauncherScript().data(using: .utf8) ?? Data(),
                password: password
            )
            _ = try await RemoteSSHCommandRunner.runSSH(
                target: endpoint.sshTarget,
                port: endpoint.sshPort,
                password: password,
                remoteCommand: Self.remoteBootstrapInstallCommand(
                    installRoot: endpoint.remoteInstallRoot,
                    stagedBridgePath: stagedBridgePath
                ),
                acceptNewHostKey: true
            )
        }
        try await writeRemoteBridgeLauncher(endpoint: endpoint, password: password)
        logger.debug(
            "Remote bootstrap binary ready endpoint=\(endpoint.id.uuidString, privacy: .public)"
        )

        for profile in remoteHookProfiles {
            let remoteCommand = HookInstaller.managedBridgeCommand(
                source: profile.bridgeSource,
                extraArguments: profile.bridgeExtraArguments,
                launcherPath: "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge",
                socketPath: endpoint.remoteHookSocketPath
            )
            switch profile.installationKind {
            case .jsonHooks:
                let remoteConfigPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let existingConfig = try? await RemoteSSHCommandRunner.readRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                let updatedData = HookInstaller.updatedConfigurationData(
                    existingData: existingConfig?.isEmpty == true ? nil : existingConfig,
                    profile: profile,
                    customCommand: remoteCommand,
                    installing: true,
                    removingCommandPrefixes: ["/Users/"]
                )
                logger.debug(
                    "Remote bootstrap preparing hook config endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteConfigPath, privacy: .public) hasExistingConfig=\(existingConfig?.isEmpty == false, privacy: .public) updatedConfigBytes=\(updatedData.count, privacy: .public)"
                )
                try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    contents: updatedData,
                    password: password
                )
            case .hookDirectory:
                let remoteDirectoryPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let remoteBridgeArguments = Self.remoteManagedBridgeArguments(
                    for: profile,
                    installRoot: endpoint.remoteInstallRoot
                )
                let remoteFiles = HookInstaller.managedHookDirectoryFiles(
                    for: profile,
                    bridgeArguments: remoteBridgeArguments,
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: endpoint.remoteHookSocketPath
                    )
                )
                logger.debug(
                    "Remote bootstrap preparing hook directory endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteDirectoryPath, privacy: .public) fileCount=\(remoteFiles.count, privacy: .public)"
                )
                for (name, content) in remoteFiles {
                    try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: "\(remoteDirectoryPath)/\(name)",
                        contents: Data(content.utf8),
                        password: password
                    )
                }

                if let activationPath = profile.activationConfigurationRelativePath,
                   let entryName = profile.activationEntryName {
                    let remoteActivationPath = Self.remoteConfigurationPath(
                        relativePath: activationPath,
                        homeDirectory: probe.homeDirectory
                    )
                    let existingActivationConfig = try? await RemoteSSHCommandRunner.readRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        password: password
                    )
                    let updatedActivationData = HookInstaller.updatedInternalHookConfigurationData(
                        existingData: existingActivationConfig?.isEmpty == true ? nil : existingActivationConfig,
                        entryName: entryName,
                        installing: true
                    )
                    try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        contents: updatedActivationData,
                        password: password
                    )
                }
            case .pluginDirectory:
                let remoteDirectoryPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let remoteFiles = HookInstaller.managedPluginDirectoryFiles(
                    for: profile,
                    bridgeArguments: Self.remoteManagedBridgeArguments(
                        for: profile,
                        installRoot: endpoint.remoteInstallRoot
                    ),
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: endpoint.remoteHookSocketPath
                    )
                )
                logger.debug(
                    "Remote bootstrap preparing plugin directory endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteDirectoryPath, privacy: .public) fileCount=\(remoteFiles.count, privacy: .public)"
                )
                for (name, content) in remoteFiles {
                    try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: "\(remoteDirectoryPath)/\(name)",
                        contents: Data(content.utf8),
                        password: password
                    )
                }
            case .tomlHooks:
                let remoteConfigPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let existingConfig = try? await RemoteSSHCommandRunner.readRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                let existingContent = String(data: existingConfig ?? Data(), encoding: .utf8) ?? ""
                let segments = TOMLHookConfigParser.parse(existingContent)
                let newHooks = profile.events.map { event -> TOMLHookConfigParser.TOMLHookEntry in
                    let matcher = event.templates.first.map { template -> String in
                        switch template {
                        case .plain, .direct: return ""
                        case .matcher(let value): return value
                        }
                    } ?? ""
                    return TOMLHookConfigParser.TOMLHookEntry(
                        event: event.name,
                        command: remoteCommand,
                        matcher: matcher,
                        timeout: event.timeout
                    )
                }
                let updatedContent = TOMLHookConfigParser.rebuild(segments: segments, newHooks: newHooks)
                try await RemoteSSHCommandRunner.writeRemoteFileViaSSH(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    contents: Data(updatedContent.utf8),
                    password: password
                )
            case .pluginFile:
                continue
            }
        }
        logger.notice(
            "Remote bootstrap completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )

        if var refreshed = self.endpoint(for: endpointID) {
            refreshed.lastBootstrapAt = Date()
            updateEndpoint(refreshed)
        }
    }

    nonisolated static func remoteBridgeChecksumCommand(path: String) -> String {
        let quotedPath = shellQuote(path)
        return "if command -v sha256sum >/dev/null 2>&1; then sha256sum \(quotedPath); else shasum -a 256 \(quotedPath); fi"
    }

    nonisolated static func isRemoteBridgeInstallationCurrent(
        bridgeExists: Bool,
        launcherExists: Bool,
        localChecksum: String,
        remoteChecksum: String?
    ) -> Bool {
        bridgeExists
            && launcherExists
            && remoteChecksum == localChecksum
    }

    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func uninstallRemoteAgent(endpointID: UUID, password: String?, probe: RemoteHostProbe) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let remoteHookProfiles = Self.remoteManagedHookProfiles()

        logger.notice(
            "Remote uninstall starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public)"
        )

        for profile in remoteHookProfiles {
            switch profile.installationKind {
            case .jsonHooks:
                let remoteConfigPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let configExists = try await RemoteSSHCommandRunner.remoteFileExists(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                guard configExists else {
                    logger.debug(
                        "Remote uninstall skipped missing hook config endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteConfigPath, privacy: .public)"
                    )
                    continue
                }
                let existingConfig = try await RemoteSSHCommandRunner.readRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                let updatedData = HookInstaller.updatedConfigurationData(
                    existingData: existingConfig.isEmpty ? nil : existingConfig,
                    profile: profile,
                    customCommand: "",
                    installing: false
                )
                try await RemoteSSHCommandRunner.writeRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    contents: updatedData,
                    password: password
                )

            case .hookDirectory:
                let remoteDirectoryPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                _ = try await RemoteSSHCommandRunner.runSSH(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    password: password,
                    remoteCommand: "rm -rf \(quoted(remoteDirectoryPath))",
                    acceptNewHostKey: true,
                    allowFailure: true
                )

                if let activationPath = profile.activationConfigurationRelativePath,
                   let entryName = profile.activationEntryName {
                    let remoteActivationPath = Self.remoteConfigurationPath(
                        relativePath: activationPath,
                        homeDirectory: probe.homeDirectory
                    )
                    let activationConfigExists = try await RemoteSSHCommandRunner.remoteFileExists(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        password: password
                    )
                    guard activationConfigExists else {
                        logger.debug(
                            "Remote uninstall skipped missing activation config endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteActivationPath, privacy: .public)"
                        )
                        continue
                    }
                    let existingActivationConfig = try await RemoteSSHCommandRunner.readRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        password: password
                    )
                    let updatedActivationData = HookInstaller.updatedInternalHookConfigurationData(
                        existingData: existingActivationConfig.isEmpty ? nil : existingActivationConfig,
                        entryName: entryName,
                        installing: false
                    )
                    try await RemoteSSHCommandRunner.writeRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        contents: updatedActivationData,
                        password: password
                    )
                }

            case .pluginDirectory:
                let remoteDirectoryPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                _ = try await RemoteSSHCommandRunner.runSSH(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    password: password,
                    remoteCommand: "rm -rf \(quoted(remoteDirectoryPath))",
                    acceptNewHostKey: true,
                    allowFailure: true
                )

            case .tomlHooks:
                let remoteConfigPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let configExists = try await RemoteSSHCommandRunner.remoteFileExists(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                guard configExists else {
                    logger.debug(
                        "Remote uninstall skipped missing TOML config endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteConfigPath, privacy: .public)"
                    )
                    continue
                }
                let existingConfig = try await RemoteSSHCommandRunner.readRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                let existingContent = String(data: existingConfig, encoding: .utf8) ?? ""
                let segments = TOMLHookConfigParser.parse(existingContent)
                let updatedContent = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [])
                try await RemoteSSHCommandRunner.writeRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    contents: Data(updatedContent.utf8),
                    password: password
                )
            case .pluginFile:
                continue
            }
        }

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteBootstrapUninstallCommand(
                installRoot: endpoint.remoteInstallRoot,
                controlSocketPath: endpoint.remoteControlSocketPath,
                hookSocketPath: endpoint.remoteHookSocketPath
            ),
            acceptNewHostKey: true,
            allowFailure: true
        )
        logger.notice(
            "Remote uninstall completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )
    }

    private func ensureRemoteAgentRunning(endpointID: UUID, password: String?) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        logger.notice(
            "Remote agent ensure/start endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
        let command = Self.remoteEnsureAgentRunningCommand(
            installRoot: endpoint.remoteInstallRoot,
            controlSocketPath: endpoint.remoteControlSocketPath,
            hookSocketPath: endpoint.remoteHookSocketPath
        )
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: command,
            acceptNewHostKey: true
        )
        logger.debug(
            "Remote agent ensure/start completed endpoint=\(endpoint.id.uuidString, privacy: .public)"
        )
    }

    private func endpoint(for id: UUID) -> RemoteEndpoint? {
        endpoints.first { $0.id == id }
    }

    nonisolated static func resolvedRemoteHostHint(
        payloadRemoteHost: String?,
        endpoint: RemoteEndpoint?
    ) -> String? {
        if let payloadRemoteHost = sanitizedNonEmpty(payloadRemoteHost) {
            if isIPAddressLike(payloadRemoteHost),
               let detectedHostname = sanitizedNonEmpty(endpoint?.detectedHostname) {
                return detectedHostname
            }
            return payloadRemoteHost
        }

        if let detectedHostname = sanitizedNonEmpty(endpoint?.detectedHostname) {
            return detectedHostname
        }

        if let host = sanitizedNonEmpty(endpoint?.sshLink?.host) {
            return host
        }

        guard let sshTarget = sanitizedNonEmpty(endpoint?.sshTarget) else {
            return nil
        }
        return sanitizedNonEmpty(sshTarget.split(separator: "@").last.map(String.init) ?? sshTarget)
    }

    nonisolated static func isRemoteCodexBypassPermissionRequest(
        provider: String, eventType: String, permissionMode: String?
    ) -> Bool {
        provider == "codex" && eventType == "PermissionRequest" && permissionMode == "bypassPermissions"
    }

    nonisolated static func immediateRemoteCodexPermissionDecision(
        provider: String, eventType: String, permissionMode: String?
    ) -> String? {
        isRemoteCodexBypassPermissionRequest(
            provider: provider, eventType: eventType, permissionMode: permissionMode
        ) ? "approve" : nil
    }

    nonisolated static func resolvedRemoteToolUseID(
        toolUseID: String?,
        expectsResponse: Bool,
        requestID: UUID
    ) -> String? {
        if let toolUseID = sanitizedNonEmpty(toolUseID) {
            return toolUseID
        }

        guard expectsResponse else {
            return nil
        }

        return "bridge-\(requestID.uuidString)"
    }

    private func updateEndpoint(_ endpoint: RemoteEndpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else {
            return
        }
        endpoints[index] = endpoint
        persistEndpoints()
    }

    private func clearUninstalledRemoteAgentMetadata(endpointID: UUID) {
        guard var endpoint = endpoint(for: endpointID) else { return }
        endpoint.agentVersion = nil
        endpoint.lastBootstrapAt = nil
        endpoint.lastConnectedAt = nil
        updateEndpoint(endpoint)
    }

    private func shouldAutoReconnectOnStart(endpoint: RemoteEndpoint) -> Bool {
        guard connectionAttempts.allowsAutomaticRetry(endpointID: endpoint.id) else { return false }
        return Self.shouldAutoReconnectOnLaunch(
            endpoint: endpoint,
            hasReusablePassword: hasReusablePassword(for: endpoint.id)
        )
    }

    func shouldBootstrapRemoteAgent(endpointID: UUID, forceBootstrap: Bool) -> Bool {
        guard let endpoint = endpoint(for: endpointID) else {
            return forceBootstrap
        }

        return Self.shouldBootstrapRemoteAgent(endpoint: endpoint, forceBootstrap: forceBootstrap)
    }

    nonisolated static func shouldBootstrapRemoteAgent(endpoint: RemoteEndpoint, forceBootstrap: Bool) -> Bool {
        if forceBootstrap {
            return true
        }

        return endpoint.lastBootstrapAt == nil
            && endpoint.lastConnectedAt == nil
            && endpoint.agentVersion == nil
    }

    nonisolated static func shouldAutoReconnectOnLaunch(
        endpoint: RemoteEndpoint,
        hasReusablePassword: Bool
    ) -> Bool {
        guard endpoint.lastConnectedAt != nil else {
            return false
        }

        switch endpoint.authMode {
        case .passwordSession:
            return hasReusablePassword
        case .unknown, .publicKey:
            return true
        }
    }

    nonisolated static func runtimeReconnectDelaySeconds(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 5))
        return min(pow(2, Double(exponent)), 30)
    }

    nonisolated static func normalizedLinuxBridgeArchitecture(_ architecture: String) -> String? {
        switch architecture.lowercased() {
        case "x86_64", "amd64":
            return "x86_64"
        case "aarch64", "arm64":
            return "aarch64"
        default:
            return nil
        }
    }

    nonisolated static func remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: String) -> String {
        "PingIslandBridge-linux-musl-\(normalizedArchitecture)"
    }

    nonisolated static func remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: String) -> String {
        remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: normalizedArchitecture) + ".zip"
    }

    nonisolated static func remoteLinuxBridgeLegacyBinaryAssetName(normalizedArchitecture: String) -> String {
        "PingIslandBridge-linux-\(normalizedArchitecture)"
    }

    nonisolated static func remoteLinuxBridgeLegacyArchiveAssetName(normalizedArchitecture: String) -> String {
        remoteLinuxBridgeLegacyBinaryAssetName(normalizedArchitecture: normalizedArchitecture) + ".zip"
    }

    nonisolated static func remoteLinuxBridgeOverrideURL(
        normalizedArchitecture: String,
        homeDirectory: URL
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".ping-island", isDirectory: true)
            .appendingPathComponent("custom-bridges", isDirectory: true)
            .appendingPathComponent(
                remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: normalizedArchitecture)
            )
    }

    func hasReusablePassword(for endpointID: UUID) -> Bool {
        if let password = ephemeralPasswords[endpointID], !password.isEmpty {
            return true
        }

        return credentialStore.hasPassword(for: endpointID)
    }

    private func setState(
        for endpointID: UUID,
        phase: RemoteEndpointConnectionPhase,
        detail: String,
        lastError: String? = nil,
        requiresPassword: Bool = false,
        agentVersion: String? = nil
    ) {
        let currentVersion = agentVersion ?? runtimeStates[endpointID]?.agentVersion
        runtimeStates[endpointID] = RemoteEndpointRuntimeState(
            phase: phase,
            detail: detail,
            lastError: lastError,
            requiresPassword: requiresPassword,
            agentVersion: currentVersion
        )
    }

    private func loadPersistedEndpoints() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([RemoteEndpoint].self, from: data) else {
            endpoints = []
            return
        }
        endpoints = decoded
        runtimeStates = Dictionary(uniqueKeysWithValues: decoded.map { endpoint in
            (endpoint.id, RemoteEndpointRuntimeState(agentVersion: endpoint.agentVersion))
        })
    }

    private func persistEndpoints() {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    nonisolated private static func sanitizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated static func connectionFailureDetail(for stage: String) -> String {
        switch stage {
        case let stage where stage.hasPrefix("probe"):
            return "远程主机检测失败"
        case let stage where stage.hasPrefix("bootstrap"):
            return "远程初始化失败"
        default:
            return "远程连接失败"
        }
    }

    nonisolated static func presentableConnectionError(
        stage: String,
        errorDescription: String
    ) -> String {
        let normalized = errorDescription
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()

        if lowercased.contains("permission denied") {
            return "SSH 认证失败，请重新输入密码或检查远程 SSH 凭据。"
        }

        if lowercased.contains("connection timed out") || lowercased.contains("operation timed out") {
            return "SSH 连接超时，请检查远程主机地址、端口和网络连通性。"
        }

        if lowercased.contains("connection refused") {
            return "SSH 连接被拒绝，请确认远程 SSH 服务和端口配置。"
        }

        if lowercased.contains("host key verification failed") {
            return "SSH 主机指纹校验失败，请确认远程主机指纹后重新连接。"
        }

        if lowercased.contains(".hermes/plugins/ping_island") && lowercased.contains("no such file or directory") {
            return stage.hasPrefix("bootstrap")
                ? "无法写入远程 Hermes 插件目录，请确认远程主目录可写后重试。"
                : "远程 Hermes 插件目录不可用，暂时无法写入插件文件。"
        }

        if lowercased.contains("dest open") && lowercased.contains("no such file or directory") {
            return "远程目标目录不存在，无法写入初始化文件。"
        }

        if let firstLine = normalized.split(separator: "\n", omittingEmptySubsequences: true).first {
            return String(firstLine)
        }

        return normalized
    }

    nonisolated private static func isIPAddressLike(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipv4Parts = candidate.split(separator: ".")
        if ipv4Parts.count == 4,
           ipv4Parts.allSatisfy({ part in
               guard let octet = Int(part) else { return false }
               return octet >= 0 && octet <= 255
           }) {
            return true
        }

        return candidate.contains(":") && candidate.range(of: "^[0-9a-fA-F:]+$", options: .regularExpression) != nil
    }

    private func resolvedCredential(
        for endpointID: UUID,
        requestedPassword: String?
    ) -> RemoteEndpointCredential {
        if let requestedPassword {
            ephemeralPasswords[endpointID] = requestedPassword
            return RemoteEndpointCredential(password: requestedPassword, source: .userInput)
        }

        if let password = ephemeralPasswords[endpointID], !password.isEmpty {
            return RemoteEndpointCredential(password: password, source: .memory)
        }

        if let password = credentialStore.password(for: endpointID) {
            return RemoteEndpointCredential(password: password, source: .keychain)
        }

        return RemoteEndpointCredential(password: nil, source: .none)
    }

    private func persistCredentialAfterSuccessfulConnection(endpointID: UUID, password: String?) {
        guard let endpoint = endpoint(for: endpointID) else { return }

        if endpoint.authMode == .passwordSession, let password, !password.isEmpty {
            if credentialStore.savePassword(password, for: endpoint) {
                ephemeralPasswords.removeValue(forKey: endpointID)
            }
            objectWillChange.send()
            return
        }

        ephemeralPasswords.removeValue(forKey: endpointID)
        credentialStore.deletePassword(for: endpointID)
        objectWillChange.send()
    }

    private func handleConnectionFailure(
        endpointID: UUID,
        credentialSource: RemoteEndpointCredentialSource
    ) {
        if credentialSource != .none {
            ephemeralPasswords.removeValue(forKey: endpointID)
        }

        if credentialSource == .keychain || endpoint(for: endpointID)?.authMode == .passwordSession {
            credentialStore.deletePassword(for: endpointID)
        }

        if var endpoint = endpoint(for: endpointID), endpoint.authMode == .unknown, credentialSource != .none {
            endpoint.authMode = .passwordSession
            updateEndpoint(endpoint)
        }

        objectWillChange.send()
    }

    private func shouldRequirePasswordAfterConnectionFailure(
        endpointID: UUID,
        credentialSource: RemoteEndpointCredentialSource
    ) -> Bool {
        if credentialSource != .none {
            return true
        }

        return endpoint(for: endpointID)?.authMode == .passwordSession
    }

    private func resolvedRemotePath(_ path: String, homeDirectory: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return homeDirectory + "/" + path.dropFirst(2)
    }

    func diagnosticsSnapshot() -> [RemoteEndpointDiagnosticsSnapshot] {
        endpoints.map { endpoint in
            RemoteEndpointDiagnosticsSnapshot(
                endpoint: endpoint,
                runtimeState: runtimeStates[endpoint.id] ?? RemoteEndpointRuntimeState(agentVersion: endpoint.agentVersion)
            )
        }
    }

    nonisolated static func remoteBootstrapPrepareCommand(
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String,
        homeDirectory: String,
        configDirectoryPaths: [String]
    ) -> String {
        let agentPattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        let claudeDirectory = remoteConfigurationPath(relativePath: ".claude", homeDirectory: homeDirectory)
        let directoryList = ([ "\(installRoot)/bin", "\(installRoot)/run", "\(installRoot)/logs", claudeDirectory ] + configDirectoryPaths)
            .uniquedPreservingOrder()
            .map(shellQuote)
            .joined(separator: " ")
        return """
        mkdir -p \(directoryList)
        chmod 700 \(shellQuote("\(installRoot)/run")) \(shellQuote("\(installRoot)/logs"))
        pkill -f \(shellQuote(agentPattern)) >/dev/null 2>&1 || true
        sleep 1
        rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge.tmp"))
        """
    }

    nonisolated static func remoteEnsureAgentRunningCommand(
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String
    ) -> String {
        let servicePattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        return """
        mkdir -p \(shellQuote("\(installRoot)/run")) \(shellQuote("\(installRoot)/logs"))
        chmod 700 \(shellQuote("\(installRoot)/run")) \(shellQuote("\(installRoot)/logs"))
        if [ -S \(shellQuote(controlSocketPath)) ] && pgrep -f \(shellQuote(servicePattern)) >/dev/null 2>&1; then
          exit 0
        fi
        if [ ! -x \(shellQuote("\(installRoot)/bin/ping-island-bridge")) ] || [ ! -x \(shellQuote("\(installRoot)/bin/PingIslandBridge")) ]; then
          echo "Ping Island remote bridge is not installed at \(installRoot)/bin" >&2
          exit 127
        fi
        pkill -f \(shellQuote(servicePattern)) >/dev/null 2>&1 || true
        rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath))
        nohup \(shellQuote("\(installRoot)/bin/ping-island-bridge")) --mode remote-agent-service --hook-socket \(shellQuote(hookSocketPath)) --control-socket \(shellQuote(controlSocketPath)) > \(shellQuote("\(installRoot)/logs/remote-agent.log")) 2>&1 &
        sleep 1
        if [ -S \(shellQuote(controlSocketPath)) ] && pgrep -f \(shellQuote(servicePattern)) >/dev/null 2>&1; then
          exit 0
        fi
        echo "Ping Island remote bridge failed to start" >&2
        tail -n 40 \(shellQuote("\(installRoot)/logs/remote-agent.log")) >&2 2>/dev/null || true
        exit 1
        """
    }

    nonisolated static func remoteBootstrapInstallCommand(
        installRoot: String,
        stagedBridgePath: String
    ) -> String {
        """
        mv -f \(shellQuote(stagedBridgePath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge"))
        chmod 755 \(shellQuote("\(installRoot)/bin/PingIslandBridge")) \(shellQuote("\(installRoot)/bin/ping-island-bridge"))
        """
    }

    nonisolated static func remoteBridgeLauncherScript() -> String {
        """
        #!/bin/sh
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        export PING_ISLAND_BRIDGE_CONFIG="$SCRIPT_DIR/../bridge-config.json"
        COMPAT_LIB="$SCRIPT_DIR/../lib"
        if [ -x "$COMPAT_LIB/ld-linux-x86-64.so.2" ] && ldd "$SCRIPT_DIR/PingIslandBridge" 2>&1 | grep -q 'libc\\.so'; then
          exec "$COMPAT_LIB/ld-linux-x86-64.so.2" --library-path "$COMPAT_LIB" "$SCRIPT_DIR/PingIslandBridge" "$@"
        fi
        exec "$SCRIPT_DIR/PingIslandBridge" "$@"
        """
    }

    nonisolated static func remoteBridgeRuntimeConfigPath(installRoot: String) -> String {
        "\(installRoot)/bridge-config.json"
    }

    nonisolated static func remoteBootstrapUninstallCommand(
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String
    ) -> String {
        let servicePattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        let attachPattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-attach"
        return """
        pkill -f \(shellQuote(servicePattern)) >/dev/null 2>&1 || true
        pkill -f \(shellQuote(attachPattern)) >/dev/null 2>&1 || true
        sleep 1
        rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath))
        rm -rf \(shellQuote(installRoot))
        """
    }

    nonisolated static func remoteManagedHookProfiles() -> [ManagedHookClientProfile] {
        let supportedProfileIDs: Set<String> = [
            "claude-hooks",
            "codex-hooks",
            "antigravity-hooks",
            "hermes-hooks",
            "pi-hooks",
            "qwen-code-hooks",
            "openclaw-hooks",
            "codebuddy-cli-hooks",
            "qoder-hooks",
            "qoder-cli-hooks",
            "qoder-cn-hooks",
            "qoder-cn-cli-hooks",
            "qoderwork-hooks"
        ]
        return ClientProfileRegistry.managedHookProfiles.filter { profile in
            supportedProfileIDs.contains(profile.id)
        }
    }

    nonisolated static func remoteManagedBridgeArguments(
        for profile: ManagedHookClientProfile,
        installRoot: String
    ) -> [String] {
        [
            "\(installRoot)/bin/ping-island-bridge",
            "--source",
            profile.bridgeSource
        ] + profile.bridgeExtraArguments
    }

    nonisolated static func remoteManagedBridgeEnvironment(hookSocketPath: String) -> [String: String] {
        ["ISLAND_SOCKET_PATH": hookSocketPath]
    }

    nonisolated static func remoteManagedHookConfigDirectoryPaths(
        homeDirectory: String,
        profiles: [ManagedHookClientProfile]
    ) -> [String] {
        profiles
            .flatMap { profile in
                remoteManagedHookDirectoryPaths(for: profile, homeDirectory: homeDirectory)
            }
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
    }

    nonisolated static func remoteManagedHookDirectoryPaths(
        for profile: ManagedHookClientProfile,
        homeDirectory: String
    ) -> [String] {
        let configurationPath = remoteConfigurationPath(
            relativePath: profile.configurationRelativePaths[0],
            homeDirectory: homeDirectory
        )

        var paths: [String]
        switch profile.installationKind {
        case .hookDirectory:
            paths = [configurationPath, NSString(string: configurationPath).deletingLastPathComponent]
        case .jsonHooks, .pluginFile, .tomlHooks:
            paths = [NSString(string: configurationPath).deletingLastPathComponent]
        case .pluginDirectory:
            paths = [
                NSString(string: configurationPath).deletingLastPathComponent,
                configurationPath
            ]
        }

        if let activationRelativePath = profile.activationConfigurationRelativePath {
            let activationPath = remoteConfigurationPath(
                relativePath: activationRelativePath,
                homeDirectory: homeDirectory
            )
            paths.append(NSString(string: activationPath).deletingLastPathComponent)
        }

        return paths.uniquedPreservingOrder()
    }

    nonisolated static func remoteConfigurationPath(relativePath: String, homeDirectory: String) -> String {
        guard !relativePath.isEmpty else { return homeDirectory }
        return relativePath
            .split(separator: "/")
            .reduce(homeDirectory) { partialPath, component in
                partialPath + "/" + component
            }
    }

    private func quoted(_ value: String) -> String {
        Self.shellQuote(value)
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

struct PendingRemoteRequest: Equatable {
    let endpointID: UUID
    let requestID: UUID
    let sessionID: String
}

struct RemotePendingRequestStore {
    private var requestsByToolUseID: [String: [PendingRemoteRequest]] = [:]

    mutating func append(_ request: PendingRemoteRequest, for toolUseID: String) {
        requestsByToolUseID[toolUseID, default: []].append(request)
    }

    mutating func removeAll() {
        requestsByToolUseID.removeAll()
    }

    mutating func removeAll(for toolUseID: String) -> [PendingRemoteRequest] {
        requestsByToolUseID.removeValue(forKey: toolUseID) ?? []
    }

    mutating func removeAll(for endpointID: UUID) {
        requestsByToolUseID = requestsByToolUseID.reduce(into: [:]) { partialResult, entry in
            let remainingRequests = entry.value.filter { $0.endpointID != endpointID }
            if !remainingRequests.isEmpty {
                partialResult[entry.key] = remainingRequests
            }
        }
    }

    func requests(for toolUseID: String) -> [PendingRemoteRequest] {
        requestsByToolUseID[toolUseID] ?? []
    }
}

private struct RemoteEndpointCredential {
    let password: String?
    let source: RemoteEndpointCredentialSource
}

private enum RemoteEndpointCredentialSource {
    case none
    case userInput
    case memory
    case keychain
}

private struct RemoteEndpointCredentialStore {
    private let service = "com.wudanwu.pingisland.remote-host-password"

    func hasPassword(for endpointID: UUID) -> Bool {
        password(for: endpointID) != nil
    }

    func password(for endpointID: UUID) -> String? {
        var query = baseQuery(for: endpointID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }

        return password
    }

    @discardableResult
    func savePassword(_ password: String, for endpoint: RemoteEndpoint) -> Bool {
        let passwordData = Data(password.utf8)
        let query = baseQuery(for: endpoint.id)
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = query
        addQuery[kSecValueData as String] = passwordData
        addQuery[kSecAttrLabel as String] = endpoint.resolvedTitle
        addQuery[kSecAttrComment as String] = endpoint.sshURL?.absoluteString ?? endpoint.sshTarget
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func deletePassword(for endpointID: UUID) {
        let query = baseQuery(for: endpointID)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for endpointID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointID.uuidString
        ]
    }
}

private enum RemoteConnectorError: LocalizedError {
    case localBridgeBinaryMissing
    case missingClaudeHookProfile
    case invalidRemoteMessage
    case authenticationRejected
    case unsupportedRemotePlatform(String)
    case remoteBridgeDownloadFailed(String)
    case sshFailure(String)

    var errorDescription: String? {
        switch self {
        case .localBridgeBinaryMissing:
            return "本地 PingIslandBridge 二进制不存在，无法安装到远程主机"
        case .missingClaudeHookProfile:
            return "未找到 hooks 配置模板"
        case .invalidRemoteMessage:
            return "远程桥接返回了无法识别的消息"
        case .authenticationRejected:
            return "远程 SSH 身份验证失败，请重新连接"
        case .unsupportedRemotePlatform(let detail):
            return detail
        case .remoteBridgeDownloadFailed(let detail):
            return detail
        case .sshFailure(let detail):
            return detail
        }
    }
}

@MainActor
final class RemoteAttachConnector {
    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Remote")

    private let endpoint: RemoteEndpoint
    private let password: String?
    private let onMessage: @Sendable (RemoteInboundMessage) async -> Void
    private let onDisconnect: @Sendable (Error?) -> Void

    private var process: Process?
    private var controlWriter: RemoteControlWriter?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var messageDeliveryTask: Task<Void, Never>?
    private let disconnectLock = NSLock()
    private var didFinishDisconnect = false
    private var suppressDisconnectCallback = false

    fileprivate init(
        endpoint: RemoteEndpoint,
        password: String?,
        onMessage: @escaping @Sendable (RemoteInboundMessage) async -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        self.endpoint = endpoint
        self.password = password
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    // Exercise transport response/termination ownership without starting SSH.
    init(controlWriter: RemoteControlWriter, onDisconnect: @escaping @Sendable (Error?) -> Void) {
        endpoint = RemoteEndpoint(displayName: "Transport", sshTarget: "unused.example.test")
        password = nil
        onMessage = { _ in }
        self.onDisconnect = onDisconnect
        self.controlWriter = controlWriter
    }

    func processTerminated(_ error: Error?) {
        finishDisconnect(error)
    }

    func start() async throws {
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try RemoteSSHCommandRunner.makeSSHProcess(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: "\(shellQuote("\(endpoint.remoteInstallRoot)/bin/ping-island-bridge")) --mode remote-agent-attach --control-socket \(shellQuote(endpoint.remoteControlSocketPath))",
            acceptNewHostKey: true
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let writer = try RemoteControlWriter(handle: stdinPipe.fileHandleForWriting)
        do { try process.run() } catch { writer.cancel(); throw error }
        Self.logger.notice(
            "Remote attach process launched endpoint=\(self.endpoint.id.uuidString, privacy: .public) target=\(self.endpoint.sshTarget, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
        )
        self.process = process
        self.controlWriter = writer
        try? stdinPipe.fileHandleForWriting.close()
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Drain on the readability callback, before scheduling actor work;
            // otherwise repeated callbacks can queue blocking reads of an empty pipe.
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                self?.receiveStdout(chunk)
            }
        }
        let endpointID = endpoint.id
        process.terminationHandler = { [weak self] process in
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let authenticationRejected = RemoteAuthenticationFailure.isRejection(stderr: stderr, exitCode: process.terminationStatus)
            let error: Error? = if process.terminationStatus == 0 {
                nil
            } else if authenticationRejected {
                RemoteConnectorError.authenticationRejected
            } else {
                RemoteConnectorError.sshFailure(
                    stderr.isEmpty ? "SSH attach 已断开" : "SSH attach 已断开: \(Self.excerpt(stderr))"
                )
            }

            if process.terminationStatus == 0 {
                Self.logger.notice(
                    "Remote attach process exited cleanly endpoint=\(endpointID.uuidString, privacy: .public) status=\(process.terminationStatus, privacy: .public)"
                )
            } else if authenticationRejected {
                Self.logger.error("Remote attach authentication rejected endpoint=\(endpointID.uuidString, privacy: .public)")
            } else {
                Self.logger.error(
                    "Remote attach process exited endpoint=\(endpointID.uuidString, privacy: .public) status=\(process.terminationStatus, privacy: .public) stderr=\(Self.excerpt(stderr), privacy: .public)"
                )
            }

            if let self {
                Task { @MainActor in
                    self.processTerminated(error)
                }
            }
        }
    }

    func stop() {
        suppressDisconnectCallback = true
        stdoutHandle?.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        controlWriter?.cancel()
        controlWriter = nil
        stdoutHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    func sendDecision(
        requestID: UUID,
        decision: String,
        reason: String?,
        updatedInput: [String: RemoteJSONValue]?
    ) async throws {
        let message = RemoteDecisionMessage(
            requestID: requestID,
            decision: decision,
            reason: reason,
            updatedInput: updatedInput
        )
        try await writeControlMessage(message)
    }

    func sendAcknowledgement(requestID: UUID) async throws {
        try await writeControlMessage(RemoteAcknowledgementMessage(requestID: requestID))
    }

    func acknowledgeIgnoredEvent(_ payload: RemoteHookEventPayload) async throws {
        if payload.expectsResponse {
            // Decisions also acknowledge delivery. A no-decision response lets
            // the provider proceed and releases a filtered blocking hook.
            try await sendDecision(requestID: payload.requestID, decision: "defer", reason: nil, updatedInput: nil)
        } else {
            try await sendAcknowledgement(requestID: payload.requestID)
        }
    }

    private func writeControlMessage<T: Encodable>(_ message: T) async throws {
        guard let controlWriter else { throw RemoteConnectorError.invalidRemoteMessage }
        let data = try JSONEncoder().encode(message) + Data("\n".utf8)
        do {
            try await controlWriter.write(data)
        } catch {
            // EPIPE means SSH closed stdin; its termination callback supplies the
            // authoritative authentication error rather than an eager generic retry.
            if (error as? POSIXError)?.code != .EPIPE { finishDisconnect(error) }
            throw error
        }
    }

    private func receiveStdout(_ chunk: Data) {
        guard !suppressDisconnectCallback, !didFinishDisconnect else { return }
        do {
            if chunk.isEmpty {
                stdoutHandle?.readabilityHandler = nil
                // The termination callback carries the SSH authentication result.
                // Do not turn EOF into a generic retry before that result arrives.
                return
            }
            stdoutBuffer.append(chunk)
            try processBufferedMessages()
        } catch {
            Self.logger.error(
                "Remote attach read loop failed endpoint=\(self.endpoint.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            finishDisconnect(error)
        }
    }

    private func processBufferedMessages() throws {
        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(RemoteInboundMessage.self, from: line)
                let previousDelivery = messageDeliveryTask
                messageDeliveryTask = Task {
                    await previousDelivery?.value
                    guard !Task.isCancelled, !self.suppressDisconnectCallback, !self.didFinishDisconnect else { return }
                    await self.onMessage(message)
                }
            } catch {
                Self.logger.error(
                    "Remote attach decode failed endpoint=\(self.endpoint.id.uuidString, privacy: .public) payload=\(Self.excerpt(String(decoding: line, as: UTF8.self)), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
    }

    private func finishDisconnect(_ error: Error?) {
        disconnectLock.lock()
        defer { disconnectLock.unlock() }
        guard !didFinishDisconnect else { return }
        didFinishDisconnect = true
        controlWriter?.cancel()
        guard !suppressDisconnectCallback else { return }
        onDisconnect(error)
    }

    nonisolated private static func excerpt(_ value: String, limit: Int = 240) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

fileprivate enum RemoteInboundMessage: Decodable {
    case hello(RemoteDaemonHello)
    case hookEvent(RemoteHookEventMessage)
    case codexUsage(RemoteCodexUsageMessage)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(try RemoteDaemonHello(from: decoder))
        case "hook_event":
            self = .hookEvent(try RemoteHookEventMessage(from: decoder))
        case "codex_usage":
            self = .codexUsage(try RemoteCodexUsageMessage(from: decoder))
        default:
            throw RemoteConnectorError.invalidRemoteMessage
        }
    }
}

struct RemoteCodexUsageMessage: Codable, Equatable, Sendable {
    let type: String
    let payload: CodexUsageSnapshot
}

private struct SSHExecutionResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private enum RemoteSSHCommandRunner {
    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "RemoteSSH")

    static func probe(target: String, port: Int, password: String?) async throws -> RemoteHostProbe {
        let command = #"printf "%s\n" "$USER" "$HOSTNAME" "$HOME"; uname -s; uname -m; command -v claude >/dev/null 2>&1 && echo "__PING_ISLAND_HAS_CLAUDE__=1" || echo "__PING_ISLAND_HAS_CLAUDE__=0"; command -v tmux >/dev/null 2>&1 && echo "__PING_ISLAND_HAS_TMUX__=1" || echo "__PING_ISLAND_HAS_TMUX__=0""#
        logger.notice(
            "SSH probe starting target=\(target, privacy: .public) port=\(port, privacy: .public) hasPassword=\(password != nil, privacy: .public)"
        )
        let result = try await runSSH(
            target: target,
            port: port,
            password: password,
            remoteCommand: command,
            acceptNewHostKey: true
        )
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 7 else {
            throw RemoteConnectorError.sshFailure("远程主机返回的信息不完整")
        }
        let fingerprint = localKnownHostFingerprint(for: target, port: port)
        logger.notice(
            "SSH probe completed target=\(target, privacy: .public) port=\(port, privacy: .public) username=\(lines[0], privacy: .public) hostname=\(lines[1], privacy: .public) os=\(lines[3], privacy: .public) arch=\(lines[4], privacy: .public)"
        )
        return RemoteHostProbe(
            username: lines[0],
            hostname: lines[1],
            homeDirectory: lines[2],
            operatingSystem: lines[3],
            architecture: lines[4],
            hasClaude: lines[5].contains("=1"),
            hasTmux: lines[6].contains("=1"),
            fingerprint: fingerprint
        )
    }

    static func readRemoteFile(target: String, port: Int, remotePath: String, password: String?) async throws -> Data {
        let result = try await runSSH(
            target: target,
            port: port,
            password: password,
            remoteCommand: "cat \(shellQuote(remotePath))",
            acceptNewHostKey: true
        )
        return Data(result.stdout.utf8)
    }

    static func remoteFileExists(target: String, port: Int, remotePath: String, password: String?) async throws -> Bool {
        let result = try await runSSH(
            target: target,
            port: port,
            password: password,
            remoteCommand: "test -f \(shellQuote(remotePath))",
            acceptNewHostKey: true,
            allowFailure: true
        )
        if result.exitCode == 0 {
            return true
        }
        if result.exitCode == 1 {
            return false
        }

        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        throw RemoteConnectorError.sshFailure(detail.isEmpty ? "SSH 执行失败" : detail)
    }

    static func writeRemoteFile(target: String, port: Int, remotePath: String, contents: Data, password: String?) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-remote-\(UUID().uuidString)")
        try contents.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await copyFile(localURL: tempURL, remoteTarget: target, port: port, remotePath: remotePath, password: password)
    }

    /// Write a small file to the remote host via SSH (base64 pipe), bypassing SCP.
    /// Suitable for config files and scripts, not for large binaries.
    static func writeRemoteFileViaSSH(target: String, port: Int, remotePath: String, contents: Data, password: String?) async throws {
        let b64 = contents.base64EncodedString()
        let dirPath = (remotePath as NSString).deletingLastPathComponent
        let command = "mkdir -p \(shellQuote(dirPath)) && echo \(shellQuote(b64)) | base64 -d > \(shellQuote(remotePath))"
        let result = try await runSSH(
            target: target,
            port: port,
            password: password,
            remoteCommand: command,
            acceptNewHostKey: true
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RemoteConnectorError.sshFailure("写入远程文件失败 \(remotePath): \(detail)")
        }
    }

    static func copyFile(localURL: URL, remoteTarget: String, port: Int, remotePath: String, password: String?) async throws {
        logger.notice(
            "SCP copy starting target=\(remoteTarget, privacy: .public) port=\(port, privacy: .public) localPath=\(localURL.path, privacy: .public) remotePath=\(remotePath, privacy: .public) hasPassword=\(password != nil, privacy: .public)"
        )
        let process = try makeSecureCopyProcess(
            localURL: localURL,
            remoteTarget: remoteTarget,
            port: port,
            remotePath: remotePath,
            password: password
        )
        let result = try await run(process: process)
        guard result.exitCode == 0 else {
            throw RemoteConnectorError.sshFailure(result.stderr.isEmpty ? "SCP 复制失败" : result.stderr)
        }
        logger.debug(
            "SCP copy completed target=\(remoteTarget, privacy: .public) port=\(port, privacy: .public) remotePath=\(remotePath, privacy: .public)"
        )
    }

    static func runSSH(
        target: String,
        port: Int,
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool,
        allowFailure: Bool = false
    ) async throws -> SSHExecutionResult {
        logger.debug(
            "SSH exec starting target=\(target, privacy: .public) port=\(port, privacy: .public) hasPassword=\(password != nil, privacy: .public) acceptNewHostKey=\(acceptNewHostKey, privacy: .public) allowFailure=\(allowFailure, privacy: .public) command=\(excerpt(remoteCommand), privacy: .public)"
        )
        let process = try makeSSHProcess(
            target: target,
            port: port,
            password: password,
            remoteCommand: remoteCommand,
            acceptNewHostKey: acceptNewHostKey
        )
        let result = try await run(process: process)
        if RemoteAuthenticationFailure.isRejection(stderr: result.stderr, exitCode: result.exitCode) {
            // Authentication diagnostics may contain interactive prompts; do not log them.
            throw RemoteConnectorError.authenticationRejected
        }
        if result.exitCode == 0 {
            logger.debug(
                "SSH exec completed target=\(target, privacy: .public) port=\(port, privacy: .public) exitCode=\(result.exitCode, privacy: .public) stdout=\(excerpt(result.stdout), privacy: .public) stderr=\(excerpt(result.stderr), privacy: .public)"
            )
        } else {
            logger.error(
                "SSH exec failed target=\(target, privacy: .public) port=\(port, privacy: .public) exitCode=\(result.exitCode, privacy: .public) stdout=\(excerpt(result.stdout), privacy: .public) stderr=\(excerpt(result.stderr), privacy: .public)"
            )
        }
        guard allowFailure || result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RemoteConnectorError.sshFailure(detail.isEmpty ? "SSH 执行失败" : detail)
        }
        return result
    }

    static func makeSSHProcess(
        target: String,
        port: Int,
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(
            target: target,
            port: port,
            password: password,
            remoteCommand: remoteCommand,
            acceptNewHostKey: acceptNewHostKey
        )
        process.environment = try sshEnvironment(password: password)
        return process
    }

    private static func makeSecureCopyProcess(
        localURL: URL,
        remoteTarget: String,
        port: Int,
        remotePath: String,
        password: String?
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = scpArguments(
            localPath: localURL.path,
            remoteTarget: remoteTarget,
            port: port,
            remotePath: remotePath,
            password: password
        )
        process.environment = try sshEnvironment(password: password)
        return process
    }

    private static func run(process: Process) async throws -> SSHExecutionResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: SSHExecutionResult(
                        stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                        exitCode: process.terminationStatus
                    )
                )
            }

            do {
                try process.run()
                try? stdinPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func sshArguments(
        target: String,
        port: Int,
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool
    ) -> [String] {
        var arguments = commonSSHOptions(password: password, acceptNewHostKey: acceptNewHostKey)
        if port != RemoteSSHLink.defaultPort {
            arguments += ["-p", "\(port)"]
        }
        arguments.append(target)
        arguments.append(remoteCommand)
        return arguments
    }

    private static func scpArguments(
        localPath: String,
        remoteTarget: String,
        port: Int,
        remotePath: String,
        password: String?
    ) -> [String] {
        var arguments = commonSSHOptions(password: password, acceptNewHostKey: true)
        if port != RemoteSSHLink.defaultPort {
            arguments += ["-P", "\(port)"]
        }
        arguments.append(localPath)
        let scpTarget = RemoteSSHLink(sshTarget: remoteTarget, explicitPort: port)?.secureCopyTarget ?? remoteTarget
        arguments.append("\(scpTarget):\(remotePath)")
        return arguments
    }

    private static func commonSSHOptions(password: String?, acceptNewHostKey: Bool) -> [String] {
        var options = [
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=3",
            "-o", acceptNewHostKey ? "StrictHostKeyChecking=accept-new" : "StrictHostKeyChecking=yes"
        ]
        if password == nil {
            options += ["-o", "BatchMode=yes"]
        } else {
            options += ["-o", "BatchMode=no"]
        }
        return options
    }

    private static func sshEnvironment(password: String?) throws -> [String: String] {
        guard let password, !password.isEmpty else {
            return Foundation.ProcessInfo.processInfo.environment
        }

        let askpassURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-askpass-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        printf '%s' "$PING_ISLAND_REMOTE_PASSWORD"
        """
        try script.write(to: askpassURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassURL.path)

        var environment = Foundation.ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpassURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["PING_ISLAND_REMOTE_PASSWORD"] = password
        environment["DISPLAY"] = environment["DISPLAY"] ?? "ping-island:0"
        return environment
    }

    private static func localKnownHostFingerprint(for target: String, port: Int) -> String? {
        let host = RemoteSSHLink(sshTarget: target, explicitPort: port)?.knownHostsLookupTarget
            ?? (target.split(separator: "@").last.map(String.init) ?? target)
        return ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/ssh-keygen",
            arguments: ["-F", host]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func excerpt(_ value: String, limit: Int = 240) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}

@MainActor
private final class RemoteBridgeAssetResolver {
    private let fileManager = FileManager.default

    func resolveBinaryURL(for probe: RemoteHostProbe) async throws -> URL {
        switch probe.operatingSystem.lowercased() {
        case "darwin":
            guard let localURL = HookInstaller.remoteBridgeBinaryURL() else {
                throw RemoteConnectorError.localBridgeBinaryMissing
            }
            return localURL
        case "linux":
            return try await downloadLinuxBridge(for: probe.architecture)
        default:
            throw RemoteConnectorError.unsupportedRemotePlatform(
                AppLocalization.format(
                    "当前内置远程 bridge 仅支持 macOS 与 Linux 远程主机，检测到的是 %@ (%@)",
                    probe.operatingSystem,
                    probe.architecture
                )
            )
        }
    }

    private func downloadLinuxBridge(for architecture: String) async throws -> URL {
        guard let normalizedArch = RemoteConnectorManager.normalizedLinuxBridgeArchitecture(architecture) else {
            throw RemoteConnectorError.unsupportedRemotePlatform(
                AppLocalization.format(
                    "当前 Linux 远程 bridge 暂不支持架构 %@",
                    architecture
                )
            )
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let binaryAssetName = RemoteConnectorManager.remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: normalizedArch)
        let overrideURL = RemoteConnectorManager.remoteLinuxBridgeOverrideURL(
            normalizedArchitecture: normalizedArch,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
        var overrideIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: overrideURL.path, isDirectory: &overrideIsDirectory) {
            guard !overrideIsDirectory.boolValue,
                  fileManager.isReadableFile(atPath: overrideURL.path),
                  fileManager.isExecutableFile(atPath: overrideURL.path) else {
                throw RemoteConnectorError.remoteBridgeDownloadFailed(
                    AppLocalization.format(
                        "私有 Linux bridge 不可读或不可执行：%@",
                        overrideURL.path
                    )
                )
            }
            return overrideURL
        }
        let assetCandidates = [
            (
                archive: RemoteConnectorManager.remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: normalizedArch),
                binary: binaryAssetName
            ),
            (
                archive: RemoteConnectorManager.remoteLinuxBridgeLegacyArchiveAssetName(normalizedArchitecture: normalizedArch),
                binary: RemoteConnectorManager.remoteLinuxBridgeLegacyBinaryAssetName(normalizedArchitecture: normalizedArch)
            )
        ]
        let cacheDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island", isDirectory: true)
            .appendingPathComponent("remote-cache", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let cachedBinaryURL = cacheDirectory.appendingPathComponent(binaryAssetName)

        if fileManager.isReadableFile(atPath: cachedBinaryURL.path) {
            return cachedBinaryURL
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        for candidate in assetCandidates {
            let cachedArchiveURL = cacheDirectory.appendingPathComponent(candidate.archive)
            if fileManager.isReadableFile(atPath: cachedArchiveURL.path) {
                try await extractLinuxBridgeArchive(
                    archiveURL: cachedArchiveURL,
                    expectedBinaryName: candidate.binary,
                    destinationURL: cachedBinaryURL
                )
                return cachedBinaryURL
            }
        }

        var downloadFailures: [String] = []
        for candidate in assetCandidates {
            let cachedArchiveURL = cacheDirectory.appendingPathComponent(candidate.archive)
            let releaseURLString = "https://github.com/erha19/ping-island/releases/download/v\(version)/\(candidate.archive)"
            guard let releaseURL = URL(string: releaseURLString) else {
                downloadFailures.append(AppLocalization.format("下载地址无效：%@", releaseURLString))
                continue
            }

            let (downloadedURL, response) = try await URLSession.shared.download(from: releaseURL)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                downloadFailures.append(
                    AppLocalization.format(
                        "%@（HTTP %lld）",
                        candidate.archive,
                        (response as? HTTPURLResponse)?.statusCode ?? -1
                    )
                )
                try? fileManager.removeItem(at: downloadedURL)
                continue
            }

            if fileManager.fileExists(atPath: cachedArchiveURL.path) {
                try fileManager.removeItem(at: cachedArchiveURL)
            }
            try fileManager.moveItem(at: downloadedURL, to: cachedArchiveURL)
            try await extractLinuxBridgeArchive(
                archiveURL: cachedArchiveURL,
                expectedBinaryName: candidate.binary,
                destinationURL: cachedBinaryURL
            )
            return cachedBinaryURL
        }

        throw RemoteConnectorError.remoteBridgeDownloadFailed(
            AppLocalization.format(
                "无法从 GitHub Release 下载 Linux 远程 bridge：%@",
                downloadFailures.joined(separator: "；")
            )
        )
    }

    private func extractLinuxBridgeArchive(
        archiveURL: URL,
        expectedBinaryName: String,
        destinationURL: URL
    ) async throws {
        let extractionDirectory = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractionDirectory) }

        let extractionResult = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, extractionDirectory.path]
        )

        guard case .success = extractionResult else {
            let message: String
            switch extractionResult {
            case .success:
                message = ""
            case .failure(let error):
                message = error.localizedDescription
            }
            try? fileManager.removeItem(at: archiveURL)
            throw RemoteConnectorError.remoteBridgeDownloadFailed(
                AppLocalization.format("无法解压 Linux 远程 bridge 压缩包：%@", message)
            )
        }

        guard let extractedBinaryURL = extractedBinaryURL(
            named: expectedBinaryName,
            inside: extractionDirectory
        ) else {
            try? fileManager.removeItem(at: archiveURL)
            throw RemoteConnectorError.remoteBridgeDownloadFailed(
                AppLocalization.format("Linux 远程 bridge 压缩包中缺少可执行文件：%@", expectedBinaryName)
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: extractedBinaryURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
    }

    private func extractedBinaryURL(named expectedBinaryName: String, inside directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent == expectedBinaryName {
                return candidate
            }
        }
        return nil
    }
}
