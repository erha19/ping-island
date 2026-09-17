import XCTest
@testable import Ping_Island

final class RemoteHookConfigurationTests: XCTestCase {
    private final class DisconnectSignals: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @MainActor
    func testImmediatePermissionEPIPEPreservesTerminationCallbackForReconnect() async throws {
        let pipe = Pipe()
        let writer = try RemoteControlWriter(handle: pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()
        let signals = DisconnectSignals()
        let connector = RemoteAttachConnector(controlWriter: writer, onDisconnect: { _ in signals.record() })
        defer { connector.stop() }
        var failure: Error?
        await RemoteConnectorManager.deliverImmediatePermissionResponse(
            requestID: UUID(), decision: "defer", connector: connector
        ) { failure = $0 }
        XCTAssertEqual((failure as? POSIXError)?.code, .EPIPE)
        XCTAssertEqual(signals.count, 0, "EPIPE must wait for SSH's authoritative termination result")
        connector.processTerminated(POSIXError(.EPIPE))
        XCTAssertEqual(signals.count, 1, "The disconnect callback that drives reconnect must remain armed")
        connector.processTerminated(POSIXError(.EPIPE))
        XCTAssertEqual(signals.count, 1)
    }

    @MainActor
    func testDisconnectAtDeferredLedgerEntryDoesNotRecreatePendingOrConsumeReplay() async {
        let ledger = RemoteProcessedEventLedger()
        var attempts = RemoteConnectionAttemptRegistry()
        let endpointID = UUID()
        let requestID = UUID()
        let generation = attempts.begin(endpointID: endpointID)
        var pendingRequests: [UUID] = []
        var ingestions = 0
        var acknowledgements = 0
        var validityChecks = 0
        let processed = await ledger.processOnce(
            endpointID: endpointID, requestID: requestID,
            isCurrent: {
                validityChecks += 1
                if validityChecks == 2 {
                    // Deterministically disconnect when the deferred Task enters,
                    // after admission but before insertion or state ingestion.
                    attempts.invalidate(endpointID: endpointID)
                    pendingRequests.removeAll()
                }
                return attempts.isCurrent(endpointID: endpointID, generation: generation)
            }
        ) {
            guard attempts.isCurrent(endpointID: endpointID, generation: generation) else { return false }
            pendingRequests.append(requestID)
            ingestions += 1
            return true
        }
        if processed { acknowledgements += 1 }
        XCTAssertFalse(processed)
        XCTAssertTrue(pendingRequests.isEmpty)
        XCTAssertEqual(ingestions, 0)
        XCTAssertEqual(acknowledgements, 0)

        let reconnectedGeneration = attempts.begin(endpointID: endpointID)
        let replayProcessed = await ledger.processOnce(
            endpointID: endpointID, requestID: requestID,
            isCurrent: { attempts.isCurrent(endpointID: endpointID, generation: reconnectedGeneration) }
        ) {
            pendingRequests.append(requestID)
            ingestions += 1
            return true
        }
        XCTAssertTrue(replayProcessed)
        XCTAssertEqual(pendingRequests, [requestID])
        XCTAssertEqual(ingestions, 1, "The discarded stale task must not mark the request completed")

        let rejectedAtInsertion = UUID()
        let rejected = await ledger.processOnce(endpointID: endpointID, requestID: rejectedAtInsertion) { false }
        XCTAssertFalse(rejected)
        let retried = await ledger.processOnce(endpointID: endpointID, requestID: rejectedAtInsertion) { true }
        XCTAssertTrue(retried)
    }

    func testRemoteCodexImmediateResponsesRequireExplicitBypassPermission() {
        XCTAssertEqual(RemoteConnectorManager.immediateRemoteCodexPermissionDecision(
            provider: "codex", eventType: "PermissionRequest", permissionMode: "bypassPermissions"
        ), "approve")
        for event in ["PreToolUse", "PostToolUse", "Stop", "UserPromptSubmit"] {
            XCTAssertFalse(RemoteConnectorManager.isRemoteCodexBypassPermissionRequest(
                provider: "codex", eventType: event, permissionMode: "bypassPermissions"
            ))
            XCTAssertNil(RemoteConnectorManager.immediateRemoteCodexPermissionDecision(
                provider: "codex", eventType: event, permissionMode: "bypassPermissions"
            ))
        }
        XCTAssertNil(RemoteConnectorManager.immediateRemoteCodexPermissionDecision(
            provider: "codex", eventType: "PermissionRequest", permissionMode: "default"
        ))
    }

    @MainActor
    func testControlWriterBackpressureIsBoundedAndCancellableWithoutBlockingMainActor() async throws {
        let pipe = Pipe()
        let writer = try RemoteControlWriter(handle: pipe.fileHandleForWriting, maximumBytes: 1_024 * 1_024)
        defer { writer.cancel() }
        do {
            try await writer.write(Data(repeating: 1, count: 2 * 1_024 * 1_024))
            XCTFail("Oversized frames must be rejected")
        } catch { XCTAssertEqual(error as? RemoteControlWriter.Failure, .bufferLimitExceeded) }
        let pending = Task { try await writer.write(Data(repeating: 2, count: 1_024 * 1_024)) }
        for _ in 0..<1_000 {
            if writer.bufferedByteCount > 0 { break }
            await Task.yield()
        }
        XCTAssertGreaterThan(writer.bufferedByteCount, 0)
        let mainActorProgress = await Task { @MainActor in true }.value
        XCTAssertTrue(mainActorProgress)
        writer.cancel()
        do { try await pending.value; XCTFail("Cancelled backpressure must fail the frame") }
        catch { XCTAssertNotNil(error as? RemoteControlWriter.Failure) }
        XCTAssertEqual(writer.bufferedByteCount, 0)
    }

    func testControlWriterTimesOutWhenPeerDoesNotRead() async throws {
        let pipe = Pipe()
        let writer = try RemoteControlWriter(handle: pipe.fileHandleForWriting, timeout: 0.05)
        defer { writer.cancel() }
        do { try await writer.write(Data(repeating: 1, count: 1_024 * 1_024)); XCTFail("Expected write timeout") }
        catch { XCTAssertEqual(error as? RemoteControlWriter.Failure, .timedOut) }
    }

    @MainActor
    func testDisconnectGenerationPreventsLaterReconnectSteps() async throws {
        var attempts = RemoteConnectionAttemptRegistry()
        let endpointID = UUID()
        let generation = attempts.begin(endpointID: endpointID)
        let probe = DeliveryProbe()
        let attempt = Task {
            try await RemoteConnectorManager.runConnectionSteps([
                { await probe.process() }, { await probe.record("attached") }
            ], isCurrent: { attempts.isCurrent(endpointID: endpointID, generation: generation) })
        }
        for _ in 0..<1_000 {
            if !(await probe.steps).isEmpty { break }
            await Task.yield()
        }
        attempts.invalidate(endpointID: endpointID)
        await probe.finish()
        do { try await attempt.value; XCTFail("Stale attempts must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let steps = await probe.steps
        XCTAssertFalse(steps.contains("attached"))
    }

    @MainActor
    func testLostAcknowledgementReplayProcessesOncePerEndpointAndRequest() async {
        let ledger = RemoteProcessedEventLedger(capacity: 2)
        let endpointID = UUID()
        let requestID = UUID()
        var steps: [String] = []
        for _ in 0..<2 {
            await ledger.processOnce(endpointID: endpointID, requestID: requestID) { steps.append("ingested"); return true }
            steps.append("ack")
        }
        XCTAssertEqual(steps, ["ingested", "ack", "ack"])
        await ledger.processOnce(endpointID: UUID(), requestID: requestID) { steps.append("other endpoint"); return true }
        XCTAssertEqual(steps.last, "other endpoint")

        let probe = DeliveryProbe()
        let pendingID = UUID()
        let first = Task { await ledger.processOnce(endpointID: endpointID, requestID: pendingID) { await probe.process(); return true } }
        for _ in 0..<1_000 {
            if !(await probe.steps).isEmpty { break }
            await Task.yield()
        }
        let replay = Task {
            await ledger.processOnce(endpointID: endpointID, requestID: pendingID) { await probe.record("duplicate ingestion"); return true }
            await probe.record("replay ack")
        }
        await Task.yield()
        let before = await probe.steps
        XCTAssertFalse(before.contains("replay ack"))
        await probe.finish()
        await first.value
        await replay.value
        let after = await probe.steps
        XCTAssertEqual(after, ["started", "ingested", "replay ack"])
    }

    func testAuthenticationRejectionSuspendsRetriesUntilExplicitConnect() {
        for message in ["dev@example.test: Permission denied (publickey,password).", "Authentication failed", "Too many authentication failures"] {
            XCTAssertTrue(RemoteAuthenticationFailure.isRejection(stderr: message, exitCode: 255))
        }
        XCTAssertFalse(RemoteAuthenticationFailure.isRejection(stderr: "chmod: Permission denied", exitCode: 1))
        XCTAssertFalse(RemoteAuthenticationFailure.isRejection(stderr: "Connection timed out", exitCode: 255))
        var attempts = RemoteConnectionAttemptRegistry()
        let endpointID = UUID()
        let previous = attempts.begin(endpointID: endpointID)
        attempts.suspendAfterAuthenticationRejection(endpointID: endpointID)
        XCTAssertFalse(attempts.isCurrent(endpointID: endpointID, generation: previous))
        XCTAssertFalse(attempts.allowsAutomaticRetry(endpointID: endpointID))
        let explicit = attempts.begin(endpointID: endpointID, explicit: true)
        XCTAssertTrue(attempts.isCurrent(endpointID: endpointID, generation: explicit))
        XCTAssertFalse(attempts.isCurrent(endpointID: endpointID, generation: previous))
    }

    private actor DeliveryProbe {
        private(set) var steps: [String] = []
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func process() async {
            steps.append("started")
            if !released { await withCheckedContinuation { continuation = $0 } }
            steps.append("ingested")
        }
        func record(_ step: String) { steps.append(step) }
        func finish() { released = true; continuation?.resume(); continuation = nil }
    }

    private func deliveryEvent(clientInfo: SessionClientInfo = .codexCLI()) -> HookEvent {
        HookEvent(
            sessionId: "remote-ack-test", cwd: "/work/project", event: "PreToolUse", status: "processing",
            provider: .codex, clientInfo: clientInfo, pid: nil, tty: nil, tool: "Bash", toolInput: nil,
            toolUseId: "tool-1", notificationType: nil, message: nil, ingress: .remoteBridge,
            bridgeExpectsResponse: false
        )
    }

    @MainActor
    func testProcessedEventAcknowledgementWaitsForAsyncIngestion() async {
        let probe = DeliveryProbe()
        let event = deliveryEvent()
        let delivery = Task {
            await RemoteConnectorManager.deliverRemoteHookEvent(event, onEvent: { _ in
                await probe.process()
            }) {
                await probe.record("ack")
            }
        }
        for _ in 0..<1_000 {
            if !(await probe.steps).isEmpty { break }
            await Task.yield()
        }
        let beforeCompletion = await probe.steps
        XCTAssertEqual(beforeCompletion, ["started"])
        await probe.finish()
        await delivery.value
        let afterCompletion = await probe.steps
        XCTAssertEqual(afterCompletion, ["started", "ingested", "ack"])
    }

    @MainActor
    func testFilteredAndUnknownRemoteEventsAreAcknowledgedWithoutIngestion() async {
        let probe = DeliveryProbe()
        let event = deliveryEvent(clientInfo: SessionClientInfo(kind: .custom, profileID: "qoderwork", name: "QoderWork"))
        XCTAssertTrue(event.shouldFilterBeforeApprovalHandling)
        for candidate in [event, nil] {
            await RemoteConnectorManager.deliverRemoteHookEvent(candidate, onEvent: { _ in
                await probe.record("ingested")
            }) {
                await probe.record("ack")
            }
        }
        let steps = await probe.steps
        XCTAssertEqual(steps, ["ack", "ack"])
    }

    @MainActor
    func testValidRemoteEventWithoutHandlerIsNotAcknowledged() async {
        let probe = DeliveryProbe()
        await RemoteConnectorManager.deliverRemoteHookEvent(deliveryEvent(), onEvent: nil) {
            await probe.record("ack")
        }
        let steps = await probe.steps
        XCTAssertTrue(steps.isEmpty)
    }

    func testOlderBridgePayloadWithoutPermissionModeStillDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "requestID": UUID().uuidString, "sessionID": "older-bridge", "cwd": "/work/project",
            "event": "PermissionRequest", "status": "waiting_for_approval", "provider": "codex",
            "expectsResponse": true, "clientInfo": ["kind": "codexCLI"]
        ])
        let payload = try JSONDecoder().decode(RemoteHookEventPayload.self, from: data)
        XCTAssertNil(payload.permissionMode)
        let acknowledgement = try JSONSerialization.jsonObject(with:
            JSONEncoder().encode(RemoteAcknowledgementMessage(requestID: payload.requestID))
        ) as? [String: Any]
        XCTAssertEqual(acknowledgement?["type"] as? String, "ack")
        XCTAssertEqual(acknowledgement?["requestID"] as? String, payload.requestID.uuidString)
        XCTAssertNil(acknowledgement?["decision"])
    }

