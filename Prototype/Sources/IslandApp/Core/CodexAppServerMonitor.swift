import Foundation
import IslandShared

actor CodexAppServerMonitor {
    private let sessionStore: SessionStore
    private let noteDidChange: @MainActor (String) -> Void
    private var process: Process?
    private var websocket: URLSessionWebSocketTask?
    private let port = 41241
    private static let maximumWebSocketMessageSize = 32 * 1024 * 1024

    init(
        sessionStore: SessionStore,
        noteDidChange: @escaping @MainActor (String) -> Void
    ) {
        self.sessionStore = sessionStore
        self.noteDidChange = noteDidChange
    }

    func start() async {
        guard process == nil else { return }
        guard let executable = resolveCodexExecutable() else {
            await noteDidChange("Codex CLI not found, using hook-only mode")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            self.process = process
            await noteDidChange("Codex app-server starting on :\(port)")
            try? await Task.sleep(for: .milliseconds(800))
            try await connectWebSocket()
        } catch {
            await noteDidChange("Codex app-server unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        process?.terminate()
        process = nil
    }

    func submit(response: InterventionDecision, for request: InterventionRequest) async throws {
        guard let websocket else { return }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": request.kind == .approval ? "approval/submit" : "question/submit",
            "params": [
                "requestId": request.id.uuidString,
                "threadId": request.sessionID,
                "decision": decisionPayload(response)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try await websocket.send(.data(data))
    }

    private func connectWebSocket() async throws {
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumWebSocketMessageSize
        task.resume()
        websocket = task
        await noteDidChange("Codex app-server connected")
        receiveLoop()
    }

    private func receiveLoop() {
        guard let websocket else { return }
        websocket.receive { [weak self] result in
            guard let self else { return }
            Task {
                switch result {
                case .success(let message):
                    await self.handle(message)
                    await self.receiveLoop()
                case .failure(let error):
                    await self.noteDidChange("Codex websocket closed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = json["method"] as? String,
            let params = json["params"] as? [String: Any]
        else {
            return
        }

        if method == "thread/status/changed" {
            let threadID = (params["threadId"] as? String) ?? "codex:unknown"
            let status = statusFromCodex(params["status"] as? [String: Any])
            await sessionStore.ingestCodexStatus(
                sessionID: threadID,
                title: params["title"] as? String,
                preview: params["preview"] as? String,
                status: status,
                metadata: params.compactMapValues { value in
                    if let string = value as? String { return string }
                    return nil
                }
            )
            await noteDidChange("Codex session updated")
        }
    }

    private func statusFromCodex(_ status: [String: Any]?) -> SessionStatus {
        guard let type = status?["type"] as? String else {
            return SessionStatus(kind: .active)
        }
        if type == "active" {
            let flags = status?["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                return SessionStatus(kind: .waitingForApproval)
            }
            if flags.contains("waitingOnUserInput") {
                return SessionStatus(kind: .waitingForInput)
            }
            return SessionStatus(kind: .thinking)
        }
        if type == "idle" {
            return SessionStatus(kind: .completed)
        }
        if type == "systemError" {
            return SessionStatus(kind: .error)
        }
        return SessionStatus(kind: .active)
    }

    private func decisionPayload(_ decision: InterventionDecision) -> Any {
        switch decision {
        case .approve:
            return "accept"
        case .approveForSession:
            return "acceptForSession"
        case .deny:
            return "decline"
        case .cancel:
            return "cancel"
        case .answer(let answers):
            return answers
        }
    }

    private func resolveCodexExecutable() -> String? {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/codex" }
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
