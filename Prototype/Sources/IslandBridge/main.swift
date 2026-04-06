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