    func testRemoteCodexUsageMessageRoundTripsSnapshot() throws {
        let snapshot = CodexUsageSnapshot(
            sourceFilePath: "/root/.codex/sessions/rollout.jsonl",
            capturedAt: Date(timeIntervalSince1970: 1_788_183_296),
            planType: "pro",
            limitID: "codex",
            tokenUsage: CodexTokenUsage(inputTokens: 1_200, outputTokens: 345, totalTokens: 1_545),
            windows: [
                CodexUsageWindow(
                    key: "primary",
                    label: "5h",
                    usedPercentage: 17,
                    leftPercentage: 83,
                    windowMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_788_183_296)
                )
            ]
        )
        let message = RemoteCodexUsageMessage(type: "codex_usage", payload: snapshot)

        let decoded = try JSONDecoder().decode(
            RemoteCodexUsageMessage.self,
            from: JSONEncoder().encode(message)
        )

        XCTAssertEqual(decoded, message)
    }

    func testRemoteCodexUsageSourcePathIncludesSSHEndpoint() {
        let endpoint = RemoteEndpoint(
            displayName: "Development host",
            sshTarget: "root@example.test",
            sshPort: 3006
        )

        XCTAssertEqual(
            RemoteConnectorManager.remoteUsageSourcePath(
                "/root/.codex/sessions/rollout.jsonl",
                endpoint: endpoint
            ),
            "ssh://root@example.test:3006/root/.codex/sessions/rollout.jsonl"
        )
    }

    func testRemoteBootstrapPrepareCommandStopsRunningAgentBeforeReplacingBridge() {
        let command = RemoteConnectorManager.remoteBootstrapPrepareCommand(
            installRoot: "/root/.ping-island",
            controlSocketPath: "/root/.ping-island/run/agent-control.sock",
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock",
            homeDirectory: "/root",
            configDirectoryPaths: ["/root/.codex", "/root/.qoder"]
        )

        XCTAssertTrue(command.contains("mkdir -p "))
        XCTAssertTrue(command.contains("chmod 700 '/root/.ping-island/run' '/root/.ping-island/logs'"))
        XCTAssertTrue(command.contains("pkill -f "))
        XCTAssertTrue(command.contains("PingIslandBridge"))
        XCTAssertTrue(command.contains("rm -f "))
        XCTAssertTrue(command.contains("PingIslandBridge.tmp"))
    }

    func testRemoteBootstrapPrepareCommandResolvesClaudeDirectoryAgainstHome() {
        let command = RemoteConnectorManager.remoteBootstrapPrepareCommand(
            installRoot: "/home/dev/.ping-island",
            controlSocketPath: "/home/dev/.ping-island/run/agent-control.sock",
            hookSocketPath: "/home/dev/.ping-island/run/agent-hook.sock",
            homeDirectory: "/home/dev",
            configDirectoryPaths: ["/home/dev/.codex"]
        )

        XCTAssertTrue(command.contains("'/home/dev/.claude'"))
        XCTAssertFalse(command.contains("$HOME"))
    }

    func testRemoteBootstrapInstallCommandPromotesStagedBridgeAtomically() {
        let command = RemoteConnectorManager.remoteBootstrapInstallCommand(
            installRoot: "/root/.ping-island",
            stagedBridgePath: "/root/.ping-island/bin/PingIslandBridge.tmp"
        )

        XCTAssertTrue(command.contains("mv -f '/root/.ping-island/bin/PingIslandBridge.tmp' '/root/.ping-island/bin/PingIslandBridge'"))
        XCTAssertTrue(command.contains("chmod 755 '/root/.ping-island/bin/PingIslandBridge' '/root/.ping-island/bin/ping-island-bridge'"))
    }

    func testRemoteBridgeChecksumCommandSupportsLinuxAndMacUtilities() {
        let command = RemoteConnectorManager.remoteBridgeChecksumCommand(
            path: "/home/dev/Ping Island/PingIslandBridge"
        )

        XCTAssertTrue(command.contains("command -v sha256sum"))
        XCTAssertTrue(command.contains("sha256sum '/home/dev/Ping Island/PingIslandBridge'"))
        XCTAssertTrue(command.contains("shasum -a 256 '/home/dev/Ping Island/PingIslandBridge'"))
    }

    func testRemoteBridgeInstallationIsCurrentOnlyWhenFilesAndChecksumMatch() {
        XCTAssertTrue(
            RemoteConnectorManager.isRemoteBridgeInstallationCurrent(
                bridgeExists: true,
                launcherExists: true,
                localChecksum: "expected",
                remoteChecksum: "expected"
            )
        )
        XCTAssertFalse(
            RemoteConnectorManager.isRemoteBridgeInstallationCurrent(
                bridgeExists: true,
                launcherExists: true,
                localChecksum: "expected",
                remoteChecksum: "stale"
            )
        )
        XCTAssertFalse(
            RemoteConnectorManager.isRemoteBridgeInstallationCurrent(
                bridgeExists: true,
                launcherExists: false,
                localChecksum: "expected",
                remoteChecksum: "expected"
            )
        )
    }

    func testRemoteBridgeLauncherOnlyUsesCompatLoaderForDynamicGlibcBridge() {
        let script = RemoteConnectorManager.remoteBridgeLauncherScript()

        XCTAssertTrue(script.contains("ldd \"$SCRIPT_DIR/PingIslandBridge\" 2>&1 | grep -q 'libc\\.so'"))
        XCTAssertTrue(script.contains("exec \"$SCRIPT_DIR/PingIslandBridge\" \"$@\""))
    }

    func testRemoteEnsureAgentRunningCommandReplacesStaleSocketStateBeforeRestart() {
        let command = RemoteConnectorManager.remoteEnsureAgentRunningCommand(
            installRoot: "/root/.ping-island",
            controlSocketPath: "/root/.ping-island/run/agent-control.sock",
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock"
        )

        XCTAssertTrue(command.contains("mkdir -p '/root/.ping-island/run' '/root/.ping-island/logs'"))
        XCTAssertTrue(command.contains("chmod 700 '/root/.ping-island/run' '/root/.ping-island/logs'"))
        XCTAssertTrue(command.contains("if [ -S '/root/.ping-island/run/agent-control.sock' ] && pgrep -f '/root/.ping-island/bin/[P]ingIslandBridge --mode remote-agent-service' >/dev/null 2>&1; then"))
        XCTAssertTrue(command.contains("Ping Island remote bridge is not installed at /root/.ping-island/bin"))
        XCTAssertTrue(command.contains("pkill -f '/root/.ping-island/bin/[P]ingIslandBridge --mode remote-agent-service' >/dev/null 2>&1 || true"))
        XCTAssertTrue(command.contains("rm -f '/root/.ping-island/run/agent-control.sock' '/root/.ping-island/run/agent-hook.sock'"))
        XCTAssertTrue(command.contains("nohup '/root/.ping-island/bin/ping-island-bridge' --mode remote-agent-service --hook-socket '/root/.ping-island/run/agent-hook.sock' --control-socket '/root/.ping-island/run/agent-control.sock' > '/root/.ping-island/logs/remote-agent.log' 2>&1 &"))
        XCTAssertTrue(command.contains("Ping Island remote bridge failed to start"))
        XCTAssertTrue(command.contains("tail -n 40 '/root/.ping-island/logs/remote-agent.log'"))
    }

    func testRemoteBootstrapUninstallCommandStopsBridgeAndRemovesInstallRoot() {
        let command = RemoteConnectorManager.remoteBootstrapUninstallCommand(
            installRoot: "/root/.ping-island",
            controlSocketPath: "/root/.ping-island/run/agent-control.sock",
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock"
        )

        XCTAssertTrue(command.contains("pkill -f '/root/.ping-island/bin/[P]ingIslandBridge --mode remote-agent-service'"))
        XCTAssertTrue(command.contains("pkill -f '/root/.ping-island/bin/[P]ingIslandBridge --mode remote-agent-attach'"))
        XCTAssertTrue(command.contains("rm -f '/root/.ping-island/run/agent-control.sock' '/root/.ping-island/run/agent-hook.sock'"))
        XCTAssertTrue(command.contains("rm -rf '/root/.ping-island'"))
    }

    func testRemoteUninstallPhaseUsesDedicatedTitle() {
        XCTAssertEqual(RemoteEndpointConnectionPhase.uninstalling.titleKey, "卸载中")
    }

    func testRemoteLinuxBridgeAssetNamesPreferZipArchiveDownload() {
        XCTAssertEqual(
            RemoteConnectorManager.normalizedLinuxBridgeArchitecture("amd64"),
            "x86_64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.normalizedLinuxBridgeArchitecture("aarch64"),
            "aarch64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.normalizedLinuxBridgeArchitecture("arm64"),
            "aarch64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: "x86_64"),
            "PingIslandBridge-linux-musl-x86_64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: "x86_64"),
            "PingIslandBridge-linux-musl-x86_64.zip"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeBinaryAssetName(normalizedArchitecture: "aarch64"),
            "PingIslandBridge-linux-musl-aarch64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeArchiveAssetName(normalizedArchitecture: "aarch64"),
            "PingIslandBridge-linux-musl-aarch64.zip"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeLegacyBinaryAssetName(normalizedArchitecture: "x86_64"),
            "PingIslandBridge-linux-x86_64"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeLegacyArchiveAssetName(normalizedArchitecture: "aarch64"),
            "PingIslandBridge-linux-aarch64.zip"
        )
        XCTAssertEqual(
            RemoteConnectorManager.remoteLinuxBridgeOverrideURL(
                normalizedArchitecture: "x86_64",
                homeDirectory: URL(fileURLWithPath: "/Users/testuser", isDirectory: true)
            ).path,
            "/Users/testuser/.ping-island/custom-bridges/PingIslandBridge-linux-musl-x86_64"
        )
    }

    func testRemoteManagedHookProfilesIncludeSupportedCliIntegrations() {
        let profileIDs = Set(RemoteConnectorManager.remoteManagedHookProfiles().map(\.id))

        XCTAssertEqual(profileIDs, [
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
            "qoderwork-hooks",
        ])
    }

    func testRemoteManagedHookConfigDirectoryPathsResolveUnderRemoteHome() {
        let directories = RemoteConnectorManager.remoteManagedHookConfigDirectoryPaths(
            homeDirectory: "/root",
            profiles: RemoteConnectorManager.remoteManagedHookProfiles()
        )

        XCTAssertTrue(directories.contains("/root/.claude"))
        XCTAssertTrue(directories.contains("/root/.codex"))
        XCTAssertTrue(directories.contains("/root/.gemini/antigravity-cli/plugins"))
        XCTAssertTrue(directories.contains("/root/.gemini/antigravity-cli/plugins/ping-island"))
        XCTAssertTrue(directories.contains("/root/.hermes/plugins"))
        XCTAssertTrue(directories.contains("/root/.hermes/plugins/ping_island"))
        XCTAssertTrue(directories.contains("/root/.pi/agent/extensions"))
        XCTAssertTrue(directories.contains("/root/.pi/agent/extensions/ping_island"))
        XCTAssertTrue(directories.contains("/root/.qwen"))
        XCTAssertTrue(directories.contains("/root/.openclaw"))
        XCTAssertTrue(directories.contains("/root/.openclaw/hooks"))
        XCTAssertTrue(directories.contains("/root/.openclaw/hooks/ping-island-openclaw"))
        XCTAssertTrue(directories.contains("/root/.codebuddy"))
        XCTAssertTrue(directories.contains("/root/.qoder"))
        XCTAssertTrue(directories.contains("/root/.qoder-cn"))
        XCTAssertTrue(directories.contains("/root/.qoderwork"))
    }

    func testHermesRemoteManagedHookDirectoryPathUsesPluginDirectory() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let directories = RemoteConnectorManager.remoteManagedHookDirectoryPaths(
            for: profile,
            homeDirectory: "/root"
        )

        XCTAssertEqual(directories, ["/root/.hermes/plugins", "/root/.hermes/plugins/ping_island"])
    }

    func testPiRemoteManagedHookDirectoryPathUsesExtensionDirectory() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "pi-hooks"))
        let directories = RemoteConnectorManager.remoteManagedHookDirectoryPaths(
            for: profile,
            homeDirectory: "/root"
        )

        XCTAssertEqual(
            directories,
            [
                "/root/.pi/agent/extensions",
                "/root/.pi/agent/extensions/ping_island"
            ]
        )
    }

    func testHermesManagedPluginDirectoryFilesContainPluginManifestAndModule() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)

        XCTAssertEqual(Set(files.keys), ["plugin.yaml", "__init__.py"])
        XCTAssertTrue(files["plugin.yaml"]?.contains("name: ping_island") == true)
        XCTAssertTrue(files["__init__.py"]?.contains("ctx.register_hook(\"pre_llm_call\"") == true)
    }

    func testPiManagedPluginDirectoryFilesContainExtensionModule() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "pi-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)

        XCTAssertEqual(Set(files.keys), ["index.ts"])
        XCTAssertTrue(files["index.ts"]?.contains("pi.on(\"session_start\"") == true)
        XCTAssertTrue(files["index.ts"]?.contains("hook_event_name: \"PermissionRequest\"") == true)
    }

    func testRemoteConfigurationPathResolvesRelativeHomePaths() {
        XCTAssertEqual(
            RemoteConnectorManager.remoteConfigurationPath(
                relativePath: ".codex/hooks.json",
                homeDirectory: "/root"
            ),
            "/root/.codex/hooks.json"
        )
    }

    func testShouldBootstrapRemoteAgentForFreshEndpoint() {
        let endpoint = RemoteEndpoint(
            displayName: "Fresh",
            sshTarget: "dev@example"
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: false
            )
        )
    }

    func testShouldReuseRemoteAgentAfterSuccessfulConnection() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            agentVersion: "1.2.3",
            lastConnectedAt: Date()
        )

        XCTAssertFalse(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: false
            )
        )
    }

    func testShouldAutoReconnectOnLaunchForPreviouslyConnectedPublicKeyHost() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            authMode: .publicKey,
            lastConnectedAt: Date()
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldAutoReconnectOnLaunch(
                endpoint: endpoint,
                hasReusablePassword: false
            )
        )
    }

    func testShouldAutoReconnectOnLaunchForPreviouslyConnectedPasswordHostWithSavedCredential() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            authMode: .passwordSession,
            lastConnectedAt: Date()
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldAutoReconnectOnLaunch(
                endpoint: endpoint,
                hasReusablePassword: true
            )
        )
    }

    func testShouldNotAutoReconnectOnLaunchForPasswordHostWithoutSavedCredential() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            authMode: .passwordSession,
            lastConnectedAt: Date()
        )

        XCTAssertFalse(
            RemoteConnectorManager.shouldAutoReconnectOnLaunch(
                endpoint: endpoint,
                hasReusablePassword: false
            )
        )
    }

    func testShouldNotAutoReconnectOnLaunchForFreshEndpoint() {
        let endpoint = RemoteEndpoint(
            displayName: "Fresh Host",
            sshTarget: "dev@example",
            authMode: .publicKey
        )

        XCTAssertFalse(
            RemoteConnectorManager.shouldAutoReconnectOnLaunch(
                endpoint: endpoint,
                hasReusablePassword: true
            )
        )
    }

    func testRuntimeReconnectDelayUsesCappedExponentialBackoff() {
        XCTAssertEqual(RemoteConnectorManager.runtimeReconnectDelaySeconds(forAttempt: 1), 1)
        XCTAssertEqual(RemoteConnectorManager.runtimeReconnectDelaySeconds(forAttempt: 2), 2)
        XCTAssertEqual(RemoteConnectorManager.runtimeReconnectDelaySeconds(forAttempt: 5), 16)
        XCTAssertEqual(RemoteConnectorManager.runtimeReconnectDelaySeconds(forAttempt: 6), 30)
        XCTAssertEqual(RemoteConnectorManager.runtimeReconnectDelaySeconds(forAttempt: 20), 30)
    }

    func testShouldBootstrapRemoteAgentWhenForced() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            agentVersion: "1.2.3",
            lastConnectedAt: Date()
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: true
            )
        )
    }

    func testResolvedRemoteHostHintPrefersPayloadHost() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example"
        )

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: "remote-box",
                endpoint: endpoint
            ),
            "remote-box"
        )
    }

    func testResolvedRemoteHostHintFallsBackToDetectedHostnameThenSSHTarget() {
        var detectedEndpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example"
        )
        detectedEndpoint.detectedHostname = "detected-box"

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: nil,
                endpoint: detectedEndpoint
            ),
            "detected-box"
        )

        let targetOnlyEndpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@box.example.com:2222"
        )
        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: nil,
                endpoint: targetOnlyEndpoint
            ),
            "box.example.com"
        )
    }

    func testResolvedRemoteHostHintPrefersDetectedHostnameOverPayloadIP() {
        var endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@172.25.145.237"
        )
        endpoint.detectedHostname = "devbox"

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: "172.25.145.237",
                endpoint: endpoint
            ),
            "devbox"
        )
    }

    func testManagedConfigurationDataInstallsClaudeHooksWithoutRemovingExistingEntries() throws {
        let existingJSON = """
        {
          "hooks": {
            "PreToolUse": [{
              "matcher": "*",
              "hooks": [{"type": "command", "command": "/remote/.ping-island/bin/ping-island-bridge --source claude"}]
            }],
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo existing"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let command = HookInstaller.managedBridgeCommand(
            source: profile.bridgeSource,
            extraArguments: profile.bridgeExtraArguments,
            launcherPath: "/remote/bin/ping-island-bridge",
            socketPath: "/remote/run/agent-hook.sock"
        )

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: command,
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])

        XCTAssertEqual(promptEntries.count, 2)

        for event in ["PreToolUse", "PermissionRequest"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, event)
            let hook = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(hook["command"] as? String, command)
            XCTAssertEqual(hook["timeout"] as? Int, 86_400, event)
        }
    }

    func testManagedConfigurationDataRemovesLocalOnlyCommandsForRemoteInstall() throws {
        let existingJSON = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/ping-island/.claude/hooks/peon-ping/scripts/hook-handle-use.sh"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo keep"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: "ISLAND_SOCKET_PATH='/root/.ping-island/run/agent-hook.sock' '/root/.ping-island/bin/ping-island-bridge' --source claude",
            installing: true,
            removingCommandPrefixes: ["/Users/"]
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let commands = promptEntries
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertFalse(commands.contains { $0.contains("/Users/ping-island/.claude/hooks/peon-ping") })
        XCTAssertTrue(commands.contains("/usr/bin/echo keep"))
        XCTAssertTrue(commands.contains { $0.contains("/root/.ping-island/bin/ping-island-bridge") })
    }

    func testManagedConfigurationDataRemovesIslandManagedEntriesWhenUninstalling() throws {
        let existingJSON = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo keep"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "ISLAND_SOCKET_PATH='/remote/run/agent-hook.sock' '/home/test/.ping-island/bin/ping-island-bridge' --source claude"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: "",
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])

        XCTAssertEqual(promptEntries.count, 1)
    }

    func testOpenClawInternalHookConfigurationDataEnablesManagedEntry() throws {
        let data = HookInstaller.updatedInternalHookConfigurationData(
            existingData: nil,
            entryName: "ping-island-openclaw",
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let internalHooks = try XCTUnwrap(hooks["internal"] as? [String: Any])
        let enabled = try XCTUnwrap(internalHooks["enabled"] as? Bool)
        let entries = try XCTUnwrap(internalHooks["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries["ping-island-openclaw"] as? [String: Any])

        XCTAssertTrue(enabled)
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertTrue(
            HookInstaller.isInternalHookEnabled(
                existingData: data,
                entryName: "ping-island-openclaw"
            )
        )
    }

    func testOpenClawInternalHookConfigurationDataDisablesManagedEntry() throws {
        let existingJSON = """
        {
          "hooks": {
            "internal": {
              "enabled": true,
              "entries": {
                "ping-island-openclaw": {
                  "enabled": true,
                  "env": {
                    "PING_ISLAND_DEBUG": "1"
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)

        let data = HookInstaller.updatedInternalHookConfigurationData(
            existingData: existingJSON,
            entryName: "ping-island-openclaw",
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let internalHooks = try XCTUnwrap(hooks["internal"] as? [String: Any])
        let entries = try XCTUnwrap(internalHooks["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries["ping-island-openclaw"] as? [String: Any])
        let env = try XCTUnwrap(entry["env"] as? [String: String])

        XCTAssertEqual(entry["enabled"] as? Bool, false)
        XCTAssertEqual(env["PING_ISLAND_DEBUG"], "1")
        XCTAssertFalse(
            HookInstaller.isInternalHookEnabled(
                existingData: data,
                entryName: "ping-island-openclaw"
            )
        )
    }

    func testOpenClawRemoteBridgeArgumentsAndEnvironmentUseRemoteInstallRootAndSocket() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks"))
        let arguments = RemoteConnectorManager.remoteManagedBridgeArguments(
            for: profile,
            installRoot: "/root/.ping-island"
        )
        let environment = RemoteConnectorManager.remoteManagedBridgeEnvironment(
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock"
        )

        XCTAssertEqual(arguments.prefix(3), [
            "/root/.ping-island/bin/ping-island-bridge",
            "--source",
            "claude",
        ])
        XCTAssertTrue(arguments.contains("--client-kind"))
        XCTAssertTrue(arguments.contains("openclaw"))
        XCTAssertEqual(
            environment,
            ["ISLAND_SOCKET_PATH": "/root/.ping-island/run/agent-hook.sock"]
        )
    }

    func testConnectionFailureDetailUsesStageSpecificMessage() {
        XCTAssertEqual(
            RemoteConnectorManager.connectionFailureDetail(for: "bootstrap-initial"),
            "远程初始化失败"
        )
        XCTAssertEqual(
            RemoteConnectorManager.connectionFailureDetail(for: "probe"),
            "远程主机检测失败"
        )
        XCTAssertEqual(
            RemoteConnectorManager.connectionFailureDetail(for: "attach"),
            "远程连接失败"
        )
    }

    func testPresentableConnectionErrorSummarizesHermesPluginDirectoryScpFailure() {
        let error = """
        /usr/bin/scp: dest open "/root/.hermes/plugins/ping_island/__init__.py": No such file or directory
        /usr/bin/scp: failed to upload file /var/folders/example to /root/.hermes/plugins/ping_island/__init__.py
        """

        XCTAssertEqual(
            RemoteConnectorManager.presentableConnectionError(
                stage: "bootstrap-initial",
                errorDescription: error
            ),
            "无法写入远程 Hermes 插件目录，请确认远程主目录可写后重试。"
        )
    }

    func testPresentableConnectionErrorSummarizesPermissionDenied() {
        XCTAssertEqual(
            RemoteConnectorManager.presentableConnectionError(
                stage: "probe",
                errorDescription: "Permission denied, please try again."
            ),
            "SSH 认证失败，请重新输入密码或检查远程 SSH 凭据。"
        )
    }

    func testRemotePendingRequestStoreKeepsDuplicateRequestsForSameToolUseID() {
        let endpointID = UUID()
        let firstRequest = PendingRemoteRequest(
            endpointID: endpointID,
            requestID: UUID(),
            sessionID: "remote-session"
        )
        let secondRequest = PendingRemoteRequest(
            endpointID: endpointID,
            requestID: UUID(),
            sessionID: "remote-session"
        )

        var store = RemotePendingRequestStore()
        store.append(firstRequest, for: "tool-1")
        store.append(secondRequest, for: "tool-1")

        XCTAssertEqual(store.requests(for: "tool-1"), [firstRequest, secondRequest])
        XCTAssertEqual(store.removeAll(for: "tool-1"), [firstRequest, secondRequest])
        XCTAssertTrue(store.requests(for: "tool-1").isEmpty)
    }

    func testRemotePendingRequestStoreRemovesOnlyDisconnectedEndpointRequests() {
        let disconnectedEndpointID = UUID()
        let survivingEndpointID = UUID()
        let disconnectedRequest = PendingRemoteRequest(
            endpointID: disconnectedEndpointID,
            requestID: UUID(),
            sessionID: "remote-session"
        )
        let survivingRequest = PendingRemoteRequest(
            endpointID: survivingEndpointID,
            requestID: UUID(),
            sessionID: "remote-session"
        )

        var store = RemotePendingRequestStore()
        store.append(disconnectedRequest, for: "tool-1")
        store.append(survivingRequest, for: "tool-1")

        store.removeAll(for: disconnectedEndpointID)

        XCTAssertEqual(store.requests(for: "tool-1"), [survivingRequest])
    }

    func testResolvedRemoteToolUseIDPreservesExplicitToolUseID() {
        let requestID = UUID()

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteToolUseID(
                toolUseID: "toolu_remote_123",
                expectsResponse: true,
                requestID: requestID
            ),
            "toolu_remote_123"
        )
    }

    func testResolvedRemoteToolUseIDSynthesizesBridgeIDForResponseOnlyRequests() {
        let requestID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteToolUseID(
                toolUseID: nil,
                expectsResponse: true,
                requestID: requestID
            ),
            "bridge-12345678-1234-1234-1234-1234567890AB"
        )
    }

    func testRemoteCodexReviewerMetadataIsOptionalForOlderBridges() throws {
        let base = """
        {"requestID":"00000000-0000-0000-0000-000000000001", "sessionID":"codex-remote",
         "cwd":"/work", "event":"PermissionRequest", "status":"waiting_for_approval",
         "provider":"codex", "expectsResponse":true,
         "clientInfo":{"kind":"codexCLI"}}
        """
        let legacy = try JSONDecoder().decode(RemoteHookEventPayload.self, from: Data(base.utf8))
        XCTAssertNil(legacy.approvalsReviewer)
        XCTAssertNil(legacy.permissionMode)

        let withReviewer = base.replacingOccurrences(
            of: "\"clientInfo\"", with: "\"permissionMode\":\"default\",\"approvalsReviewer\":\"auto_review\",\"clientInfo\""
        )
        let current = try JSONDecoder().decode(RemoteHookEventPayload.self, from: Data(withReviewer.utf8))
        XCTAssertEqual(current.approvalsReviewer, "auto_review")
        XCTAssertEqual(current.permissionMode, "default")
        XCTAssertTrue(CodexAutomaticApprovalReviewResolver.shouldDeferToCodex(
            provider: current.provider,
            eventType: current.event,
            metadata: ["approvals_reviewer": current.approvalsReviewer ?? "",
                       "permission_mode": current.permissionMode ?? ""]
        ))
    }

    func testResolvedRemoteToolUseIDDoesNotSynthesizeForFireAndForgetEvents() {
        XCTAssertNil(
            RemoteConnectorManager.resolvedRemoteToolUseID(
                toolUseID: nil,
                expectsResponse: false,
                requestID: UUID()
            )
        )
    }
}
