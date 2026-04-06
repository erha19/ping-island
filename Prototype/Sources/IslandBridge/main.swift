import Foundation
import IslandShared
import Darwin

@main
struct IslandBridgeMain {
    static func main() async {
        do {
            let source = try parseSource(arguments: CommandLine.arguments)
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            var environment = ProcessInfo.processInfo.environment
            if environment["TTY"]?.isEmpty != false, let tty = detectTTY(parentPID: getppid()) {
                environment["TTY"] = tty
            }
            let envelope = HookPayloadMapper.makeEnvelope(
                source: source,
                arguments: CommandLine.arguments,
                environment: environment,
                stdinData: stdinData
            )
            try? BridgeDebugLogger.logIfNeeded(
                envelope: envelope,
                arguments: CommandLine.arguments,
                environment: environment,
                stdinData: stdinData
            )

            let response = try sendEnvelopeIfPossible(
                envelope: envelope,
                socketPath: environment["ISLAND_SOCKET_PATH"] ?? "/tmp/island.sock"
            )

            if let response, response.decision != nil {
                let payload = HookPayloadMapper.stdoutPayload(
                    for: source,
                    response: response,
                    eventType: envelope.eventType,
                    metadata: envelope.metadata
                )
                FileHandle.standardOutput.write(Data(payload.utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("IslandBridge error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
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
            envelopeJSON: BridgeCodec.jsonString(for: envelope)
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
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private static func debugTarget(for envelope: BridgeEnvelope) -> String? {
        let clientKind = envelope.metadata["client_kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch clientKind {
        case "codebuddy":
            return "codebuddy-hooks"
        case "qoder", "qoderwork":
            return "qoder-hooks"
        default:
            break
        }

        if envelope.provider == .codex {
            return "codex-hooks"
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
            if interestingEnvironmentKeys.contains(pair.key) || pair.key.hasPrefix("CODEBUDDY_") || pair.key.hasPrefix("CODEX_") {
                partial[pair.key] = pair.value
            }
        }
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
}

private enum BridgeError: Error {
    case invalidArguments
    case connectionFailed
}

private enum SocketClient {
    static func send(envelope: BridgeEnvelope, socketPath: String) throws -> BridgeResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeError.connectionFailed
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
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
        shutdown(fd, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            return BridgeResponse(requestID: envelope.id)
        }
        return try BridgeCodec.decodeResponse(Data(buffer.prefix(count)))
    }
}
