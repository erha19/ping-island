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
    private var pendingRequests: [String: PendingRemoteRequest] = [:]
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

        for endpoint in endpoints where endpoint.authMode == .publicKey {
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
    func addEndpoint(displayName: String, sshTarget: String) -> RemoteEndpoint {
        let endpoint = RemoteEndpoint(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            sshTarget: sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
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
        pendingRequests = pendingRequests.filter { _, value in
            value.endpointID != id
        }
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
                        detail: "远程连接失败",
                        lastError: error.localizedDescription,
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
        connectors.removeValue(forKey: endpointID)?.stop()
        pendingRequests = pendingRequests.filter { _, request in
            request.endpointID != endpointID
        }
        setState(for: endpointID, phase: .disconnected, detail: "已断开远程转发连接")
    }

    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        guard let pending = pendingRequests[toolUseId],
              let connector = connectors[pending.endpointID] else {
            return
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

    func respondToIntervention(
        toolUseId: String,
        decision: String,
        updatedInput: [String: Any]?,
        reason: String? = nil
    ) {
        guard let pending = pendingRequests[toolUseId],
              let connector = connectors[pending.endpointID] else {
            return
        }

        let encodedInput = updatedInput?.mapValues { RemoteJSONValue.fromFoundationObject($0) }
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

    private func cleanupLocalAttachProcesses(endpointID: UUID) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }

        let escapedTarget = NSRegularExpression.escapedPattern(for: endpoint.sshTarget)
        let escapedControlSocket = NSRegularExpression.escapedPattern(for: endpoint.remoteControlSocketPath)
        let pattern = "ssh .*\(escapedTarget).*(remote-agent-attach|--mode remote-agent-attach).*\(escapedControlSocket)"

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
                toolUseId: payload.toolUseID,
                notificationType: payload.notificationType,
                message: payload.message,
                ingress: .remoteBridge
            )

            if payload.expectsResponse, let toolUseID = payload.toolUseID {
                pendingRequests[toolUseID] = PendingRemoteRequest(
                    endpointID: endpointID,
                    requestID: payload.requestID,
                    sessionID: payload.sessionID
                )
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
            remotePath: stagedBridgePath,
            password: password
        )
        logger.debug(
            "Remote bootstrap copied staged bridge endpoint=\(endpoint.id.uuidString, privacy: .public) remotePath=\(stagedBridgePath, privacy: .public)"
        )

        let launcherScript = """
        #!/bin/sh
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        exec "$SCRIPT_DIR/PingIslandBridge" "$@"
        """
        try await RemoteSSHCommandRunner.writeRemoteFile(
            target: endpoint.sshTarget,
            remotePath: "\(endpoint.remoteInstallRoot)/bin/ping-island-bridge",
            contents: launcherScript.data(using: .utf8) ?? Data(),
            password: password
        )
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
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
                        remotePath: remoteActivationPath,
                        contents: updatedActivationData,
                        password: password
                    )
                }
            case .pluginFile, .pluginDirectory:
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

    private func ensureRemoteAgentRunning(endpointID: UUID, password: String?) async throws {
        guard let endpoint = endpoint(for: endpointID) else { return }
        logger.notice(
            "Remote agent ensure/start endpoint=\(endpoint.id.uuidString, privacy: .public) target=\(endpoint.sshTarget, privacy: .public) controlSocket=\(endpoint.remoteControlSocketPath, privacy: .public)"
        )
        let command = """
        mkdir -p \(quoted(endpoint.remoteInstallRoot))/run \(quoted(endpoint.remoteInstallRoot))/logs
        if [ -S \(quoted(endpoint.remoteControlSocketPath)) ]; then
          exit 0
        fi
        nohup \(quoted(endpoint.remoteInstallRoot))/bin/ping-island-bridge --mode remote-agent-service --hook-socket \(quoted(endpoint.remoteHookSocketPath)) --control-socket \(quoted(endpoint.remoteControlSocketPath)) > \(quoted(endpoint.remoteInstallRoot))/logs/remote-agent.log 2>&1 &
        sleep 1
        """
        _ = try await RemoteSSHCommandRunner.runSSH(
            target: endpoint.sshTarget,
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

        guard let sshTarget = sanitizedNonEmpty(endpoint?.sshTarget) else {
            return nil
        }

        let withoutUser = sshTarget.split(separator: "@").last.map(String.init) ?? sshTarget
        if withoutUser.hasPrefix("["),
           let closingBracketIndex = withoutUser.firstIndex(of: "]") {
            let bracketHost = String(withoutUser[withoutUser.index(after: withoutUser.startIndex)..<closingBracketIndex])
            return sanitizedNonEmpty(bracketHost)
        }

        if let colonIndex = withoutUser.lastIndex(of: ":"),
           withoutUser[withoutUser.index(after: colonIndex)...].allSatisfy(\.isNumber) {
            return sanitizedNonEmpty(String(withoutUser[..<colonIndex]))
        }

        return sanitizedNonEmpty(withoutUser)
    }

    private func updateEndpoint(_ endpoint: RemoteEndpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else {
            return
        }
        endpoints[index] = endpoint
        persistEndpoints()
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

    nonisolated static func remoteBootstrapInstallCommand(
        installRoot: String,
        stagedBridgePath: String
    ) -> String {
        """
        mv -f \(shellQuote(stagedBridgePath)) \(shellQuote("\(installRoot)/bin/PingIslandBridge"))
        chmod 755 \(shellQuote("\(installRoot)/bin/PingIslandBridge")) \(shellQuote("\(installRoot)/bin/ping-island-bridge"))
        """
    }

    nonisolated static func remoteManagedHookProfiles() -> [ManagedHookClientProfile] {
        let supportedProfileIDs: Set<String> = [
            "claude-hooks",
            "codex-hooks",
            "qwen-code-hooks",
            "openclaw-hooks",
            "qoder-hooks",
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
        case .jsonHooks, .pluginFile, .pluginDirectory:
            paths = [NSString(string: configurationPath).deletingLastPathComponent]
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

private struct PendingRemoteRequest {
    let endpointID: UUID
    let requestID: UUID
    let sessionID: String
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
        addQuery[kSecAttrComment as String] = endpoint.sshTarget
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

    static func probe(target: String, password: String?) async throws -> RemoteHostProbe {
        let command = #"printf "%s\n" "$USER" "$HOSTNAME" "$HOME"; uname -s; uname -m; command -v claude >/dev/null 2>&1 && echo "__PING_ISLAND_HAS_CLAUDE__=1" || echo "__PING_ISLAND_HAS_CLAUDE__=0"; command -v tmux >/dev/null 2>&1 && echo "__PING_ISLAND_HAS_TMUX__=1" || echo "__PING_ISLAND_HAS_TMUX__=0""#
        logger.notice(
            "SSH probe starting target=\(target, privacy: .public) hasPassword=\(password != nil, privacy: .public)"
        )
        let result = try await runSSH(
            target: target,
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
        let fingerprint = localKnownHostFingerprint(for: target)
        logger.notice(
            "SSH probe completed target=\(target, privacy: .public) username=\(lines[0], privacy: .public) hostname=\(lines[1], privacy: .public) os=\(lines[3], privacy: .public) arch=\(lines[4], privacy: .public)"
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

    static func readRemoteFile(target: String, remotePath: String, password: String?) async throws -> Data {
        let result = try await runSSH(
            target: target,
            password: password,
            remoteCommand: "cat \(shellQuote(remotePath))",
            acceptNewHostKey: true,
            allowFailure: true
        )
        return Data(result.stdout.utf8)
    }

    static func writeRemoteFile(target: String, remotePath: String, contents: Data, password: String?) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-remote-\(UUID().uuidString)")
        try contents.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await copyFile(localURL: tempURL, remoteTarget: target, remotePath: remotePath, password: password)
    }

    static func copyFile(localURL: URL, remoteTarget: String, remotePath: String, password: String?) async throws {
        logger.notice(
            "SCP copy starting target=\(remoteTarget, privacy: .public) localPath=\(localURL.path, privacy: .public) remotePath=\(remotePath, privacy: .public) hasPassword=\(password != nil, privacy: .public)"
        )
        let process = try makeSecureCopyProcess(
            localURL: localURL,
            remoteTarget: remoteTarget,
            remotePath: remotePath,
            password: password
        )
        let result = try await run(process: process)
        guard result.exitCode == 0 else {
            throw RemoteConnectorError.sshFailure(result.stderr.isEmpty ? "SCP 复制失败" : result.stderr)
        }
        logger.debug(
            "SCP copy completed target=\(remoteTarget, privacy: .public) remotePath=\(remotePath, privacy: .public)"
        )
    }

    static func runSSH(
        target: String,
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool,
        allowFailure: Bool = false
    ) async throws -> SSHExecutionResult {
        logger.debug(
            "SSH exec starting target=\(target, privacy: .public) hasPassword=\(password != nil, privacy: .public) acceptNewHostKey=\(acceptNewHostKey, privacy: .public) allowFailure=\(allowFailure, privacy: .public) command=\(excerpt(remoteCommand), privacy: .public)"
        )
        let process = try makeSSHProcess(
            target: target,
            password: password,
            remoteCommand: remoteCommand,
            acceptNewHostKey: acceptNewHostKey
        )
        let result = try await run(process: process)
        if result.exitCode == 0 {
            logger.debug(
                "SSH exec completed target=\(target, privacy: .public) exitCode=\(result.exitCode, privacy: .public) stdout=\(excerpt(result.stdout), privacy: .public) stderr=\(excerpt(result.stderr), privacy: .public)"
            )
        } else {
            logger.error(
                "SSH exec failed target=\(target, privacy: .public) exitCode=\(result.exitCode, privacy: .public) stdout=\(excerpt(result.stdout), privacy: .public) stderr=\(excerpt(result.stderr), privacy: .public)"
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
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(
            target: target,
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
        remotePath: String,
        password: String?
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = scpArguments(
            localPath: localURL.path,
            remoteTarget: remoteTarget,
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
        password: String?,
        remoteCommand: String,
        acceptNewHostKey: Bool
    ) -> [String] {
        var arguments = commonSSHOptions(password: password, acceptNewHostKey: acceptNewHostKey)
        arguments.append(target)
        arguments.append(remoteCommand)
        return arguments
    }

    private static func scpArguments(
        localPath: String,
        remoteTarget: String,
        remotePath: String,
        password: String?
    ) -> [String] {
        var arguments = commonSSHOptions(password: password, acceptNewHostKey: true)
        arguments.append(localPath)
        arguments.append("\(remoteTarget):\(remotePath)")
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

    private static func localKnownHostFingerprint(for target: String) -> String? {
        let host = target.split(separator: "@").last.map(String.init) ?? target
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
        let normalizedArch: String
        switch architecture.lowercased() {
        case "x86_64", "amd64":
            normalizedArch = "x86_64"
        default:
            throw RemoteConnectorError.unsupportedRemotePlatform(
                AppLocalization.format(
                    "当前 Linux 远程 bridge 暂不支持架构 %@",
                    architecture
                )
            )
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let assetName = "PingIslandBridge-linux-\(normalizedArch)"
        let cacheDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island", isDirectory: true)
            .appendingPathComponent("remote-cache", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let cachedURL = cacheDirectory.appendingPathComponent(assetName)

        if fileManager.isReadableFile(atPath: cachedURL.path) {
            return cachedURL
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let releaseURLString = "https://github.com/erha19/ping-island/releases/download/v\(version)/\(assetName)"
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

        if fileManager.fileExists(atPath: cachedURL.path) {
            try fileManager.removeItem(at: cachedURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: cachedURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedURL.path)
        return cachedURL
    }
}
