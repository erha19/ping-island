import Foundation
import IslandShared
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
private let islandStreamSocketType: Int32 = SOCK_STREAM
private let islandShutdownWrite: Int32 = SHUT_WR
#elseif canImport(Musl)
private let islandStreamSocketType: Int32 = Int32(SOCK_STREAM)
private let islandShutdownWrite: Int32 = Int32(SHUT_WR)
#elseif canImport(Glibc)
private let islandStreamSocketType: Int32 = Int32(SOCK_STREAM.rawValue)
private let islandShutdownWrite: Int32 = Int32(SHUT_WR)
#endif

@main
struct IslandBridgeMain {
    private static let stdinInitialPollTimeoutMs = 100
    private static let stdinFollowUpPollTimeoutMs = 10

    static func main() async {
        Self.configureProcessSignalHandling()
        do {
            switch try parseMode(arguments: CommandLine.arguments) {
            case .hook:
                let source = try parseSource(arguments: CommandLine.arguments)
                let stdinData = readStandardInputPayload()
                var environment = ProcessInfo.processInfo.environment
                if environment["TTY"]?.isEmpty != false, let tty = detectTTY(parentPID: getppid()) {
                    environment["TTY"] = tty
                }
                let runtimeConfig = BridgeRuntimeConfig.load(environment: environment)
                let envelope = HookPayloadMapper.makeEnvelope(
                    source: source,
                    arguments: CommandLine.arguments,
                    environment: environment,
                    stdinData: stdinData,
                    runtimeConfig: runtimeConfig
                )
                try? BridgeDebugLogger.logIfNeeded(
                    envelope: envelope,
                    arguments: CommandLine.arguments,
                    environment: environment,
                    stdinData: stdinData
                )

                let socketPath = environment["ISLAND_SOCKET_PATH"] ?? "/tmp/island.sock"
                guard HookPayloadMapper.shouldDeliverEnvelope(envelope) else {
                    try? BridgeDebugLogger.logDeliveryIfNeeded(
                        envelope: envelope,
                        environment: environment,
                        socketPath: socketPath,
                        outcome: "skipped_qoder_ide_event"
                    )
                    return
                }

                let response: BridgeResponse?
                do {
                    response = try sendEnvelopeIfPossible(
                        envelope: envelope,
                        socketPath: socketPath
                    )
                    try? BridgeDebugLogger.logDeliveryIfNeeded(
                        envelope: envelope,
                        environment: environment,
                        socketPath: socketPath,
                        outcome: "delivered"
                    )
                } catch BridgeError.connectionFailed {
                    try? BridgeDebugLogger.logDeliveryIfNeeded(
                        envelope: envelope,
                        environment: environment,
                        socketPath: socketPath,
                        outcome: "connection_failed"
                    )
                    throw BridgeError.connectionFailed
                }

                if let response, response.decision != nil {
                    let payload = HookPayloadMapper.stdoutPayload(
                        for: source,
                        response: response,
                        eventType: envelope.eventType,
                        metadata: envelope.metadata
                    )
                    FileHandle.standardOutput.write(Data(payload.utf8))
                }
            case .remoteAgentService:
                let hookSocket = try requiredArgument("--hook-socket", arguments: CommandLine.arguments)
                let controlSocket = try requiredArgument("--control-socket", arguments: CommandLine.arguments)
                let service = try RemoteAgentService(hookSocketPath: hookSocket, controlSocketPath: controlSocket)
                service.run()
            case .remoteAgentAttach:
                let controlSocket = try requiredArgument("--control-socket", arguments: CommandLine.arguments)
                try RemoteAgentAttach.run(controlSocketPath: controlSocket)
            case .healthCheck:
                let environment = ProcessInfo.processInfo.environment
                let socketPath = environment["ISLAND_SOCKET_PATH"] ?? "/tmp/island.sock"
                try SocketClient.sendHealthCheck(socketPath: socketPath)
                FileHandle.standardOutput.write(Data("ok\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("PingIslandBridge error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func configureProcessSignalHandling() {
        #if canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }

    private static func parseMode(arguments: [String]) throws -> BridgeRuntimeMode {
        guard let index = arguments.firstIndex(of: "--mode"), arguments.indices.contains(index + 1) else {
            return .hook
        }
        guard let mode = BridgeRuntimeMode(rawValue: arguments[index + 1]) else {
            throw BridgeError.invalidArguments
        }
        return mode
    }

    private static func parseSource(arguments: [String]) throws -> AgentProvider {
        guard let index = arguments.firstIndex(of: "--source"), arguments.indices.contains(index + 1) else {
            throw BridgeError.invalidArguments
        }
        guard let source = AgentProvider(rawValue: arguments[index + 1]) else {
            throw BridgeError.invalidArguments
        }
        return source
    }

    private static func detectTTY(parentPID: pid_t) -> String? {
        if let tty = ttyName(from: STDIN_FILENO) ?? ttyName(from: STDOUT_FILENO) {
            return tty
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(parentPID), "-o", "tty="]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let tty = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !tty.isEmpty,
                tty != "??",
                tty != "-"
            else {
                return nil
            }
            return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        } catch {
            return nil
        }
    }

    private static func ttyName(from fd: Int32) -> String? {
        guard isatty(fd) == 1, let name = ttyname(fd) else {
            return nil
        }
        return String(cString: name)
    }

    private static func readStandardInputPayload() -> Data {
        let stdinFD = FileHandle.standardInput.fileDescriptor
        guard isatty(stdinFD) == 0 else {
            return Data()
        }

        var fileStatus = stat()
        if fstat(stdinFD, &fileStatus) == 0, (fileStatus.st_mode & S_IFMT) == S_IFREG {
            return FileHandle.standardInput.readDataToEndOfFile()
        }

        let originalFlags = fcntl(stdinFD, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(stdinFD, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(stdinFD, F_SETFL, originalFlags)
            }
        }

        var data = Data()
        var sawFirstChunk = false
        var completionState = JSONStreamCompletionState()

        while true {
            if completionState.isCompleteTopLevelObject,
               BridgeCodec.readJSONObject(from: data) != nil {
                return data
            }

            var descriptor = pollfd(fd: stdinFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let timeout = Int32(sawFirstChunk ? stdinFollowUpPollTimeoutMs : stdinInitialPollTimeoutMs)
            let pollResult = poll(&descriptor, 1, timeout)

            if pollResult == 0 {
                return data
            }

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return data
            }

            switch drainAvailableStandardInput(from: stdinFD, into: &data) {
            case .readBytes:
                sawFirstChunk = true
                completionState.consume(data)
            case .reachedEOF:
                return data
            case .wouldBlock:
                if descriptor.revents & Int16(POLLHUP) != 0 {
                    return data
                }
            case .failed:
                return data
            }
        }
    }

    private static func drainAvailableStandardInput(from fd: Int32, into data: inout Data) -> StdinDrainResult {
        var didReadAnyBytes = false
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let byteCount = read(fd, &buffer, buffer.count)
            if byteCount > 0 {
                didReadAnyBytes = true
                data.append(buffer, count: byteCount)
                continue
            }

            if byteCount == 0 {
                return .reachedEOF
            }

            if errno == EINTR {
                continue
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return didReadAnyBytes ? .readBytes : .wouldBlock
            }

            return .failed
        }
    }

    private static func sendEnvelopeIfPossible(
        envelope: BridgeEnvelope,
        socketPath: String
    ) throws -> BridgeResponse? {
        do {
            return try SocketClient.send(envelope: envelope, socketPath: socketPath)
        } catch BridgeError.connectionFailed where !envelope.expectsResponse {
            // State-only hooks should not fail the calling CLI when Island is unavailable.
            return nil
        }
    }

    private static func requiredArgument(_ name: String, arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            throw BridgeError.invalidArguments
        }
        return arguments[index + 1]
    }
}

private enum StdinDrainResult {
    case readBytes
    case reachedEOF
    case wouldBlock
    case failed
}

private struct JSONStreamCompletionState {
    private(set) var isCompleteTopLevelObject = false
    private var consumedByteCount = 0
    private var objectDepth = 0
    private var sawObjectStart = false
    private var isInsideString = false
    private var isEscaping = false

    mutating func consume(_ data: Data) {
        guard isCompleteTopLevelObject == false, consumedByteCount < data.count else {
            consumedByteCount = max(consumedByteCount, data.count)
            return
        }

        for byte in data[consumedByteCount...] {
            consumedByteCount += 1

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                    continue
                }

                if byte == 0x5C {
                    isEscaping = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            if Self.isWhitespace(byte) {
                continue
            }

            if byte == 0x22 {
                isInsideString = true
                continue
            }

            if byte == 0x7B {
                sawObjectStart = true
                objectDepth += 1
                continue
            }

            if byte == 0x7D, sawObjectStart {
                objectDepth -= 1
                if objectDepth == 0 {
                    isCompleteTopLevelObject = true
                    return
                }
                continue
            }
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

}

private enum BridgeDebugLogger {
    private static let interestingEnvironmentKeys: Set<String> = [
        "PWD",
        "TERM",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "ITERM_SESSION_ID",
        "TMUX",
        "TMUX_PANE",
        "TTY",
        "__CFBundleIdentifier",
        "CLAUDE_SESSION_ID",
        "CODEX_THREAD_ID",
        "CODEBUDDY_SESSION_ID",
        "KIMI_SESSION_ID",
    ]

    static func logIfNeeded(
        envelope: BridgeEnvelope,
        arguments: [String],
        environment: [String: String],
        stdinData: Data
    ) throws {
        guard let target = debugTarget(for: envelope) else { return }

        let fileManager = FileManager.default
        let directory = debugDirectory(for: target, environment: environment)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = BridgeDebugRecord(
            id: UUID(),
            timestamp: Date(),
            provider: envelope.provider.rawValue,
            clientKind: envelope.metadata["client_kind"],
            eventType: envelope.eventType,
            sessionKey: envelope.sessionKey,
            expectsResponse: envelope.expectsResponse,
            statusKind: envelope.status?.kind.rawValue,
            title: envelope.title,
            preview: envelope.preview,
            arguments: Array(arguments.dropFirst()),
            environment: filteredEnvironment(environment),
            metadata: envelope.metadata,
            stdinRaw: String(data: stdinData, encoding: .utf8),
            envelopeJSON: BridgeCodec.jsonString(for: envelope),
            socketPath: nil,
            deliveryOutcome: nil
        )

        let fileURL = directory.appendingPathComponent(dayStamp(for: record.timestamp) + ".jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private static func debugTarget(for envelope: BridgeEnvelope) -> String? {
        let clientKind = envelope.metadata["client_kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch clientKind {
        case "codebuddy-cli":
            return "codebuddy-cli-hooks"
        case "codebuddy":
            return "codebuddy-hooks"
        case "hermes", "hermes-agent", "hermes_agent", "hermes agent":
            return "hermes-hooks"
        case "openclaw":
            return "openclaw-hooks"
        case "qoder", "qoderwork":
            return "qoder-hooks"
        case "qoder-cli":
            return "qoder-cli-hooks"
        case "kimi":
            return "kimi-hooks"
        case "gemini":
            return "gemini-hooks"
        default:
            break
        }

        if envelope.provider == .codex {
            return "codex-hooks"
        }

        if envelope.provider == .gemini {
            return "gemini-hooks"
        }

        let normalizedEvent = envelope.eventType.lowercased()
        if envelope.expectsResponse
            || normalizedEvent.contains("permission")
            || normalizedEvent.contains("question")
            || normalizedEvent.contains("tool") {
            return "claude-hooks"
        }

        return nil
    }

    private static func debugDirectory(for target: String, environment: [String: String]) -> URL {
        if target == "codex-hooks",
           let customPath = environment["PING_ISLAND_CODEX_HOOK_DEBUG_DIR"],
           !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: customPath).expandingTildeInPath, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island-debug", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
    }

    private static func filteredEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [:]) { partial, pair in
            if interestingEnvironmentKeys.contains(pair.key)
                || pair.key.hasPrefix("CODEBUDDY_")
                || pair.key.hasPrefix("CODEX_")
                || pair.key.hasPrefix("ISLAND_")
                || pair.key.hasPrefix("PING_ISLAND_") {
                partial[pair.key] = pair.value
            }
        }
    }

    static func logDeliveryIfNeeded(
        envelope: BridgeEnvelope,
        environment: [String: String],
        socketPath: String,
        outcome: String
    ) throws {
        guard let target = debugTarget(for: envelope) else { return }

        let fileManager = FileManager.default
        let directory = debugDirectory(for: target, environment: environment)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = BridgeDebugRecord(
            id: UUID(),
            timestamp: Date(),
            provider: envelope.provider.rawValue,
            clientKind: envelope.metadata["client_kind"],
            eventType: envelope.eventType,
            sessionKey: envelope.sessionKey,
            expectsResponse: envelope.expectsResponse,
            statusKind: envelope.status?.kind.rawValue,
            title: envelope.title,
            preview: envelope.preview,
            arguments: [],
            environment: filteredEnvironment(environment),
            metadata: envelope.metadata,
            stdinRaw: nil,
            envelopeJSON: BridgeCodec.jsonString(for: envelope),
            socketPath: socketPath,
            deliveryOutcome: outcome
        )

        let fileURL = directory.appendingPathComponent(dayStamp(for: record.timestamp) + ".jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private static func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private struct BridgeDebugRecord: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let provider: String
    let clientKind: String?
    let eventType: String
    let sessionKey: String
    let expectsResponse: Bool
    let statusKind: String?
    let title: String?
    let preview: String?
    let arguments: [String]
    let environment: [String: String]
    let metadata: [String: String]
    let stdinRaw: String?
    let envelopeJSON: String?
    let socketPath: String?
    let deliveryOutcome: String?
}

private enum BridgeError: Error {
    case invalidArguments
    case connectionFailed
}

private enum BridgeRuntimeMode: String {
    case hook
    case remoteAgentService = "remote-agent-service"
    case remoteAgentAttach = "remote-agent-attach"
    case healthCheck = "health-check"
}

private enum SocketClient {
    private static let healthCheckRequest = #"{"type":"ping-island-health-check"}"#
    private static let healthCheckResponse = #"{"ok":true}"#

    static func send(envelope: BridgeEnvelope, socketPath: String) throws -> BridgeResponse {
        let fd = socket(AF_UNIX, islandStreamSocketType, 0)
        guard fd >= 0 else {
            throw BridgeError.connectionFailed
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BridgeError.connectionFailed
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw BridgeError.connectionFailed
        }

        let data = try BridgeCodec.encodeEnvelope(envelope)
        _ = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        shutdown(fd, islandShutdownWrite)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            return BridgeResponse(requestID: envelope.id)
        }
        return try BridgeCodec.decodeResponse(Data(buffer.prefix(count)))
    }

    static func sendHealthCheck(socketPath: String) throws {
        let fd = socket(AF_UNIX, islandStreamSocketType, 0)
        guard fd >= 0 else {
            throw BridgeError.connectionFailed
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BridgeError.connectionFailed
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw BridgeError.connectionFailed
        }

        let request = Data(Self.healthCheckRequest.utf8)
        let wrote = request.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            return write(fd, baseAddress, request.count) == request.count
        }
        guard wrote else {
            throw BridgeError.connectionFailed
        }
        shutdown(fd, islandShutdownWrite)

        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            throw BridgeError.connectionFailed
        }

        let response = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == Self.healthCheckResponse else {
            throw BridgeError.connectionFailed
        }
    }
}

private final class RemoteAgentService: @unchecked Sendable {
    private let hookSocketPath: String
    private let controlSocketPath: String
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.remote-agent", qos: .userInitiated)

    private var hookServerSocket: Int32 = -1
    private var controlServerSocket: Int32 = -1
    private var hookAcceptSource: DispatchSourceRead?
    private var controlAcceptSource: DispatchSourceRead?
    private var controlClientSocket: Int32 = -1
    private var controlClientReadSource: DispatchSourceRead?
    private var controlReadBuffer = Data()
    private var pendingRequests: [UUID: PendingRemoteBridgeRequest] = [:]
    private var queuedMessages: [Data] = []
    private var codexStateSource: DispatchSourceTimer?
    private var deliveredCodexThreadUpdates: [String: Int64] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(hookSocketPath: String, controlSocketPath: String) throws {
        self.hookSocketPath = hookSocketPath
        self.controlSocketPath = controlSocketPath
    }

    func run() {
        do {
            try startServers()
            dispatchMain()
        } catch {
            FileHandle.standardError.write(Data("Remote agent failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private func startServers() throws {
        hookServerSocket = try makeListeningSocket(path: hookSocketPath)
        controlServerSocket = try makeListeningSocket(path: controlSocketPath)

        hookAcceptSource = DispatchSource.makeReadSource(fileDescriptor: hookServerSocket, queue: queue)
        hookAcceptSource?.setEventHandler { [weak self] in
            self?.acceptHookConnection()
        }
        hookAcceptSource?.resume()

        controlAcceptSource = DispatchSource.makeReadSource(fileDescriptor: controlServerSocket, queue: queue)
        controlAcceptSource?.setEventHandler { [weak self] in
            self?.acceptControlConnection()
        }
        controlAcceptSource?.resume()

        startCodexStatePolling()
    }

    private func makeListeningSocket(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, islandStreamSocketType, 0)
        guard fd >= 0 else {
            throw BridgeError.connectionFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw BridgeError.connectionFailed
        }

        chmod(path, 0o700)
        guard listen(fd, 10) == 0 else {
            close(fd)
            throw BridgeError.connectionFailed
        }
        return fd
    }

    private func startCodexStatePolling() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 2)
        source.setEventHandler { [weak self] in
            self?.pollCodexState()
        }
        codexStateSource = source
        source.resume()
    }

    private func pollCodexState() {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 15 * 60 * 1000
        let codexHome = Self.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        for thread in RemoteCodexStatePoller.readRecentThreads(codexHome: codexHome, updatedSinceMs: cutoff) {
            guard thread.updatedAtMs > (deliveredCodexThreadUpdates[thread.id] ?? 0) else { continue }
            deliveredCodexThreadUpdates[thread.id] = thread.updatedAtMs
            enqueue(RemoteBridgeMessageBuilder.message(from: thread))
        }
    }

    private nonisolated static var homeDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func acceptHookConnection() {
        let clientSocket = accept(hookServerSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        queue.async { [weak self] in
            self?.handleHookClient(clientSocket)
        }
    }

    private func handleHookClient(_ clientSocket: Int32) {
        defer {
            if pendingRequests.values.contains(where: { $0.clientSocket == clientSocket }) == false {
                close(clientSocket)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(clientSocket, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break
        }

        guard let envelope = try? BridgeCodec.decodeEnvelope(data) else {
            return
        }
        let payload = RemoteBridgeMessageBuilder.payload(from: envelope)
        let message = RemoteHookEventMessage(type: "hook_event", payload: payload)

        if payload.expectsResponse {
            guard controlClientSocket >= 0 else {
                close(clientSocket)
                return
            }
            pendingRequests[payload.requestID] = PendingRemoteBridgeRequest(
                requestID: payload.requestID,
                sessionID: payload.sessionID,
                toolUseID: payload.toolUseID,
                clientSocket: clientSocket
            )
        }

        enqueue(message)

        if payload.expectsResponse == false {
            close(clientSocket)
        }
    }

    private func acceptControlConnection() {
        let clientSocket = accept(controlServerSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        if controlClientSocket >= 0 {
            close(controlClientSocket)
            controlClientReadSource?.cancel()
            controlClientReadSource = nil
        }

        controlClientSocket = clientSocket
        sendHello()
        flushQueuedMessages()

        controlClientReadSource = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
        controlClientReadSource?.setEventHandler { [weak self] in
            self?.readControlMessages()
        }
        controlClientReadSource?.setCancelHandler { [weak self] in
            if let socket = self?.controlClientSocket, socket >= 0 {
                close(socket)
                self?.controlClientSocket = -1
            }
            self?.failOpenPendingRequests()
        }
        controlClientReadSource?.resume()
    }

    private func readControlMessages() {
        guard controlClientSocket >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(controlClientSocket, &buffer, buffer.count)
        guard count > 0 else {
            controlClientReadSource?.cancel()
            controlClientReadSource = nil
            controlReadBuffer.removeAll()
            return
        }

        controlReadBuffer.append(buffer, count: count)
        while let newlineRange = controlReadBuffer.firstRange(of: Data([0x0A])) {
            let lineData = controlReadBuffer.subdata(in: 0..<newlineRange.lowerBound)
            controlReadBuffer.removeSubrange(0...newlineRange.lowerBound)
            guard !lineData.isEmpty,
                  let message = try? decoder.decode(RemoteDecisionEnvelope.self, from: lineData) else {
                continue
            }
            handleDecision(message)
        }
    }

    private func handleDecision(_ decision: RemoteDecisionEnvelope) {
        guard let pending = pendingRequests.removeValue(forKey: decision.requestID) else {
            return
        }

        let bridgeResponse = BridgeResponse(
            requestID: pending.requestID,
            decision: RemoteBridgeMessageBuilder.bridgeDecision(
                for: decision.decision,
                updatedInput: decision.updatedInput
            ),
            reason: decision.reason,
            updatedInput: decision.updatedInput,
            errorMessage: nil
        )

        guard let data = try? BridgeCodec.encodeResponse(bridgeResponse) else {
            close(pending.clientSocket)
            return
        }

        _ = data.withUnsafeBytes { buffer in
            write(pending.clientSocket, buffer.baseAddress, buffer.count)
        }
        close(pending.clientSocket)
    }

    private func failOpenPendingRequests() {
        let pendingSockets = pendingRequests.values.map(\.clientSocket)
        pendingRequests.removeAll()
        for socket in pendingSockets {
            close(socket)
        }
    }

    private func sendHello() {
        let hello = RemoteDaemonHello(
            type: "hello",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            hostname: ProcessInfo.processInfo.hostName
        )
        enqueue(hello, flushImmediately: true)
    }

    private func enqueue<T: Encodable>(_ message: T, flushImmediately: Bool = false) {
        guard let data = try? encoder.encode(message) + Data("\n".utf8) else {
            return
        }
        queuedMessages.append(data)
        if queuedMessages.count > 128 {
            queuedMessages.removeFirst(queuedMessages.count - 128)
        }

        if flushImmediately {
            flushQueuedMessages()
        } else if controlClientSocket >= 0 {
            flushQueuedMessages()
        }
    }

    private func flushQueuedMessages() {
        guard controlClientSocket >= 0 else { return }
        while let message = queuedMessages.first {
            _ = message.withUnsafeBytes { buffer in
                write(controlClientSocket, buffer.baseAddress, buffer.count)
            }
            queuedMessages.removeFirst()
        }
    }
}

private enum RemoteAgentAttach {
    static func run(controlSocketPath: String) throws {
        let fd = socket(AF_UNIX, islandStreamSocketType, 0)
        guard fd >= 0 else {
            throw BridgeError.connectionFailed
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = controlSocketPath.utf8CString.map(UInt8.init(bitPattern:))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw BridgeError.connectionFailed
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            relay(from: FileHandle.standardInput.fileDescriptor, to: fd)
            shutdown(fd, islandShutdownWrite)
            group.leave()
        }

        relay(from: fd, to: FileHandle.standardOutput.fileDescriptor)
        group.wait()
    }

    private static func relay(from inputFD: Int32, to outputFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(inputFD, &buffer, buffer.count)
            guard count > 0 else { break }
            _ = buffer.withUnsafeBytes { rawBuffer in
                write(outputFD, rawBuffer.baseAddress, count)
            }
        }
    }
}

private struct PendingRemoteBridgeRequest {
    let requestID: UUID
    let sessionID: String
    let toolUseID: String?
    let clientSocket: Int32
}

private struct RemoteCodexThread: Equatable {
    let id: String
    let cwd: String
    let title: String?
    let preview: String?
    let rolloutPath: String?
    let source: String?
    let threadSource: String?
    let updatedAtMs: Int64
}

private enum RemoteCodexStatePoller {
    static func readRecentThreads(codexHome: URL, updatedSinceMs: Int64) -> [RemoteCodexThread] {
        guard let stateURL = newestStateDatabase(in: codexHome),
              let database = RemoteSQLiteDatabase.openReadOnly(path: stateURL.path) else {
            return []
        }
        defer { database.close() }

        let columns = database.tableColumns(named: "threads")
        guard columns.contains("id"),
              columns.contains("cwd"),
              let updatedExpression = updatedAtExpression(columns: columns) else {
            return []
        }

        let titleExpression = coalescedTextExpression(["title", "first_user_message"], columns: columns)
        let previewExpression = nullableTextExpression("preview", columns: columns)
        let rolloutPathExpression = nullableTextExpression("rollout_path", columns: columns)
        let sourceExpression = nullableTextExpression("source", columns: columns)
        let threadSourceExpression = nullableTextExpression("thread_source", columns: columns)
        let archivedPredicate = columns.contains("archived") ? "AND COALESCE(archived, 0) = 0" : ""
        let messagePredicate = "COALESCE(\(previewExpression), \(titleExpression)) IS NOT NULL"
        let query = """
        SELECT
          id,
          cwd,
          \(titleExpression) AS title,
          \(previewExpression) AS preview,
          \(rolloutPathExpression) AS rolloutPath,
          \(sourceExpression) AS source,
          \(threadSourceExpression) AS threadSource,
          \(updatedExpression) AS updatedAtMs
        FROM threads
        WHERE cwd != ''
          \(archivedPredicate)
          AND \(messagePredicate)
          AND \(updatedExpression) >= ?
        ORDER BY updatedAtMs DESC
        LIMIT 12
        """

        return database.recentCodexThreads(query: query, updatedSinceMs: updatedSinceMs)
    }

    private static func newestStateDatabase(in codexHome: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .compactMap(CodexStateDatabase.init(url:))
            .max(by: { $0.version < $1.version })?
            .url
    }

    private static func updatedAtExpression(columns: Set<String>) -> String? {
        let candidates: [String] = [
            columns.contains("updated_at_ms") ? "updated_at_ms" : nil,
            columns.contains("updated_at") ? "updated_at * 1000" : nil,
            columns.contains("created_at_ms") ? "created_at_ms" : nil,
            columns.contains("created_at") ? "created_at * 1000" : nil
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return "COALESCE(\(candidates.joined(separator: ", ")))"
    }

    private static func coalescedTextExpression(_ names: [String], columns: Set<String>) -> String {
        let expressions = names.map { nullableTextExpression($0, columns: columns) }
        return "COALESCE(\(expressions.joined(separator: ", ")))"
    }

    private static func nullableTextExpression(_ name: String, columns: Set<String>) -> String {
        columns.contains(name) ? "NULLIF(\(name), '')" : "NULL"
    }
}

private final class RemoteSQLiteDatabase {
    fileprivate typealias SQLiteOpenV2 = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
    fileprivate typealias SQLiteClose = @convention(c) (OpaquePointer?) -> Int32
    fileprivate typealias SQLitePrepareV2 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    fileprivate typealias SQLiteStep = @convention(c) (OpaquePointer?) -> Int32
    fileprivate typealias SQLiteFinalize = @convention(c) (OpaquePointer?) -> Int32
    fileprivate typealias SQLiteColumnText = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
    fileprivate typealias SQLiteColumnInt64 = @convention(c) (OpaquePointer?, Int32) -> Int64
    fileprivate typealias SQLiteBindInt64 = @convention(c) (OpaquePointer?, Int32, Int64) -> Int32

    private static let sqliteOpenReadonly: Int32 = 0x00000001
    private static let sqliteRow: Int32 = 100

    private let handle: OpaquePointer?
    private let symbols: RemoteSQLiteSymbols

    private init(handle: OpaquePointer?, symbols: RemoteSQLiteSymbols) {
        self.handle = handle
        self.symbols = symbols
    }

    static func openReadOnly(path: String) -> RemoteSQLiteDatabase? {
        guard let symbols = RemoteSQLiteSymbols.load() else { return nil }
        var handle: OpaquePointer?
        let result = path.withCString { pathPointer in
            symbols.openV2(pathPointer, &handle, sqliteOpenReadonly, nil)
        }
        guard result == 0 else {
            if handle != nil {
                _ = symbols.close(handle)
            }
            return nil
        }
        return RemoteSQLiteDatabase(handle: handle, symbols: symbols)
    }

    func close() {
        _ = symbols.close(handle)
    }

    func tableColumns(named tableName: String) -> Set<String> {
        guard tableName.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return []
        }

        var statement: OpaquePointer?
        guard prepare("PRAGMA table_info(\(tableName))", statement: &statement) else { return [] }
        defer { _ = symbols.finalize(statement) }

        var columns = Set<String>()
        while symbols.step(statement) == Self.sqliteRow {
            if let name = textColumn(statement, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    func recentCodexThreads(query: String, updatedSinceMs: Int64) -> [RemoteCodexThread] {
        var statement: OpaquePointer?
        guard prepare(query, statement: &statement) else { return [] }
        defer { _ = symbols.finalize(statement) }

        guard symbols.bindInt64(statement, 1, updatedSinceMs) == 0 else { return [] }

        var threads: [RemoteCodexThread] = []
        while symbols.step(statement) == Self.sqliteRow {
            guard let id = textColumn(statement, 0),
                  let cwd = textColumn(statement, 1),
                  !id.isEmpty,
                  !cwd.isEmpty else {
                continue
            }

            threads.append(RemoteCodexThread(
                id: id,
                cwd: cwd,
                title: textColumn(statement, 2),
                preview: textColumn(statement, 3),
                rolloutPath: textColumn(statement, 4),
                source: textColumn(statement, 5),
                threadSource: textColumn(statement, 6),
                updatedAtMs: symbols.columnInt64(statement, 7)
            ))
        }
        return threads
    }

    private func prepare(_ sql: String, statement: UnsafeMutablePointer<OpaquePointer?>) -> Bool {
        sql.withCString { sqlPointer in
            symbols.prepareV2(handle, sqlPointer, -1, statement, nil) == 0
        }
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = symbols.columnText(statement, index) else { return nil }
        let value = String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct RemoteSQLiteSymbols: @unchecked Sendable {
    // Keep the dlopen handle alive for the lifetime of the cached C symbols.
    let library: UnsafeMutableRawPointer
    let openV2: RemoteSQLiteDatabase.SQLiteOpenV2
    let close: RemoteSQLiteDatabase.SQLiteClose
    let prepareV2: RemoteSQLiteDatabase.SQLitePrepareV2
    let step: RemoteSQLiteDatabase.SQLiteStep
    let finalize: RemoteSQLiteDatabase.SQLiteFinalize
    let columnText: RemoteSQLiteDatabase.SQLiteColumnText
    let columnInt64: RemoteSQLiteDatabase.SQLiteColumnInt64
    let bindInt64: RemoteSQLiteDatabase.SQLiteBindInt64

    static func load() -> RemoteSQLiteSymbols? {
        cached
    }

    private static let cached: RemoteSQLiteSymbols? = loadUncached()

    private static func loadUncached() -> RemoteSQLiteSymbols? {
        for name in libraryNames {
            guard let library = dlopen(name, RTLD_NOW | RTLD_LOCAL),
                  let openV2: RemoteSQLiteDatabase.SQLiteOpenV2 = symbol("sqlite3_open_v2", in: library),
                  let close: RemoteSQLiteDatabase.SQLiteClose = symbol("sqlite3_close", in: library),
                  let prepareV2: RemoteSQLiteDatabase.SQLitePrepareV2 = symbol("sqlite3_prepare_v2", in: library),
                  let step: RemoteSQLiteDatabase.SQLiteStep = symbol("sqlite3_step", in: library),
                  let finalize: RemoteSQLiteDatabase.SQLiteFinalize = symbol("sqlite3_finalize", in: library),
                  let columnText: RemoteSQLiteDatabase.SQLiteColumnText = symbol("sqlite3_column_text", in: library),
                  let columnInt64: RemoteSQLiteDatabase.SQLiteColumnInt64 = symbol("sqlite3_column_int64", in: library),
                  let bindInt64: RemoteSQLiteDatabase.SQLiteBindInt64 = symbol("sqlite3_bind_int64", in: library) else {
                continue
            }

            return RemoteSQLiteSymbols(
                library: library,
                openV2: openV2,
                close: close,
                prepareV2: prepareV2,
                step: step,
                finalize: finalize,
                columnText: columnText,
                columnInt64: columnInt64,
                bindInt64: bindInt64
            )
        }
        return nil
    }

    private static var libraryNames: [String] {
        #if canImport(Darwin)
        ["/usr/lib/libsqlite3.dylib", "libsqlite3.dylib"]
        #else
        ["libsqlite3.so.0", "libsqlite3.so"]
        #endif
    }

    private static func symbol<T>(_ name: String, in library: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private struct CodexStateDatabase {
    let url: URL
    let version: Int

    init?(url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }

        let versionText = name
            .dropFirst("state_".count)
            .dropLast(".sqlite".count)
        guard let version = Int(versionText) else { return nil }

        self.url = url
        self.version = version
    }
}

private struct RemoteHookClientInfoPayload: Codable {
    let kind: String
    let profileID: String?
    let name: String?
    let bundleIdentifier: String?
    let launchURL: String?
    let origin: String?
    let originator: String?
    let threadSource: String?
    let transport: String?
    let remoteHost: String?
    let sessionFilePath: String?
    let terminalBundleIdentifier: String?
    let terminalProgram: String?
    let terminalSessionIdentifier: String?
    let iTermSessionIdentifier: String?
    let tmuxSessionIdentifier: String?
    let tmuxPaneIdentifier: String?
    let processName: String?
}

private struct RemoteHookEventPayload: Codable {
    let requestID: UUID
    let sessionID: String
    let cwd: String
    let event: String
    let status: String
    let provider: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: JSONValue]?
    let toolUseID: String?
    let notificationType: String?
    let message: String?
    let expectsResponse: Bool
    let clientInfo: RemoteHookClientInfoPayload
}

private struct RemoteHookEventMessage: Codable {
    let type: String
    let payload: RemoteHookEventPayload
}

private struct RemoteDaemonHello: Codable {
    let type: String
    let version: String
    let hostname: String
}

private struct RemoteDecisionEnvelope: Codable {
    let type: String
    let requestID: UUID
    let decision: String
    let reason: String?
    let updatedInput: [String: JSONValue]?
}

private enum RemoteBridgeMessageBuilder {
    static func message(from thread: RemoteCodexThread) -> RemoteHookEventMessage {
        RemoteHookEventMessage(type: "hook_event", payload: payload(from: thread))
    }

    static func payload(from envelope: BridgeEnvelope) -> RemoteHookEventPayload {
        let metadata = envelope.metadata
        let toolInput = decodeToolInput(from: metadata["tool_input_json"])
        let terminalContext = envelope.terminalContext
        let sessionID = resolvedSessionID(for: envelope)
        let remoteHost = firstNonEmpty(metadata["remote_host"], terminalContext.remoteHost)
        let transport = firstNonEmpty(metadata["connection_transport"], terminalContext.transport)
        let toolUseID = metadata["tool_use_id"]

        return RemoteHookEventPayload(
            requestID: envelope.id,
            sessionID: sessionID,
            cwd: envelope.cwd ?? terminalContext.currentDirectory ?? metadata["cwd"] ?? "",
            event: envelope.eventType,
            status: mapStatus(eventType: envelope.eventType, status: envelope.status?.kind, notificationType: metadata["notification_type"]),
            provider: envelope.provider.rawValue,
            pid: Int(metadata["pid"] ?? "") ?? Int(getppid()),
            tty: terminalContext.tty,
            tool: normalizedToolName(metadata["tool_name"] ?? envelope.title),
            toolInput: toolInput,
            toolUseID: toolUseID,
            notificationType: metadata["notification_type"],
            message: metadata["message"] ?? envelope.preview,
            expectsResponse: envelope.expectsResponse,
            clientInfo: RemoteHookClientInfoPayload(
                kind: clientKind(for: envelope),
                profileID: metadata["client_kind"],
                name: firstNonEmpty(metadata["client_name"], metadata["client_title"], metadata["client"]),
                bundleIdentifier: firstNonEmpty(metadata["client_bundle_id"], metadata["source_bundle_id"]),
                launchURL: firstNonEmpty(metadata["launch_url"], metadata["deeplink"], metadata["deep_link"]),
                origin: metadata["client_origin"],
                originator: firstNonEmpty(metadata["client_originator"], metadata["originator"], metadata["source_title"], terminalContext.ideName),
                threadSource: firstNonEmpty(metadata["thread_source"], metadata["session_start_source"], metadata["codex_session_start_source"]),
                transport: transport,
                remoteHost: remoteHost,
                sessionFilePath: firstNonEmpty(metadata["session_file_path"], metadata["rollout_path"], metadata["transcript_path"]),
                terminalBundleIdentifier: resolvedTerminalHostBundleIdentifier(
                    terminalBundleID: terminalContext.terminalBundleID,
                    ideBundleID: terminalContext.ideBundleID
                ),
                terminalProgram: terminalContext.terminalProgram,
                terminalSessionIdentifier: terminalContext.terminalSessionID,
                iTermSessionIdentifier: terminalContext.iTermSessionID,
                tmuxSessionIdentifier: terminalContext.tmuxSession,
                tmuxPaneIdentifier: terminalContext.tmuxPane,
                processName: firstNonEmpty(metadata["source_process_name"], metadata["process_name"])
            )
        )
    }

    private static func payload(from thread: RemoteCodexThread) -> RemoteHookEventPayload {
        let message = firstNonEmpty(thread.preview, thread.title)
        return RemoteHookEventPayload(
            requestID: UUID(),
            sessionID: thread.id,
            cwd: thread.cwd,
            event: "RemoteCodexThreadUpdated",
            status: "processing",
            provider: AgentProvider.codex.rawValue,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseID: nil,
            notificationType: nil,
            message: message,
            expectsResponse: false,
            clientInfo: RemoteHookClientInfoPayload(
                kind: "codexCLI",
                profileID: "codex-cli",
                name: "Codex CLI",
                bundleIdentifier: nil,
                launchURL: nil,
                origin: "cli",
                originator: "Codex App",
                threadSource: firstNonEmpty(thread.threadSource, thread.source, "app-server"),
                transport: "ssh",
                remoteHost: ProcessInfo.processInfo.hostName,
                sessionFilePath: thread.rolloutPath,
                terminalBundleIdentifier: nil,
                terminalProgram: nil,
                terminalSessionIdentifier: nil,
                iTermSessionIdentifier: nil,
                tmuxSessionIdentifier: nil,
                tmuxPaneIdentifier: nil,
                processName: "codex app-server"
            )
        )
    }

    static func bridgeDecision(for value: String, updatedInput: [String: JSONValue]?) -> InterventionDecision? {
        switch value {
        case "allow", "approve":
            return .approve
        case "approveForSession":
            return .approveForSession
        case "deny":
            return .deny
        case "cancel":
            return .cancel
        case "answer":
            return .answer(BridgeAnswerPayload.extractAnswers(from: updatedInput))
        default:
            return nil
        }
    }

    private static func resolvedSessionID(for envelope: BridgeEnvelope) -> String {
        let sessionId = envelope.metadata["session_id"]
            ?? envelope.metadata["thread_id"]
            ?? envelope.metadata["threadId"]
            ?? envelope.sessionKey.components(separatedBy: ":").dropFirst().joined(separator: ":")
        return sessionId.isEmpty ? envelope.sessionKey : sessionId
    }

    private static func decodeToolInput(from json: String?) -> [String: JSONValue]? {
        guard let json, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func normalizedToolName(_ rawToolName: String?) -> String? {
        guard let rawToolName else { return nil }
        switch rawToolName.lowercased() {
        case "ask_user_question", "askuserquestion":
            return "AskUserQuestion"
        default:
            return rawToolName
        }
    }

    private static func mapStatus(
        eventType: String,
        status: SessionStatusKind?,
        notificationType: String?
    ) -> String {
        if eventType == "Notification", notificationType == "idle_prompt" {
            return "waiting_for_input"
        }

        switch status {
        case .waitingForApproval:
            return "waiting_for_approval"
        case .waitingForInput:
            return "waiting_for_input"
        case .runningTool:
            return "running_tool"
        case .compacting:
            return "compacting"
        case .completed:
            return "ended"
        case .notification:
            return "notification"
        case .interrupted:
            return "waiting_for_input"
        case .idle:
            return "idle"
        case .thinking, .active, .error, .none:
            break
        }

        switch eventType {
        case "SessionEnd":
            return "ended"
        case "SessionStart", "Stop", "SubagentStop":
            return "waiting_for_input"
        case "UserPromptSubmit", "PostToolUse":
            return "processing"
        case "PreToolUse":
            return "running_tool"
        case "PreCompact":
            return "compacting"
        case "Notification":
            return "notification"
        default:
            return "processing"
        }
    }

    private static func clientKind(for envelope: BridgeEnvelope) -> String {
        let metadata = envelope.metadata
        let explicitKind = (
            metadata["client_kind"]
                ?? metadata["client_type"]
                ?? metadata["client"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch envelope.provider {
        case .claude:
            return "claudeCode"
        case .codex:
            if explicitKind?.contains("cli") == true
                || envelope.terminalContext.tty != nil
                || envelope.terminalContext.terminalProgram != nil
                || envelope.terminalContext.terminalBundleID != nil {
                return "codexCLI"
            }
            return "codexApp"
        case .copilot:
            return "custom"
        case .kimi:
            return "kimi"
        case .gemini:
            return "gemini"
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func resolvedTerminalHostBundleIdentifier(
        terminalBundleID: String?,
        ideBundleID: String?
    ) -> String? {
        let terminalBundleID = firstNonEmpty(terminalBundleID)
        let ideBundleID = firstNonEmpty(ideBundleID)

        if let terminalBundleID,
           let ideBundleID,
           terminalBundleID.caseInsensitiveCompare(ideBundleID) != .orderedSame,
           isStandaloneTerminalBundleIdentifier(terminalBundleID) {
            return terminalBundleID
        }

        return ideBundleID ?? terminalBundleID
    }

    private static func isStandaloneTerminalBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        switch bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "com.apple.terminal",
             "com.googlecode.iterm2",
             "com.mitchellh.ghostty",
             "com.cmuxterm.app",
             "io.alacritty",
             "org.alacritty",
             "net.kovidgoyal.kitty",
             "co.zeit.hyper",
             "dev.warp.warp-stable",
             "com.github.wez.wezterm":
            return true
        default:
            return false
        }
    }
}
