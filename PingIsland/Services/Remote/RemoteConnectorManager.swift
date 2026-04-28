import Combine
import Foundation
import os.log
import Security

@MainActor
final class RemoteConnectorManager: ObservableObject {
    static let shared = RemoteConnectorManager()

    @Published private(set) var endpoints: [RemoteEndpoint] = []
    @Published private(set) var runtimeStates: [UUID: RemoteEndpointRuntimeState] = [:]

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Remote")
    private let persistenceKey = "RemoteConnectorManager.endpoints.v1"

    private var eventHandler: (@Sendable (HookEvent) -> Void)?
    private var permissionFailureHandler: (@Sendable (_ sessionId: String, _ toolUseId: String) -> Void)?
    private var connectors: [UUID: RemoteAttachConnector] = [:]
    private var pendingRequests = RemotePendingRequestStore()
    private var ephemeralPasswords: [UUID: String] = [:]
    private var hasStarted = false
    private let assetResolver = RemoteBridgeAssetResolver()
    private let credentialStore = RemoteEndpointCredentialStore()

    private init() {
        loadPersistedEndpoints()
    }

    func start(
        onEvent: @escaping @Sendable (HookEvent) -> Void,
        onPermissionFailure: (@Sendable (_ sessionId: String, _ toolUseId: String) -> Void)? = nil
    ) {
        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        guard !hasStarted else { return }
        hasStarted = true

        for endpoint in endpoints where shouldAutoReconnectOnStart(endpoint: endpoint) {
            connect(endpointID: endpoint.id, password: nil, forceBootstrap: false)
        }
    }

    func stop() {
        hasStarted = false
        for connector in connectors.values {
            connector.stop()
        }
        connectors.removeAll()
        pendingRequests.removeAll()
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

                let shouldBootstrap = await MainActor.run {
                    self.shouldBootstrapRemoteAgent(endpointID: endpointID, forceBootstrap: forceBootstrap)
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
                    stage = forceBootstrap ? "bootstrap-forced" : "bootstrap-initial"
                    try await bootstrapRemoteAgent(endpointID: endpointID, password: effectivePassword, probe: probe)
                    stage = "ensure-remote-message-runtime"
                    try await ensureRemoteMessageRuntime(
                        endpointID: endpointID,
                        password: effectivePassword,
                        probe: probe,
                        restartGateway: true
                    )
                } else {
                    logger.notice(
                        "Remote bootstrap skipped endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) reason=reuse_existing_install"
                    )
                    stage = "ensure-remote-hooks"
                    try await ensureRemoteHookConfigurations(endpointID: endpointID, password: effectivePassword, probe: probe)
                    stage = "ensure-remote-message-runtime"
                    try await ensureRemoteMessageRuntime(
                        endpointID: endpointID,
                        password: effectivePassword,
                        probe: probe,
                        restartGateway: false
                    )
                }

                do {
                stage = "ensure-remote-agent"
                try await ensureRemoteAgentRunning(endpointID: endpointID, password: effectivePassword)

                stage = "attach-cleanup-local"
                try await cleanupLocalAttachProcesses(endpointID: endpointID)

                stage = "attach-cleanup"
                try await cleanupRemoteAttachProcesses(endpointID: endpointID, password: effectivePassword)

                    stage = "attach"
                    try await attach(endpointID: endpointID, password: effectivePassword)
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

                    stage = "bootstrap-retry"
                    try await bootstrapRemoteAgent(endpointID: endpointID, password: effectivePassword, probe: probe)

                    stage = "ensure-remote-message-runtime"
                    try await ensureRemoteMessageRuntime(
                        endpointID: endpointID,
                        password: effectivePassword,
                        probe: probe,
                        restartGateway: true
                    )

                    stage = "ensure-remote-agent"
                    try await ensureRemoteAgentRunning(endpointID: endpointID, password: effectivePassword)

                    stage = "attach-cleanup"
                    try await cleanupRemoteAttachProcesses(endpointID: endpointID, password: effectivePassword)

                    stage = "attach"
                    try await attach(endpointID: endpointID, password: effectivePassword)
                }
                await MainActor.run {
                    self.persistCredentialAfterSuccessfulConnection(
                        endpointID: endpointID,
                        password: effectivePassword
                    )
                }
            } catch {
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

    private func attach(endpointID: UUID, password: String?) async throws {
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
                await self?.handle(message: message, endpointID: endpointID)
            },
            onDisconnect: { [weak self] error in
                guard let manager = self else { return }
                Task { @MainActor in
                    manager.handleDisconnect(endpointID: endpointID, error: error)
                }
            }
        )

        try await connector.start()
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
        connectors.removeValue(forKey: endpointID)?.stop()
        pendingRequests.removeAll(for: endpointID)
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

    private func handle(message: RemoteInboundMessage, endpointID: UUID) async {
        switch message {
        case .hello(let hello):
            logger.notice(
                "Remote daemon hello endpoint=\(endpointID.uuidString, privacy: .public) hostname=\(hello.hostname, privacy: .public) version=\(hello.version, privacy: .public)"
            )
            if var currentEndpoint = endpoint(for: endpointID) {
                currentEndpoint.agentVersion = hello.version
                currentEndpoint.lastConnectedAt = Date()
                updateEndpoint(currentEndpoint)
            }
            setState(for: endpointID, phase: .connected, detail: "远程转发已连接", agentVersion: hello.version)

        case .hookEvent(let eventMessage):
            let payload = eventMessage.payload
            guard let provider = SessionProvider(rawValue: payload.provider) else {
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
                kind: Self.resolvedRemoteClientKind(payload.clientInfo),
                profileID: payload.clientInfo.profileID,
                name: payload.clientInfo.name,
                bundleIdentifier: payload.clientInfo.bundleIdentifier,
                launchURL: payload.clientInfo.launchURL,
                origin: payload.clientInfo.origin,
                originator: payload.clientInfo.originator,
                threadSource: payload.clientInfo.threadSource,
                transport: payload.clientInfo.transport,
                remoteHost: resolvedRemoteHost,
                sessionFilePath: payload.clientInfo.sessionFilePath,
                terminalBundleIdentifier: payload.clientInfo.terminalBundleIdentifier,
                terminalProgram: payload.clientInfo.terminalProgram,
                terminalSessionIdentifier: payload.clientInfo.terminalSessionIdentifier,
                iTermSessionIdentifier: payload.clientInfo.iTermSessionIdentifier,
                tmuxSessionIdentifier: payload.clientInfo.tmuxSessionIdentifier,
                tmuxPaneIdentifier: payload.clientInfo.tmuxPaneIdentifier,
                processName: payload.clientInfo.processName
            )
            let resolvedStatus = Self.normalizedRemoteHookStatus(payload: payload, clientInfo: clientInfo)

            let event = HookEvent(
                sessionId: payload.sessionID,
                cwd: payload.cwd,
                event: payload.event,
                status: resolvedStatus,
                provider: provider,
                clientInfo: clientInfo,
                pid: payload.pid,
                tty: payload.tty,
                tool: payload.tool,
                toolInput: payload.toolInput?.mapValues { AnyCodable($0.foundationObject) },
                toolUseId: resolvedToolUseID,
                notificationType: payload.notificationType,
                message: payload.message,
                ingress: .remoteBridge
            )

            if payload.expectsResponse, let toolUseID = resolvedToolUseID {
                pendingRequests.append(PendingRemoteRequest(
                    endpointID: endpointID,
                    requestID: payload.requestID,
                    sessionID: payload.sessionID
                ), for: toolUseID)
            }

            eventHandler?(event)
        }
    }

