import XCTest
@testable import Ping_Island

@MainActor
final class NativeRuntimeSessionStoreTests: XCTestCase {
    private actor StubRuntime: SessionRuntime {
        let provider: SessionProvider
        nonisolated let events: AsyncStream<SessionRuntimeEvent>

        private var continuation: AsyncStream<SessionRuntimeEvent>.Continuation?

        init(provider: SessionProvider) {
            self.provider = provider
            var capturedContinuation: AsyncStream<SessionRuntimeEvent>.Continuation?
            self.events = AsyncStream { continuation in
                capturedContinuation = continuation
            }
            self.continuation = capturedContinuation
        }

        func prepare() async {}
        func shutdown() async {}
        func isAvailable() async -> Bool { true }

        func startSession(_ request: SessionRuntimeLaunchRequest) async throws -> SessionRuntimeHandle {
            let handle = SessionRuntimeHandle(
                sessionID: request.preferredSessionID ?? UUID().uuidString,
                provider: provider,
                cwd: request.cwd,
                createdAt: Date(),
                resumeToken: request.resumeSessionID,
                runtimeIdentifier: "stub-\(provider.rawValue)",
                sessionFilePath: nil
            )
            continuation?.yield(.started(handle))
            return handle
        }

        func resumeSession(id: String) async throws -> SessionRuntimeHandle {
            let handle = SessionRuntimeHandle(
                sessionID: id,
                provider: provider,
                cwd: "/tmp",
                createdAt: Date(),
                resumeToken: id,
                runtimeIdentifier: "stub-\(provider.rawValue)",
                sessionFilePath: nil
            )
            continuation?.yield(.started(handle))
            return handle
        }

        func terminateSession(id: String) async throws {
            continuation?.yield(.stopped(sessionID: id, reason: .cancelled))
        }
    }

    private let claudeRuntime = StubRuntime(provider: .claude)
    private let codexRuntime = StubRuntime(provider: .codex)

    override func setUp() async throws {
        FeatureFlags.setEnabled(true, for: .nativeClaudeRuntime)
        FeatureFlags.setEnabled(true, for: .nativeCodexRuntime)
    }

    override func tearDown() async throws {
        FeatureFlags.setEnabled(false, for: .nativeClaudeRuntime)
        FeatureFlags.setEnabled(false, for: .nativeCodexRuntime)
    }

    func testRuntimeStartedCreatesSessionStateEntry() async throws {
        let coordinator = RuntimeCoordinator(
            runtimes: [
                .claude: claudeRuntime,
                .codex: codexRuntime,
            ]
        )
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let handle = try await coordinator.startSession(
            provider: .claude,
            cwd: "/tmp/native-runtime-test",
            preferredSessionID: "native-claude-session"
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        let session = await SessionStore.shared.session(for: handle.sessionID)
        XCTAssertEqual(session?.sessionId, "native-claude-session")
        XCTAssertEqual(session?.provider, .claude)
        XCTAssertEqual(session?.ingress, .nativeRuntime)
        XCTAssertEqual(session?.cwd, "/tmp/native-runtime-test")
        XCTAssertEqual(session?.clientInfo.origin, "native-runtime")
    }

    func testRuntimeStoppedMarksSessionEnded() async throws {
        let coordinator = RuntimeCoordinator(
            runtimes: [
                .claude: claudeRuntime,
                .codex: codexRuntime,
            ]
        )
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let handle = try await coordinator.startSession(
            provider: .codex,
            cwd: "/tmp/native-runtime-test-codex",
            preferredSessionID: "native-codex-session"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        try await coordinator.terminateSession(provider: .codex, sessionID: handle.sessionID)
        try await Task.sleep(nanoseconds: 100_000_000)

        let session = await SessionStore.shared.session(for: handle.sessionID)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertEqual(session?.ingress, .nativeRuntime)
    }
}
