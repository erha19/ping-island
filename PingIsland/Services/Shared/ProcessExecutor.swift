//
//  ProcessExecutor.swift
//  PingIsland
//
//  Shared utility for executing shell commands with proper error handling
//

import Foundation
import os.log
import Darwin

/// Errors that can occur during process execution
nonisolated enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, underlying: Error)
    case timedOut(command: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let command, let exitCode, let stderr):
            let stderrInfo = stderr.map { ", stderr: \($0)" } ?? ""
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrInfo)"
        case .invalidOutput(let command):
            return "Command '\(command)' produced invalid output"
        case .commandNotFound(let command):
            return "Command not found: \(command)"
        case .launchFailed(let command, let underlying):
            return "Failed to launch '\(command)': \(underlying.localizedDescription)"
        case .timedOut(let command, let timeout):
            return "Command '\(command)' timed out after \(Int(timeout.rounded()))s"
        }
    }
}

/// Result type for process execution
nonisolated struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stderr: String?

    var isSuccess: Bool { exitCode == 0 }
}

/// Protocol for executing shell commands (enables testing)
nonisolated protocol ProcessExecuting: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError>
    func runWithResult(_ executable: String, arguments: [String], timeout: TimeInterval?) async -> Result<ProcessResult, ProcessExecutorError>
    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError>
}

/// Default implementation using Foundation.Process
nonisolated struct ProcessExecutor: ProcessExecuting {
    static let shared = ProcessExecutor()

    nonisolated static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ProcessExecutor")

    private init() {}

    /// Run a command asynchronously and return output (throws on failure)
    func run(_ executable: String, arguments: [String]) async throws -> String {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let processResult):
            return processResult.output
        case .failure(let error):
            throw error
        }
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        await runWithResult(executable, arguments: arguments, timeout: nil)
    }

    /// Run a command asynchronously and optionally terminate it on timeout.
    func runWithResult(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> Result<ProcessResult, ProcessExecutorError> {
        await withCheckedContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let state = ProcessExecutionState()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                state.appendStdout(data)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                state.appendStderr(data)
            }

            @Sendable
            func finish(_ result: Result<ProcessResult, ProcessExecutorError>) {
                guard state.markFinished() else { return }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: result)
            }

            do {
                process.terminationHandler = { process in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                    let result = state.makeResult(exitCode: process.terminationStatus)
                    if process.terminationStatus == 0 {
                        finish(.success(result))
                    } else {
                        Self.logger.warning("Command failed: \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) - exit code \(process.terminationStatus)")
                        finish(.failure(.executionFailed(
                            command: executable,
                            exitCode: process.terminationStatus,
                            stderr: result.stderr
                        )))
                    }
                }

                try process.run()

                if let timeout, timeout > 0 {
                    let deadline = DispatchTime.now() + timeout
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                        guard !state.isFinished else { return }
                        terminateProcess(process)
                        Self.logger.warning("Command timed out: \(executable, privacy: .public) after \(Int(timeout.rounded()))s")
                        finish(.failure(.timedOut(command: executable, timeout: timeout)))
                    }
                }
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    Self.logger.error("Command not found: \(executable, privacy: .public)")
                    finish(.failure(.commandNotFound(executable)))
                } else {
                    Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    finish(.failure(.launchFailed(command: executable, underlying: error)))
                }
            } catch {
                Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                finish(.failure(.launchFailed(command: executable, underlying: error)))
            }
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)

            if process.terminationStatus == 0 {
                return .success(stdout)
            } else {
                Self.logger.warning("Sync command failed: \(executable, privacy: .public) - exit code \(process.terminationStatus)")
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: process.terminationStatus,
                    stderr: stderr
                ))
            }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            } else {
                Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                return .failure(.launchFailed(command: executable, underlying: error))
            }
        } catch {
            Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return .failure(.launchFailed(command: executable, underlying: error))
        }
    }
}

private nonisolated final class ProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var finished = false

    nonisolated var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    nonisolated func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    nonisolated func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    nonisolated func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    nonisolated func makeResult(exitCode: Int32) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }

        let output = String(data: stdout, encoding: .utf8) ?? ""
        let stderrText = String(data: stderr, encoding: .utf8)

        return ProcessResult(
            output: output,
            exitCode: exitCode,
            stderr: stderrText
        )
    }
}

private nonisolated func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }

    process.terminate()

    let deadline = Date().addingTimeInterval(0.2)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }

    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Convenience Extensions

extension ProcessExecutor {
    /// Run a command and return output, returning nil only if the command itself fails to execute
    /// (as opposed to non-zero exit codes which may still have useful output)
    func runOrNil(_ executable: String, arguments: [String]) async -> String? {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let processResult):
            return processResult.output
        case .failure:
            return nil
        }
    }

    /// Run a command synchronously, returning nil on failure (backwards compatible)
    func runSyncOrNil(_ executable: String, arguments: [String]) -> String? {
        switch runSync(executable, arguments: arguments) {
        case .success(let output):
            return output
        case .failure:
            return nil
        }
    }
}