    private func handleDisconnect(endpointID: UUID, error: Error?) {
        connectors.removeValue(forKey: endpointID)
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
    }

    private func applyProbe(_ probe: RemoteHostProbe, to endpointID: UUID, passwordWasUsed: Bool) {
        guard var endpoint = endpoint(for: endpointID) else { return }
        endpoint.detectedUsername = probe.username
        endpoint.detectedHostname = probe.hostname
        endpoint.detectedHomeDirectory = probe.homeDirectory
        endpoint.hostFingerprint = probe.fingerprint
        endpoint.authMode = passwordWasUsed ? .passwordSession : .publicKey
        if Self.usesPraduckHermesContainer(endpoint) {
            endpoint.remoteInstallRoot = Self.praduckHermesHostInstallRoot
            endpoint.remoteHookSocketPath = "\(Self.praduckHermesHostInstallRoot)/run/agent-hook.sock"
            endpoint.remoteControlSocketPath = "\(Self.praduckHermesHostInstallRoot)/run/agent-control.sock"
        } else {
            endpoint.remoteInstallRoot = resolvedRemotePath(endpoint.remoteInstallRoot, homeDirectory: probe.homeDirectory)
            endpoint.remoteHookSocketPath = resolvedRemotePath(endpoint.remoteHookSocketPath, homeDirectory: probe.homeDirectory)
            endpoint.remoteControlSocketPath = resolvedRemotePath(endpoint.remoteControlSocketPath, homeDirectory: probe.homeDirectory)
        }
        updateEndpoint(endpoint)
        logger.debug(
            "Remote probe applied endpoint=\(endpoint.id.uuidString, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public) hookSocket=\(endpoint.remoteHookSocketPath, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
    }

    private func bootstrapRemoteAgent(endpointID: UUID, password: String?, probe: RemoteHostProbe) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let bridgeBinaryURL = try await assetResolver.resolveBinaryURL(for: probe)
        let stagedBridgePath = Self.remoteStagedBridgePath(for: endpoint)
        let remoteHookProfiles = Self.remoteManagedHookProfiles(for: endpoint)
        logger.notice(
            "Remote bootstrap starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) binary=\(bridgeBinaryURL.path, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public)"
        )
        guard !remoteHookProfiles.isEmpty else {
            throw RemoteConnectorError.missingClaudeHookProfile
        }

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteBootstrapPrepareCommand(
                endpoint: endpoint,
                installRoot: endpoint.remoteInstallRoot,
                controlSocketPath: endpoint.remoteControlSocketPath,
                hookSocketPath: endpoint.remoteHookSocketPath,
                configDirectoryPaths: Self.remoteManagedHookConfigDirectoryPaths(
                    endpoint: endpoint,
                    homeDirectory: probe.homeDirectory,
                    profiles: remoteHookProfiles
                )
            ),
            acceptNewHostKey: true
        )
        logger.debug(
            "Remote bootstrap prepared directories and stopped stale agent endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )

        try await RemoteSSHCommandRunner.copyFile(
            localURL: bridgeBinaryURL,
            remoteTarget: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: stagedBridgePath,
            password: password
        )
        logger.debug(
            "Remote bootstrap copied staged bridge endpoint=\(endpoint.id.uuidString, privacy: .public) remotePath=\(stagedBridgePath, privacy: .public)"
        )

        let launcherScript = """
        #!/bin/sh
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        COMPAT_LIB="$SCRIPT_DIR/../lib"
        if [ -x "$COMPAT_LIB/ld-linux-x86-64.so.2" ]; then
          exec "$COMPAT_LIB/ld-linux-x86-64.so.2" --library-path "$COMPAT_LIB" "$SCRIPT_DIR/PingIslandBridge" "$@"
        fi
        exec "$SCRIPT_DIR/PingIslandBridge" "$@"
        """
        try await writeManagedRemoteFile(
            endpoint: endpoint,
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge",
            contents: launcherScript.data(using: .utf8) ?? Data(),
            password: password
        )
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteBootstrapInstallCommand(
                endpoint: endpoint,
                installRoot: endpoint.remoteInstallRoot,
                stagedBridgePath: stagedBridgePath
            ),
            acceptNewHostKey: true
        )
        logger.debug(
            "Remote bootstrap wrote launcher endpoint=\(endpoint.id.uuidString, privacy: .public)"
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
                let remoteBridgeArguments = Self.remoteManagedBridgeArguments(
                    for: profile,
                    installRoot: Self.remoteHookRuntimeInstallRoot(for: endpoint)
                )
                let remoteFiles = HookInstaller.managedHookDirectoryFiles(
                    for: profile,
                    bridgeArguments: remoteBridgeArguments,
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: Self.remoteHookRuntimeSocketPath(for: endpoint)
                    )
                )
                logger.debug(
                    "Remote bootstrap preparing hook directory endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteDirectoryPath, privacy: .public) fileCount=\(remoteFiles.count, privacy: .public)"
                )
                for (name, content) in remoteFiles {
                    try await writeManagedRemoteFile(
                        endpoint: endpoint,
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
                    try await RemoteSSHCommandRunner.writeRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        contents: updatedActivationData,
                        password: password
                    )
                }
            case .pluginDirectory:
                let remoteDirectoryPath = Self.remoteManagedPluginDirectoryPath(
                    for: profile,
                    endpoint: endpoint,
                    homeDirectory: probe.homeDirectory
                )
                let remoteFiles = HookInstaller.managedPluginDirectoryFiles(
                    for: profile,
                    bridgeArguments: Self.remoteManagedBridgeArguments(
                        for: profile,
                        installRoot: Self.remoteHookRuntimeInstallRoot(for: endpoint)
                    ),
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: Self.remoteHookRuntimeSocketPath(for: endpoint)
                    )
                )
                logger.debug(
                    "Remote bootstrap preparing plugin directory endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteDirectoryPath, privacy: .public) fileCount=\(remoteFiles.count, privacy: .public)"
                )
                for (name, content) in remoteFiles {
                    try await writeManagedRemoteFile(
                        endpoint: endpoint,
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: "\(remoteDirectoryPath)/\(name)",
                        contents: Data(content.utf8),
                        password: password
                    )
                }
                try await validateRemotePluginDirectoryIfNeeded(
                    profile: profile,
                    remoteDirectoryPath: remoteDirectoryPath,
                    endpoint: endpoint,
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

    private func ensureRemoteHookConfigurations(endpointID: UUID, password: String?, probe: RemoteHostProbe) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let remoteHookProfiles = Self.remoteManagedHookProfiles(for: endpoint)
        logger.notice(
            "Remote hook configuration refresh starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteManagedHookConfigPrepareCommand(
                endpoint: endpoint,
                homeDirectory: probe.homeDirectory,
                profiles: remoteHookProfiles
            ),
            acceptNewHostKey: true
        )

        for profile in remoteHookProfiles {
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
                let remoteCommand = HookInstaller.managedBridgeCommand(
                    source: profile.bridgeSource,
                    extraArguments: profile.bridgeExtraArguments,
                    launcherPath: "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge",
                    socketPath: endpoint.remoteHookSocketPath
                )
                let updatedData = HookInstaller.updatedConfigurationData(
                    existingData: existingConfig?.isEmpty == true ? nil : existingConfig,
                    profile: profile,
                    customCommand: remoteCommand,
                    installing: true,
                    removingCommandPrefixes: ["/Users/"]
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
                let remoteBridgeArguments = Self.remoteManagedBridgeArguments(
                    for: profile,
                    installRoot: Self.remoteHookRuntimeInstallRoot(for: endpoint)
                )
                let remoteFiles = HookInstaller.managedHookDirectoryFiles(
                    for: profile,
                    bridgeArguments: remoteBridgeArguments,
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: Self.remoteHookRuntimeSocketPath(for: endpoint)
                    )
                )
                for (name, content) in remoteFiles {
                    try await writeManagedRemoteFile(
                        endpoint: endpoint,
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
                    try await RemoteSSHCommandRunner.writeRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        contents: updatedActivationData,
                        password: password
                    )
                }

            case .pluginDirectory:
                let remoteDirectoryPath = Self.remoteManagedPluginDirectoryPath(
                    for: profile,
                    endpoint: endpoint,
                    homeDirectory: probe.homeDirectory
                )
                let remoteFiles = HookInstaller.managedPluginDirectoryFiles(
                    for: profile,
                    bridgeArguments: Self.remoteManagedBridgeArguments(
                        for: profile,
                        installRoot: Self.remoteHookRuntimeInstallRoot(for: endpoint)
                    ),
                    bridgeEnvironment: Self.remoteManagedBridgeEnvironment(
                        hookSocketPath: Self.remoteHookRuntimeSocketPath(for: endpoint)
                    )
                )
                for (name, content) in remoteFiles {
                    try await writeManagedRemoteFile(
                        endpoint: endpoint,
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: "\(remoteDirectoryPath)/\(name)",
                        contents: Data(content.utf8),
                        password: password
                    )
                }
                try await validateRemotePluginDirectoryIfNeeded(
                    profile: profile,
                    remoteDirectoryPath: remoteDirectoryPath,
                    endpoint: endpoint,
                    password: password
                )

            case .pluginFile:
                continue
            }
        }

        logger.notice(
            "Remote hook configuration refresh completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )
    }

    private func ensureRemoteMessageRuntime(
        endpointID: UUID,
        password: String?,
        probe: RemoteHostProbe,
        restartGateway: Bool
    ) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        guard Self.remoteManagedHookProfiles(for: endpoint).contains(where: { $0.id == "hermes-hooks" }) else {
            return
        }

        let paths = Self.remoteHermesRuntimeSupportPaths(endpoint: endpoint, homeDirectory: probe.homeDirectory)
        logger.notice(
            "Remote Hermes runtime refresh starting endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) runtime=\(paths.runtimeScriptHostPath, privacy: .public) hookDir=\(paths.gatewayHookDirectoryHostPath, privacy: .public)"
        )

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteHermesRuntimePrepareCommand(endpoint: endpoint, paths: paths),
            acceptNewHostKey: true
        )

        try await writeManagedRemoteFile(
            endpoint: endpoint,
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: paths.runtimeScriptHostPath,
            contents: Data(Self.remoteHermesRuntimeScript.utf8),
            password: password
        )
        try await writeManagedRemoteFile(
            endpoint: endpoint,
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: "\(paths.gatewayHookDirectoryHostPath)/handler.py",
            contents: Data(Self.remoteHermesGatewayHandlerScript.utf8),
            password: password
        )
        try await writeManagedRemoteFile(
            endpoint: endpoint,
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            remotePath: "\(paths.gatewayHookDirectoryHostPath)/HOOK.yaml",
            contents: Data(Self.remoteHermesGatewayHookYAML.utf8),
            password: password
        )

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteHermesRuntimeValidationCommand(
                endpoint: endpoint,
                paths: paths,
                restartGateway: restartGateway
            ),
            acceptNewHostKey: true
        )

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteHermesRuntimeWatcherCommand(endpoint: endpoint, paths: paths),
            acceptNewHostKey: true
        )

        logger.notice(
            "Remote Hermes runtime refresh completed endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public)"
        )
    }

    private func validateRemotePluginDirectoryIfNeeded(
        profile: ManagedHookClientProfile,
        remoteDirectoryPath: String,
        endpoint: RemoteEndpoint,
        password: String?
    ) async throws {
        guard profile.id == "hermes-hooks" else { return }

        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: Self.remoteHermesPluginValidationCommand(
                endpoint: endpoint,
                pluginDirectoryPath: remoteDirectoryPath
            ),
            acceptNewHostKey: true
        )
    }

    private func writeManagedRemoteFile(
        endpoint: RemoteEndpoint,
        target: String,
        port: Int,
        remotePath: String,
        contents: Data,
        password: String?
    ) async throws {
        guard Self.usesPraduckHermesContainer(endpoint),
              remotePath.hasPrefix(Self.praduckHermesDataRoot + "/")
        else {
            try await RemoteSSHCommandRunner.writeRemoteFile(
                target: target,
                port: port,
                remotePath: remotePath,
                contents: contents,
                password: password
            )
            return
        }

        let stagedPath = "/tmp/ping-island-managed-\(UUID().uuidString)"
        try await RemoteSSHCommandRunner.writeRemoteFile(
            target: target,
            port: port,
            remotePath: stagedPath,
            contents: contents,
            password: password
        )
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: target,
            port: port,
            password: password,
            remoteCommand: """
            sudo install -D -m 644 -o \(Self.praduckHermesHostUID) -g \(Self.praduckHermesHostGID) \(quoted(stagedPath)) \(quoted(remotePath))
            sudo rm -f \(quoted(stagedPath))
            """,
            acceptNewHostKey: true
        )
    }

    private func uninstallRemoteAgent(endpointID: UUID, password: String?, probe: RemoteHostProbe) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let remoteHookProfiles = Self.remoteManagedHookProfiles(for: endpoint)

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
                let existingConfig = try? await RemoteSSHCommandRunner.readRemoteFile(
                    target: endpoint.sshTarget,
                    port: endpoint.sshPort,
                    remotePath: remoteConfigPath,
                    password: password
                )
                let updatedData = HookInstaller.updatedConfigurationData(
                    existingData: existingConfig?.isEmpty == true ? nil : existingConfig,
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
                    let existingActivationConfig = try? await RemoteSSHCommandRunner.readRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: remoteActivationPath,
                        password: password
                    )
                    let updatedActivationData = HookInstaller.updatedInternalHookConfigurationData(
                        existingData: existingActivationConfig?.isEmpty == true ? nil : existingActivationConfig,
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
            endpoint: endpoint,
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
        Self.shouldAutoReconnectOnLaunch(
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

    nonisolated static func normalizedRemoteHookStatus(
        payload: RemoteHookEventPayload,
        clientInfo: SessionClientInfo
    ) -> String {
        switch payload.event {
        case "Stop":
            return "idle"
        case "SessionEnd":
            return "ended"
        default:
            break
        }

        guard clientInfo.isOpenClawGatewayClient else {
            return payload.status
        }

        switch payload.event {
        case "command:new", "command:reset", "message:received":
            return "processing"
        case "message:sent", "session:patch", "session:compact:after":
            return "idle"
        case "command:stop":
            return "ended"
        default:
            break
        }

        return payload.status
    }

    nonisolated static func resolvedRemoteClientKind(_ clientInfo: RemoteHookClientInfoPayload) -> SessionClientKind {
        let payloadKind = SessionClientKind(rawValue: clientInfo.kind) ?? .custom
        let explicitKind = clientInfo.profileID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchedProfile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: explicitKind,
            explicitName: clientInfo.name,
            explicitBundleIdentifier: clientInfo.bundleIdentifier,
            terminalBundleIdentifier: clientInfo.terminalBundleIdentifier,
            origin: clientInfo.origin,
            originator: clientInfo.originator,
            threadSource: clientInfo.threadSource,
            processName: clientInfo.processName
        )

        if let matchedProfile, matchedProfile.kind != .claudeCode || payloadKind == .custom {
            return matchedProfile.kind
        }

        return payloadKind
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
        "PingIslandBridge-linux-\(normalizedArchitecture)"
    }

    nonisolated static func remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: String) -> String {
        remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: normalizedArchitecture) + ".zip"
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
        endpoint: RemoteEndpoint,
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String,
        configDirectoryPaths: [String]
    ) -> String {
        let agentPattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        let baseDirectories = usesPraduckHermesContainer(endpoint)
            ? [ "\(installRoot)/bin", "\(installRoot)/run", "\(installRoot)/logs" ]
            : [ "\(installRoot)/bin", "\(installRoot)/run", "\(installRoot)/logs", "$HOME/.claude" ]
        let directoryList = (baseDirectories + configDirectoryPaths)
            .uniquedPreservingOrder()
            .map(shellQuote)
            .joined(separator: " ")
        if usesPraduckHermesContainer(endpoint) {
            return """
            sudo chmod o+x \(shellQuote(praduckHermesHostRoot)) >/dev/null 2>&1 || true
            sudo install -d -m 755 -o \(praduckHermesHostUID) -g \(praduckHermesHostGID) \(directoryList)
            sudo chown -R \(praduckHermesHostUID):\(praduckHermesHostGID) \(shellQuote(installRoot))
            sudo pkill -u \(praduckHermesHostUID) -f \(shellQuote(agentPattern)) >/dev/null 2>&1 || true
            sleep 1
            sudo rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath))
            sudo rm -f \(shellQuote("\(installRoot)/bin/PingIslandBridge.tmp"))
            """
        }
        return """
        mkdir -p \(directoryList)
        pkill -f \(shellQuote(agentPattern)) >/dev/null 2>&1 || true
        sleep 1
        rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge.tmp"))
        """
    }

    nonisolated static func remoteEnsureAgentRunningCommand(
        endpoint: RemoteEndpoint,
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String
    ) -> String {
        let servicePattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        if usesPraduckHermesContainer(endpoint) {
            let serviceCommand = """
            nohup \(shellQuote("\(installRoot)/bin/ping-island-bridge")) --mode remote-agent-service --hook-socket \(shellQuote(hookSocketPath)) --control-socket \(shellQuote(controlSocketPath)) > \(shellQuote("\(installRoot)/logs/remote-agent.log")) 2>&1 &
            """
            return """
            sudo chmod o+x \(shellQuote(praduckHermesHostRoot)) >/dev/null 2>&1 || true
            sudo install -d -m 755 -o \(praduckHermesHostUID) -g \(praduckHermesHostGID) \(shellQuote("\(installRoot)/run")) \(shellQuote("\(installRoot)/logs"))
            sudo chown -R \(praduckHermesHostUID):\(praduckHermesHostGID) \(shellQuote(installRoot))
            if \(praduckHermesHostRunPrefix) test -S \(shellQuote(controlSocketPath)) && pgrep -u \(praduckHermesHostUID) -f \(shellQuote(servicePattern)) >/dev/null 2>&1; then
              exit 0
            fi
            sudo pkill -u \(praduckHermesHostUID) -f \(shellQuote(servicePattern)) >/dev/null 2>&1 || true
            sudo rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath))
            \(praduckHermesHostRunPrefix) sh -c \(shellQuote(serviceCommand))
            sleep 1
            """
        }
        return """
        mkdir -p \(shellQuote("\(installRoot)/run")) \(shellQuote("\(installRoot)/logs"))
        if [ -S \(shellQuote(controlSocketPath)) ] && pgrep -f \(shellQuote(servicePattern)) >/dev/null 2>&1; then
          exit 0
        fi
        pkill -f \(shellQuote(servicePattern)) >/dev/null 2>&1 || true
        rm -f \(shellQuote(controlSocketPath)) \(shellQuote(hookSocketPath))
        nohup \(shellQuote("\(installRoot)/bin/ping-island-bridge")) --mode remote-agent-service --hook-socket \(shellQuote(hookSocketPath)) --control-socket \(shellQuote(controlSocketPath)) > \(shellQuote("\(installRoot)/logs/remote-agent.log")) 2>&1 &
        sleep 1
        """
    }

    nonisolated static func remoteBootstrapInstallCommand(
        endpoint: RemoteEndpoint,
        installRoot: String,
        stagedBridgePath: String
    ) -> String {
        if usesPraduckHermesContainer(endpoint) {
            return """
            sudo install -D -m 755 -o \(praduckHermesHostUID) -g \(praduckHermesHostGID) \(shellQuote(stagedBridgePath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge"))
            sudo chmod 755 \(shellQuote("\(installRoot)/bin/PingIslandBridge")) \(shellQuote("\(installRoot)/bin/ping-island-bridge"))
            sudo rm -f \(shellQuote(stagedBridgePath))
            """
        }
        return """
        mv -f \(shellQuote(stagedBridgePath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge"))
        chmod 755 \(shellQuote("\(installRoot)/bin/PingIslandBridge")) \(shellQuote("\(installRoot)/bin/ping-island-bridge"))
        """
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
            "hermes-hooks",
            "qwen-code-hooks",
            "openclaw-hooks",
            "qoder-hooks",
            "qoderwork-hooks"
        ]
        return ClientProfileRegistry.managedHookProfiles.filter { profile in
            supportedProfileIDs.contains(profile.id)
        }
    }

    nonisolated static func remoteManagedHookProfiles(for endpoint: RemoteEndpoint) -> [ManagedHookClientProfile] {
        let endpointDescriptor = [
            endpoint.displayName,
            endpoint.sshTarget,
            endpoint.detectedHostname,
            endpoint.detectedUsername
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        let selectedProfileIDs: Set<String>?
        if endpointDescriptor.contains("openclaw") {
            selectedProfileIDs = ["openclaw-hooks"]
        } else if endpointDescriptor.contains("praduck") || endpointDescriptor.contains("hermes") {
            selectedProfileIDs = ["hermes-hooks"]
        } else {
            selectedProfileIDs = nil
        }

        guard let selectedProfileIDs else {
            return remoteManagedHookProfiles()
        }

        return ClientProfileRegistry.managedHookProfiles.filter { profile in
            selectedProfileIDs.contains(profile.id)
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

    private struct RemoteHermesRuntimeSupportPaths: Sendable {
        let runtimeScriptHostPath: String
        let runtimeScriptContainerPath: String
        let gatewayHookDirectoryHostPath: String
        let gatewayHookDirectoryContainerPath: String
        let sessionsDirectoryContainerPath: String
        let logsDirectoryHostPath: String
        let logsDirectoryContainerPath: String
        let role: String
        let remoteHost: String
    }

    nonisolated static let praduckHermesHostRoot = "/srv/hermes"
    nonisolated static let praduckHermesDataRoot = "/srv/hermes/data"
    nonisolated static let praduckHermesHostInstallRoot = "/srv/hermes/data/ping-island"
    nonisolated static let praduckHermesContainerInstallRoot = "/opt/data/ping-island"
    nonisolated static let praduckHermesHostUID = "10000"
    nonisolated static let praduckHermesHostGID = "10000"
    nonisolated static let praduckHermesHostRunPrefix = "sudo setpriv --reuid=10000 --regid=10000 --clear-groups"

    nonisolated static func usesPraduckHermesContainer(_ endpoint: RemoteEndpoint) -> Bool {
        let descriptor = [
            endpoint.displayName,
            endpoint.sshTarget,
            endpoint.detectedHostname ?? "",
            endpoint.detectedHomeDirectory ?? ""
        ].joined(separator: " ").lowercased()
        return descriptor.contains("praduck")
    }

    nonisolated static func remoteHookRuntimeInstallRoot(for endpoint: RemoteEndpoint) -> String {
        usesPraduckHermesContainer(endpoint) ? praduckHermesContainerInstallRoot : endpoint.remoteInstallRoot
    }

    nonisolated static func remoteHookRuntimeSocketPath(for endpoint: RemoteEndpoint) -> String {
        usesPraduckHermesContainer(endpoint)
            ? "\(praduckHermesContainerInstallRoot)/run/agent-hook.sock"
            : endpoint.remoteHookSocketPath
    }

    nonisolated private static func remoteHermesRuntimeSupportPaths(
        endpoint: RemoteEndpoint,
        homeDirectory: String
    ) -> RemoteHermesRuntimeSupportPaths {
        if usesPraduckHermesContainer(endpoint) {
            return RemoteHermesRuntimeSupportPaths(
                runtimeScriptHostPath: "\(praduckHermesHostInstallRoot)/bin/ping_island_remote_runtime.py",
                runtimeScriptContainerPath: "\(praduckHermesContainerInstallRoot)/bin/ping_island_remote_runtime.py",
                gatewayHookDirectoryHostPath: "\(praduckHermesDataRoot)/hooks/ping_island",
                gatewayHookDirectoryContainerPath: "/opt/data/hooks/ping_island",
                sessionsDirectoryContainerPath: "/opt/data/sessions",
                logsDirectoryHostPath: "\(praduckHermesHostInstallRoot)/logs",
                logsDirectoryContainerPath: "\(praduckHermesContainerInstallRoot)/logs",
                role: "Praduck",
                remoteHost: "praduck"
            )
        }

        return RemoteHermesRuntimeSupportPaths(
            runtimeScriptHostPath: "\(endpoint.remoteInstallRoot)/bin/ping_island_remote_runtime.py",
            runtimeScriptContainerPath: "\(endpoint.remoteInstallRoot)/bin/ping_island_remote_runtime.py",
            gatewayHookDirectoryHostPath: "\(homeDirectory)/.hermes/hooks/ping_island",
            gatewayHookDirectoryContainerPath: "\(homeDirectory)/.hermes/hooks/ping_island",
            sessionsDirectoryContainerPath: "\(homeDirectory)/.hermes/sessions",
            logsDirectoryHostPath: "\(endpoint.remoteInstallRoot)/logs",
            logsDirectoryContainerPath: "\(endpoint.remoteInstallRoot)/logs",
            role: "Hermes",
            remoteHost: "hermes"
        )
    }

    nonisolated static func remoteStagedBridgePath(for endpoint: RemoteEndpoint) -> String {
        usesPraduckHermesContainer(endpoint)
            ? "/tmp/PingIslandBridge.\(UUID().uuidString).tmp"
            : "\(endpoint.remoteInstallRoot)/bin/PingIslandBridge.tmp"
    }

    nonisolated static func remoteManagedHookConfigDirectoryPaths(
        endpoint: RemoteEndpoint,
        homeDirectory: String,
        profiles: [ManagedHookClientProfile]
    ) -> [String] {
        profiles
            .flatMap { profile in
                remoteManagedHookDirectoryPaths(for: profile, endpoint: endpoint, homeDirectory: homeDirectory)
            }
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
    }

    nonisolated static func remoteManagedHookConfigPrepareCommand(
        endpoint: RemoteEndpoint,
        homeDirectory: String,
        profiles: [ManagedHookClientProfile]
    ) -> String {
        let directories = remoteManagedHookConfigDirectoryPaths(
            endpoint: endpoint,
            homeDirectory: homeDirectory,
            profiles: profiles
        )
        guard usesPraduckHermesContainer(endpoint) else {
            return "mkdir -p \(directories.map(shellQuote).joined(separator: " "))"
        }
        return """
        sudo install -d -m 755 -o \(praduckHermesHostUID) -g \(praduckHermesHostGID) \(directories.map(shellQuote).joined(separator: " "))
        """
    }

    nonisolated static func remoteManagedHookDirectoryPaths(
        for profile: ManagedHookClientProfile,
        endpoint: RemoteEndpoint,
        homeDirectory: String
    ) -> [String] {
        let configurationPath = remoteManagedPluginDirectoryPath(
            for: profile,
            endpoint: endpoint,
            homeDirectory: homeDirectory
        )

        var paths: [String]
        switch profile.installationKind {
        case .hookDirectory:
            paths = [configurationPath, NSString(string: configurationPath).deletingLastPathComponent]
        case .jsonHooks, .pluginFile:
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

    nonisolated static func remoteManagedPluginDirectoryPath(
        for profile: ManagedHookClientProfile,
        endpoint: RemoteEndpoint,
        homeDirectory: String
    ) -> String {
        guard profile.id == "hermes-hooks", usesPraduckHermesContainer(endpoint) else {
            return remoteConfigurationPath(
                relativePath: profile.configurationRelativePaths[0],
                homeDirectory: homeDirectory
            )
        }
        return "\(praduckHermesDataRoot)/plugins/ping_island"
    }

    nonisolated static func remoteHermesPluginValidationCommand(
        endpoint: RemoteEndpoint,
        pluginDirectoryPath: String
    ) -> String {
        if usesPraduckHermesContainer(endpoint) {
            return """
            sudo docker exec -u hermes hermes bash -lc 'python -m py_compile /opt/data/plugins/ping_island/__init__.py'
            sudo docker exec -u hermes hermes bash -lc 'source /opt/hermes/.venv/bin/activate; cd /opt/hermes; python /opt/hermes/hermes plugins enable ping-island'
            """
        }
        return """
        python3 -m py_compile \(shellQuote("\(pluginDirectoryPath)/__init__.py"))
        if command -v hermes >/dev/null 2>&1; then
          hermes plugins enable ping-island >/dev/null 2>&1 || true
        fi
        """
    }

    nonisolated private static func remoteHermesRuntimePrepareCommand(
        endpoint: RemoteEndpoint,
        paths: RemoteHermesRuntimeSupportPaths
    ) -> String {
        if usesPraduckHermesContainer(endpoint) {
            return """
            sudo install -d -m 755 -o \(praduckHermesHostUID) -g \(praduckHermesHostGID) \(shellQuote("\(praduckHermesHostInstallRoot)/bin")) \(shellQuote(paths.logsDirectoryHostPath)) \(shellQuote(paths.gatewayHookDirectoryHostPath))
            sudo chown -R \(praduckHermesHostUID):\(praduckHermesHostGID) \(shellQuote(paths.gatewayHookDirectoryHostPath)) \(shellQuote(paths.logsDirectoryHostPath))
            """
        }

        return """
        mkdir -p \(shellQuote(NSString(string: paths.runtimeScriptHostPath).deletingLastPathComponent)) \(shellQuote(paths.logsDirectoryHostPath)) \(shellQuote(paths.gatewayHookDirectoryHostPath))
        """
    }

    nonisolated private static func remoteHermesRuntimeValidationCommand(
        endpoint: RemoteEndpoint,
        paths: RemoteHermesRuntimeSupportPaths,
        restartGateway: Bool
    ) -> String {
        if usesPraduckHermesContainer(endpoint) {
            let validation = [
                "python3 -m py_compile \(shellQuote(paths.runtimeScriptContainerPath)) \(shellQuote("\(paths.gatewayHookDirectoryContainerPath)/handler.py"))",
                restartGateway
                    ? "/opt/hermes/.venv/bin/python /opt/hermes/hermes gateway --accept-hooks restart >/dev/null 2>&1 || true"
                    : nil
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            return """
            sudo chmod 755 \(shellQuote(paths.runtimeScriptHostPath))
            sudo docker exec -u hermes hermes sh -lc \(shellQuote(validation))
            """
        }

        let restartCommand = restartGateway ? "\nif command -v hermes >/dev/null 2>&1; then hermes gateway --accept-hooks restart >/dev/null 2>&1 || true; fi" : ""
        return """
        chmod 755 \(shellQuote(paths.runtimeScriptHostPath))
        python3 -m py_compile \(shellQuote(paths.runtimeScriptContainerPath)) \(shellQuote("\(paths.gatewayHookDirectoryContainerPath)/handler.py"))\(restartCommand)
        """
    }

    nonisolated private static func remoteHermesRuntimeWatcherCommand(
        endpoint: RemoteEndpoint,
        paths: RemoteHermesRuntimeSupportPaths
    ) -> String {
        let bridgePath = "\(remoteHookRuntimeInstallRoot(for: endpoint))/bin/ping-island-bridge"
        let socketPath = remoteHookRuntimeSocketPath(for: endpoint)
        let envPrefix = [
            "PING_ISLAND_ROLE=\(shellQuote(paths.role))",
            "PING_ISLAND_REMOTE_HOST=\(shellQuote(paths.remoteHost))",
            "PING_ISLAND_BRIDGE=\(shellQuote(bridgePath))",
            "ISLAND_SOCKET_PATH=\(shellQuote(socketPath))",
            "PING_ISLAND_SESSIONS_DIR=\(shellQuote(paths.sessionsDirectoryContainerPath))",
            "PING_ISLAND_IDLE_DEBOUNCE=15",
            "PING_ISLAND_FINAL_DEBOUNCE=3"
        ].joined(separator: " ")
        let watchPattern = "\(paths.runtimeScriptContainerPath) watch"

        if usesPraduckHermesContainer(endpoint) {
            let command = """
            pkill -f \(shellQuote(watchPattern)) >/dev/null 2>&1 || true
            nohup env \(envPrefix) python3 \(shellQuote(paths.runtimeScriptContainerPath)) watch > \(shellQuote("\(paths.logsDirectoryContainerPath)/hermes-runtime-watch.log")) 2>&1 < /dev/null &
            """
            return """
            sudo docker exec -u hermes hermes sh -lc \(shellQuote(command))
            """
        }

        return """
        pkill -f \(shellQuote(watchPattern)) >/dev/null 2>&1 || true
        nohup env \(envPrefix) python3 \(shellQuote(paths.runtimeScriptContainerPath)) watch > \(shellQuote("\(paths.logsDirectoryContainerPath)/hermes-runtime-watch.log")) 2>&1 < /dev/null &
        """
    }

    nonisolated private static let remoteHermesRuntimeScript = #"""
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

ROLE = os.environ.get("PING_ISLAND_ROLE", "Hermes")
REMOTE_HOST = os.environ.get("PING_ISLAND_REMOTE_HOST", "hermes")
BRIDGE = os.environ.get("PING_ISLAND_BRIDGE", str(Path.home() / ".ping-island/bin/ping-island-bridge"))
SOCKET = os.environ.get("ISLAND_SOCKET_PATH", str(Path.home() / ".ping-island/run/agent-hook.sock"))
SESSIONS_DIR = Path(os.environ.get("PING_ISLAND_SESSIONS_DIR", str(Path.home() / ".hermes/sessions")))
DEBUG_DIR = Path(os.environ.get("PING_ISLAND_DEBUG_DIR", str(Path.home() / ".ping-island/debug")))

COMMON_ARGS = [
    BRIDGE,
    "--source", "claude",
    "--client-kind", "hermes",
    "--client-name", "Hermes",
    "--client-origin", "cli",
    "--client-originator", ROLE,
    "--thread-source", "hermes-runtime",
    "--remote-host", REMOTE_HOST,
]

_stop_timers: dict[str, threading.Timer] = {}
ACTIVE_IDLE_DEBOUNCE_SECONDS = float(os.environ.get("PING_ISLAND_IDLE_DEBOUNCE", "15"))
FINAL_IDLE_DEBOUNCE_SECONDS = float(os.environ.get("PING_ISLAND_FINAL_DEBOUNCE", "3"))


def stable_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    try:
        return json.dumps(value, ensure_ascii=False)
    except Exception:
        return str(value)


def session_id(value: Any) -> str | None:
    text = stable_text(value)
    if not text:
        return None
    return text if text.startswith("hermes-") else f"hermes-{text}"


def write_debug(payload: dict[str, Any]) -> None:
    try:
        DEBUG_DIR.mkdir(parents=True, exist_ok=True)
        with (DEBUG_DIR / f"{time.strftime('%Y%m%d')}.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, default=str) + "\n")
    except Exception:
        pass


def emit(payload: dict[str, Any]) -> None:
    payload = {key: value for key, value in payload.items() if value is not None}
    payload.setdefault("platform", payload.get("connection_transport") or "ssh")
    payload.setdefault("connection_transport", payload.get("platform") or "ssh")
    payload.setdefault("remote_host", REMOTE_HOST)
    write_debug(payload)
    env = os.environ.copy()
    env["ISLAND_SOCKET_PATH"] = SOCKET
    try:
        process = subprocess.Popen(
            COMMON_ARGS,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
            start_new_session=True,
        )
        if process.stdin:
            process.stdin.write(json.dumps(payload, ensure_ascii=False, default=str))
            process.stdin.close()
    except Exception as exc:
        write_debug({"error": repr(exc), "payload": payload})


def schedule_stop(
    sid: str,
    delay: float,
    assistant: str | None = None,
    platform: str = "ssh",
) -> None:
    old_timer = _stop_timers.pop(sid, None)
    if old_timer:
        old_timer.cancel()

    def stop() -> None:
        emit({
            "hook_event_name": "Stop",
            "session_id": sid,
            "last_assistant_message": assistant,
            "platform": platform,
            "connection_transport": platform,
            "completed": True,
        })
        _stop_timers.pop(sid, None)

    timer = threading.Timer(delay, stop)
    _stop_timers[sid] = timer
    timer.start()


def refresh_active(sid: str, platform: str = "ssh", delay: float | None = None) -> None:
    schedule_stop(sid, delay=delay or ACTIVE_IDLE_DEBOUNCE_SECONDS, platform=platform)


def extract_content(obj: dict[str, Any]) -> str | None:
    content = obj.get("content") or obj.get("message") or obj.get("text")
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                parts.append(stable_text(item.get("text") or item.get("content")) or "")
            else:
                parts.append(stable_text(item) or "")
        return stable_text("\n".join(part for part in parts if part))
    return stable_text(content)


def handle_transcript_line(path: Path, line: str) -> None:
    try:
        obj = json.loads(line)
    except Exception:
        return
    if not isinstance(obj, dict):
        return

    role = stable_text(obj.get("role") or obj.get("type"))
    if role == "session_meta":
        return

    sid = session_id(path.stem)
    if not sid:
        return

    text = extract_content(obj)
    if role == "user":
        emit({
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
            "prompt": text,
            "message": text,
            "platform": "ssh",
            "connection_transport": "ssh",
            "cwd": os.environ.get("PWD") or str(SESSIONS_DIR.parent),
        })
        refresh_active(sid, platform="ssh")
    elif role == "tool":
        emit({
            "hook_event_name": "PreToolUse",
            "session_id": sid,
            "tool_name": "Tool",
            "message": text[:500] if text else None,
            "platform": "ssh",
            "connection_transport": "ssh",
        })
        refresh_active(sid, platform="ssh")
    elif role == "assistant":
        if text:
            emit({
                "hook_event_name": "Notification",
                "session_id": sid,
                "notification_type": "assistant_message",
                "message": text,
                "platform": "ssh",
                "connection_transport": "ssh",
            })
        schedule_stop(sid, delay=FINAL_IDLE_DEBOUNCE_SECONDS, assistant=text, platform="ssh")


def watch_transcripts() -> None:
    offsets: dict[Path, int] = {}
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    for path in SESSIONS_DIR.glob("*.jsonl"):
        try:
            offsets[path] = path.stat().st_size
        except OSError:
            pass

    write_debug({"watcher": "started", "sessions_dir": str(SESSIONS_DIR), "remote_host": REMOTE_HOST})
    while True:
        try:
            paths = sorted(SESSIONS_DIR.glob("*.jsonl"), key=lambda item: item.stat().st_mtime)
            for path in paths:
                try:
                    size = path.stat().st_size
                    position = offsets.get(path, 0)
                    if size < position:
                        position = 0
                    if size == position:
                        offsets[path] = position
                        continue
                    with path.open("r", encoding="utf-8", errors="ignore") as handle:
                        handle.seek(position)
                        for line in handle:
                            handle_transcript_line(path, line)
                        offsets[path] = handle.tell()
                except Exception as exc:
                    write_debug({"watcher_error": repr(exc), "path": str(path)})
        except Exception as exc:
            write_debug({"watcher_loop_error": repr(exc)})
        time.sleep(1.0)


def gateway_handle(event_type: str, context: dict[str, Any]) -> None:
    sid = session_id(
        context.get("session_id")
        or context.get("session_key")
        or context.get("thread_id")
        or context.get("user_id")
    )
    if not sid:
        return

    platform = stable_text(context.get("platform") or context.get("transport")) or "discord"
    if event_type == "session:start":
        emit({
            "hook_event_name": "SessionStart",
            "session_id": sid,
            "platform": platform,
            "connection_transport": platform,
        })
        refresh_active(sid, platform=platform)
    elif event_type == "agent:start":
        message = stable_text(context.get("message") or context.get("prompt"))
        emit({
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
            "prompt": message,
            "message": message,
            "platform": platform,
            "connection_transport": platform,
        })
        refresh_active(sid, platform=platform)
    elif event_type == "agent:step":
        names = context.get("tool_names") or []
        tool = names[0] if isinstance(names, list) and names else "Tool"
        emit({
            "hook_event_name": "PreToolUse",
            "session_id": sid,
            "tool_name": stable_text(tool) or "Tool",
            "platform": platform,
            "connection_transport": platform,
        })
        refresh_active(sid, platform=platform)
    elif event_type == "agent:end":
        response = stable_text(context.get("response") or context.get("message"))
        if response:
            emit({
                "hook_event_name": "Notification",
                "session_id": sid,
                "notification_type": "assistant_message",
                "message": response,
                "platform": platform,
                "connection_transport": platform,
            })
        schedule_stop(sid, delay=FINAL_IDLE_DEBOUNCE_SECONDS, assistant=response, platform=platform)
    elif event_type in ("session:end", "session:reset"):
        emit({
            "hook_event_name": "SessionEnd",
            "session_id": sid,
            "platform": platform,
            "connection_transport": platform,
        })


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "watch":
        watch_transcripts()
    else:
        payload = json.load(sys.stdin) if not sys.stdin.isatty() else {}
        emit(payload)
"""#

    nonisolated private static let remoteHermesGatewayHandlerScript = #"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path

if Path("/opt/data/ping-island/bin/ping_island_remote_runtime.py").exists():
    os.environ.setdefault("PING_ISLAND_RUNTIME", "/opt/data/ping-island/bin/ping_island_remote_runtime.py")
    os.environ.setdefault("PING_ISLAND_ROLE", "Praduck")
    os.environ.setdefault("PING_ISLAND_REMOTE_HOST", "praduck")
    os.environ.setdefault("PING_ISLAND_BRIDGE", "/opt/data/ping-island/bin/ping-island-bridge")
    os.environ.setdefault("ISLAND_SOCKET_PATH", "/opt/data/ping-island/run/agent-hook.sock")
    os.environ.setdefault("PING_ISLAND_SESSIONS_DIR", "/opt/data/sessions")
elif Path("/home/joseph/.ping-island/bin/ping_island_remote_runtime.py").exists():
    os.environ.setdefault("PING_ISLAND_RUNTIME", "/home/joseph/.ping-island/bin/ping_island_remote_runtime.py")
    os.environ.setdefault("PING_ISLAND_ROLE", "Hermes")
    os.environ.setdefault("PING_ISLAND_REMOTE_HOST", "hermes")
    os.environ.setdefault("PING_ISLAND_BRIDGE", "/home/joseph/.ping-island/bin/ping-island-bridge")
    os.environ.setdefault("ISLAND_SOCKET_PATH", "/home/joseph/.ping-island/run/agent-hook.sock")
    os.environ.setdefault("PING_ISLAND_SESSIONS_DIR", "/home/joseph/.hermes/sessions")

_candidates = []
_env_path = os.environ.get("PING_ISLAND_RUNTIME")
if _env_path:
    _candidates.append(Path(_env_path))
_candidates.extend([
    Path.home() / ".ping-island/bin/ping_island_remote_runtime.py",
    Path("/opt/data/ping-island/bin/ping_island_remote_runtime.py"),
    Path("/home/joseph/.ping-island/bin/ping_island_remote_runtime.py"),
])
_runtime_path = next((path for path in _candidates if path.exists()), _candidates[0])
_spec = importlib.util.spec_from_file_location("ping_island_remote_runtime", _runtime_path)
_runtime = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_runtime)


async def handle(event_type, context):
    try:
        _runtime.gateway_handle(event_type, context or {})
    except Exception:
        return None
"""#

    nonisolated private static let remoteHermesGatewayHookYAML = #"""
name: ping-island-runtime
description: Forward Hermes gateway lifecycle events to Ping Island
events:
  - session:start
  - agent:start
  - agent:step
  - agent:end
  - session:end
  - session:reset
"""#

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
    nonisolated func uniquedPreservingOrder() -> [Element] {
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
        case .unsupportedRemotePlatform(let detail):
            return detail
        case .remoteBridgeDownloadFailed(let detail):
            return detail
        case .sshFailure(let detail):
            return detail
        }
    }
}

private final class RemoteAttachConnector {
    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Remote")

    private let endpoint: RemoteEndpoint
    private let password: String?
    private let onMessage: @Sendable (RemoteInboundMessage) async -> Void
    private let onDisconnect: @Sendable (Error?) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private let disconnectLock = NSLock()
    private var didFinishDisconnect = false
    private var suppressDisconnectCallback = false

    init(
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

    func start() async throws {
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let bridgeCommand = "\(shellQuote("\(endpoint.remoteInstallRoot)/bin/ping-island-bridge")) --mode remote-agent-attach --control-socket \(shellQuote(endpoint.remoteControlSocketPath))"
        let remoteCommand = RemoteConnectorManager.usesPraduckHermesContainer(endpoint)
            ? "\(RemoteConnectorManager.praduckHermesHostRunPrefix) \(bridgeCommand)"
            : bridgeCommand
        let process = try RemoteSSHCommandRunner.makeSSHProcess(
            target: endpoint.sshTarget,
            port: endpoint.sshPort,
            password: password,
            remoteCommand: remoteCommand,
            acceptNewHostKey: true
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()
        Self.logger.notice(
            "Remote attach process launched endpoint=\(self.endpoint.id.uuidString, privacy: .public) target=\(self.endpoint.sshTarget, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
        )
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let connector = self else { return }
            Task { @MainActor in
                connector.drainStdout(from: handle)
            }
        }
        process.terminationHandler = { [weak self] process in
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error: Error? = if process.terminationStatus == 0 {
                nil
            } else {
                RemoteConnectorError.sshFailure(
                    stderr.isEmpty ? "SSH attach 已断开" : "SSH attach 已断开: \(Self.excerpt(stderr))"
                )
            }

            if process.terminationStatus == 0 {
                Self.logger.notice(
                    "Remote attach process exited cleanly endpoint=\(self?.endpoint.id.uuidString ?? "unknown", privacy: .public) status=\(process.terminationStatus, privacy: .public)"
                )
            } else {
                Self.logger.error(
                    "Remote attach process exited endpoint=\(self?.endpoint.id.uuidString ?? "unknown", privacy: .public) status=\(process.terminationStatus, privacy: .public) stderr=\(Self.excerpt(stderr), privacy: .public)"
                )
            }

            if let self {
                Task { @MainActor in
                    self.finishDisconnect(error)
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
        stdinHandle = nil
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
        let data = try JSONEncoder().encode(message) + Data("\n".utf8)
        try stdinHandle?.write(contentsOf: data)
    }

    private func drainStdout(from handle: FileHandle) {
        do {
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finishDisconnect(nil)
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
                Task {
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

private enum RemoteInboundMessage: Decodable {
    case hello(RemoteDaemonHello)
    case hookEvent(RemoteHookEventMessage)

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
        default:
            throw RemoteConnectorError.invalidRemoteMessage
        }
    }
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
            acceptNewHostKey: true,
            allowFailure: true
        )
        return Data(result.stdout.utf8)
    }

    static func writeRemoteFile(target: String, port: Int, remotePath: String, contents: Data, password: String?) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-remote-\(UUID().uuidString)")
        try contents.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await copyFile(localURL: tempURL, remoteTarget: target, port: port, remotePath: remotePath, password: password)
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
        let archiveAssetName = RemoteConnectorManager.remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: normalizedArch)
        let cacheDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island", isDirectory: true)
            .appendingPathComponent("remote-cache", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let cachedBinaryURL = cacheDirectory.appendingPathComponent(binaryAssetName)
        let cachedArchiveURL = cacheDirectory.appendingPathComponent(archiveAssetName)

        if fileManager.isReadableFile(atPath: cachedBinaryURL.path) {
            return cachedBinaryURL
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        if fileManager.isReadableFile(atPath: cachedArchiveURL.path) {
            try await extractLinuxBridgeArchive(
                archiveURL: cachedArchiveURL,
                expectedBinaryName: binaryAssetName,
                destinationURL: cachedBinaryURL
            )
            return cachedBinaryURL
        }

        let releaseURLString = "https://github.com/erha19/ping-island/releases/download/v\(version)/\(archiveAssetName)"
        guard let releaseURL = URL(string: releaseURLString) else {
            throw RemoteConnectorError.remoteBridgeDownloadFailed(
                AppLocalization.format("Linux 远程 bridge 下载地址无效：%@", releaseURLString)
            )
        }

        let (downloadedURL, response) = try await URLSession.shared.download(from: releaseURL)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw RemoteConnectorError.remoteBridgeDownloadFailed(
                AppLocalization.format("无法从 GitHub Release 下载 Linux 远程 bridge（HTTP %lld）", (response as? HTTPURLResponse)?.statusCode ?? -1)
            )
        }

        if fileManager.fileExists(atPath: cachedArchiveURL.path) {
            try fileManager.removeItem(at: cachedArchiveURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: cachedArchiveURL)
        try await extractLinuxBridgeArchive(
            archiveURL: cachedArchiveURL,
            expectedBinaryName: binaryAssetName,
            destinationURL: cachedBinaryURL
        )
        return cachedBinaryURL
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
