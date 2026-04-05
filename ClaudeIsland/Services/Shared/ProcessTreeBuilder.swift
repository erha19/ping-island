//
//  ProcessTreeBuilder.swift
//  ClaudeIsland
//
//  Builds and queries process trees using ps command
//

import Foundation
import os.log

/// Information about a process in the tree
struct ProcessInfo: Sendable {
    let pid: Int
    let ppid: Int
    let command: String
    let tty: String?

    nonisolated init(pid: Int, ppid: Int, command: String, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.tty = tty
    }
}

/// Builds and queries the system process tree
struct ProcessTreeBuilder: Sendable {
    nonisolated static let shared = ProcessTreeBuilder()
    nonisolated static let logger = Logger(subsystem: "com.wudanwu.island", category: "ProcessTree")

    private nonisolated init() {}

    /// Build a process tree mapping PID -> ProcessInfo
    nonisolated func buildTree() -> [Int: ProcessInfo] {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,comm"]) else {
            return [:]
        }

        var tree: [Int: ProcessInfo] = [:]

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else { continue }

            let tty = parts[2] == "??" ? nil : parts[2]
            let command = parts[3...].joined(separator: " ")

            tree[pid] = ProcessInfo(pid: pid, ppid: ppid, command: command, tty: tty)
        }

        return tree
    }

    /// Check if a process has tmux in its parent chain
    nonisolated func isInTmux(pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }
            if info.command.lowercased().contains("tmux") {
                return true
            }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Walk up the process tree to find the terminal app PID
    nonisolated func findTerminalPid(forProcess pid: Int, tree: [Int: ProcessInfo]) -> Int? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }

            if TerminalAppRegistry.isTerminal(info.command) {
                Self.logger.debug("Matched terminal via parent chain pid=\(pid, privacy: .public) terminalPid=\(current, privacy: .public) command=\(info.command, privacy: .public)")
                return current
            }

            current = info.ppid
            depth += 1
        }

        Self.logger.debug("No terminal found in parent chain for pid=\(pid, privacy: .public)")
        return nil
    }

    /// Find the terminal app PID for the process group attached to a TTY.
    /// This is more reliable than following a single child process when the
    /// tool process is launched from an intermediate host such as Codex.
    nonisolated func findTerminalPid(forTTY tty: String, tree: [Int: ProcessInfo]) -> Int? {
        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        let candidates = candidateProcesses(forTTY: normalizedTTY, tree: tree)

        let candidateSummary = candidates.map { "\($0.pid):\($0.command)" }.joined(separator: ", ")
        Self.logger.debug("TTY lookup tty=\(normalizedTTY, privacy: .public) candidates=[\(candidateSummary, privacy: .public)]")

        for candidate in candidates {
            if let terminalPid = findTerminalPid(forProcess: candidate.pid, tree: tree) {
                Self.logger.debug("TTY lookup matched tty=\(normalizedTTY, privacy: .public) candidatePid=\(candidate.pid, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
                return terminalPid
            }
        }

        Self.logger.debug("TTY lookup failed tty=\(normalizedTTY, privacy: .public)")
        return nil
    }

    nonisolated func candidateProcessIDs(forTTY tty: String, tree: [Int: ProcessInfo]) -> [Int] {
        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        return candidateProcesses(forTTY: normalizedTTY, tree: tree).map(\.pid)
    }

    /// Check if targetPid is a descendant of ancestorPid
    nonisolated func isDescendant(targetPid: Int, ofAncestor ancestorPid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = targetPid
        var depth = 0

        while current > 1 && depth < 50 {
            if current == ancestorPid {
                return true
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Find all descendant PIDs of a given process
    nonisolated func findDescendants(of pid: Int, tree: [Int: ProcessInfo]) -> Set<Int> {
        var descendants: Set<Int> = []
        var queue = [pid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (childPid, info) in tree where info.ppid == current {
                if !descendants.contains(childPid) {
                    descendants.insert(childPid)
                    queue.append(childPid)
                }
            }
        }

        return descendants
    }

    /// Get working directory for a process using lsof
    nonisolated func getWorkingDirectory(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"]) else {
            return nil
        }

        var foundCwd = false
        for line in output.components(separatedBy: "\n") {
            if line == "fcwd" {
                foundCwd = true
            } else if foundCwd && line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }

    private nonisolated func processSelectionScore(for command: String) -> Int {
        let lower = command.lowercased()

        if lower.contains("zsh") || lower.contains("bash") || lower.contains("fish") || lower.contains("/sh") {
            return 4
        }

        if lower.contains("login") {
            return 3
        }

        if lower.contains("claude") || lower.contains("codex") {
            return 2
        }

        return 1
    }

    private nonisolated func candidateProcesses(forTTY normalizedTTY: String, tree: [Int: ProcessInfo]) -> [ProcessInfo] {
        tree.values
            .filter { $0.tty == normalizedTTY }
            .sorted { lhs, rhs in
                let lhsScore = processSelectionScore(for: lhs.command)
                let rhsScore = processSelectionScore(for: rhs.command)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return lhs.pid > rhs.pid
            }
    }
}
