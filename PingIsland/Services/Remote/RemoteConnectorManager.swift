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
                } else {
                    logger.notice(
                        "Remote bootstrap skipped endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) reason=reuse_existing_install"
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
        endpoint.remoteInstallRoot = resolvedRemotePath(endpoint.remoteInstallRoot, homeDirectory: probe.homeDirectory)
        endpoint.remoteHookSocketPath = resolvedRemotePath(endpoint.remoteHookSocketPath, homeDirectory: probe.homeDirectory)
        endpoint.remoteControlSocketPath = resolvedRemotePath(endpoint.remoteControlSocketPath, homeDirectory: probe.homeDirectory)
        updateEndpoint(endpoint)
        logger.debug(
            "Remote probe applied endpoint=\(endpoint.id.uuidString, privacy: .public) installRoot=\(endpoint.remoteInstallRoot, privacy: .public) hookSocket=\(endpoint.remoteHookSocketPath, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
    }

    private func bootstrapRemoteAgent(endpointID: UUID, password: String?, probe: RemoteHostProbe) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        let bridgeBinaryURL = try await assetResolver.resolveBinaryURL(for: probe)
        let stagedBridgePath = "\(endpoint.remoteInstallRoot)/bin/PingIslandBridge.tmp"
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
        try await RemoteSSHCommandRunner.writeRemoteFile(
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
                    try await RemoteSSHCommandRunner.writeRemoteFile(
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
                let remoteDirectoryPath = Self.remoteConfigurationPath(
                    relativePath: profile.configurationRelativePaths[0],
                    homeDirectory: probe.homeDirectory
                )
                let remoteFiles = HookInstaller.managedPluginDirectoryFiles(for: profile)
                logger.debug(
                    "Remote bootstrap preparing plugin directory endpoint=\(endpoint.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) remotePath=\(remoteDirectoryPath, privacy: .public) fileCount=\(remoteFiles.count, privacy: .public)"
                )
                for (name, content) in remoteFiles {
                    try await RemoteSSHCommandRunner.writeRemoteFile(
                        target: endpoint.sshTarget,
                        port: endpoint.sshPort,
                        remotePath: "\(remoteDirectoryPath)/\(name)",
                        contents: Data(content.utf8),
                        password: password
                    )
                }
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
        installRoot: String,
        controlSocketPath: String,
        hookSocketPath: String,
        configDirectoryPaths: [String]
    ) -> String {
        let agentPattern = "\(installRoot)/bin/[P]ingIslandBridge --mode remote-agent-service"
        let directoryList = ([ "\(installRoot)/bin", "\(installRoot)/run", "\(installRoot)/logs", "$HOME/.claude" ] + configDirectoryPaths)
            .uniquedPreservingOrder()
            .map(shellQuote)
            .joined(separator: " ")
        return """
        mkdir -p \(directoryList)
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
        installRoot: String,
        stagedBridgePath: String
    ) -> String {
        """
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
            "qoder-cli-hooks",
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

        try process.run()
        Self.logger.notice(
            "Remote attach process launched endpoint=\(self.endpoint.id.uuidString, privacy: .public) target=\(self.endpoint.sshTarget, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
        )
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.drainStdout(from: handle)
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
