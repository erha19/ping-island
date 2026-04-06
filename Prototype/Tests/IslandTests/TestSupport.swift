import Darwin
import Foundation
import IslandShared
import Testing

enum TestSupportError: Error, CustomStringConvertible {
    case timedOut(String)
    case executableNotFound(String)
    case failedToStartProcess(String)

    var description: String {
        switch self {
        case .timedOut(let message):
            return "Timed out: \(message)"
        case .executableNotFound(let name):
            return "Executable not found in .build: \(name)"
        case .failedToStartProcess(let message):
            return "Failed to start process: \(message)"
        }
    }
}

@MainActor
final class SnapshotRecorder {
    var snapshot = SessionSnapshot()

    var sessions: [AgentSession] {
        snapshot.sessions
    }
}

func withTemporaryDirectory<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

func waitUntil(
    timeout: Duration = .seconds(2),
    description: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }

    throw TestSupportError.timedOut(description)
}

enum TestRuntime {
    private static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static func executableURL(named name: String) throws -> URL {
        let buildRoot = packageRoot.appending(path: ".build", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw TestSupportError.executableNotFound(name)
        }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == name else { continue }
            guard url.path.contains("/debug/") else { continue }
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            matches.append(url)
        }

        if let match = matches.sorted(by: { $0.path.count < $1.path.count }).first {
            return match
        }

        throw TestSupportError.executableNotFound(name)
    }
}

struct ProcessResult {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

final class RunningProcess {
    private let process: Process
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        stdin: String = ""
    ) throws {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw TestSupportError.failedToStartProcess(error.localizedDescription)
        }

        if !stdin.isEmpty {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    func waitForExit() -> ProcessResult {
        process.waitUntilExit()
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

enum TestSocketClient {
    static func send(envelope: BridgeEnvelope, socketPath: String) throws -> BridgeResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= maxLength else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.ECONNREFUSED)
        }

        let data = try BridgeCodec.encodeEnvelope(envelope)
        try writeAll(data, to: fd)
        shutdown(fd, Int32(SHUT_WR))

        let responseData = try readAll(from: fd)
        return try BridgeCodec.decodeResponse(responseData)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress?.advanced(by: offset), data.count - offset)
            }
            guard written >= 0 else {
                throw POSIXError(.EIO)
            }
            offset += written
        }
    }

    private static func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let readCount = read(fd, &buffer, buffer.count)
            if readCount < 0 {
                throw POSIXError(.EIO)
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data
    }
}
