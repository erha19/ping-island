//
//  ProcessTreeBuilder.swift
//  PingIsland
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
    nonisolated static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ProcessTree")

    /// Guards the parent-chain walks against cycles in a stale snapshot.
    private nonisolated static let maximumAncestorWalkDepth = 20

    struct SSHCarrierMatch: Equatable, Sendable {
        let sshPid: Int
        let terminalPid: Int
        let tty: String?
        let candidateProcessIDs: [Int]
    }

    private nonisolated init() {}

    /// Build a process tree mapping PID -> ProcessInfo
    nonisolated func buildTree() -> [Int: ProcessInfo] {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,args"]) else {
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

    /// Whether `ancestorPid` appears anywhere in the parent chain of `pid`.
    ///
    /// Resolving a session's host app by process name is unreliable for IDE-hosted
    /// terminals: the agent binary itself can live inside the IDE's extension
    /// directory (for example `~/.vscode/extensions/…/claude`), so a name match lands
    /// on the agent instead of the app, and helper processes match too. Looking for a
    /// specific pid in the parent chain sidesteps naming altogether.
    ///
    /// - Parameters:
    ///   - ancestorPid: Candidate ancestor, typically a frontmost application's pid.
    ///   - pid: Process to walk upward from.
    ///   - tree: Process snapshot to walk.
    /// - Returns: `true` when `ancestorPid` is a strict ancestor of `pid`.
    nonisolated func isAncestor(_ ancestorPid: Int, of pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        guard ancestorPid > 1, pid != ancestorPid else {
            return false
        }

        var current = pid
        var depth = 0

        while current > 1 && depth < Self.maximumAncestorWalkDepth {
            guard let info = tree[current] else {
                return false
            }
            if info.ppid == ancestorPid {
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

    nonisolated func findInteractiveSSHCarrier(
        remoteHostHint: String?,
        tree: [Int: ProcessInfo]
    ) -> SSHCarrierMatch? {
        let hostTokens = remoteHostTokens(from: remoteHostHint)
        let matches = interactiveSSHCarrierMatches(tree: tree, hostTokens: hostTokens)

        if matches.isEmpty {
            return nil
        }

        if hostTokens.isEmpty {
            guard matches.count == 1 else { return nil }
            return matches[0].match
        }

        let sortedMatches = matches.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.match.sshPid > rhs.match.sshPid
        }

        guard let best = sortedMatches.first else { return nil }
        if sortedMatches.dropFirst().contains(where: { $0.score == best.score }) {
            return nil
        }

        return best.match
    }

    nonisolated func interactiveSSHCarriers(tree: [Int: ProcessInfo]) -> [SSHCarrierMatch] {
        interactiveSSHCarrierMatches(tree: tree, hostTokens: []).map(\.match)
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

    private nonisolated func isInteractiveSSHProcess(_ command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.contains("ssh") else { return false }
        guard !lower.contains("sshd") else { return false }
        guard !lower.contains("ssh-agent") else { return false }
        guard !lower.contains("sourcecontrol.sshhelper") else { return false }
        guard !lower.contains("xcode.sourcecontrol.sshhelper") else { return false }
        guard !lower.contains("scp ") else { return false }
        guard !lower.contains("sftp ") else { return false }
        guard !lower.contains("remote-agent-attach") else { return false }
        return true
    }

    private nonisolated func interactiveSSHCarrierMatches(
        tree: [Int: ProcessInfo],
        hostTokens: [String]
    ) -> [(match: SSHCarrierMatch, score: Int)] {
        tree.values.compactMap { info -> (match: SSHCarrierMatch, score: Int)? in
            guard isInteractiveSSHProcess(info.command) else { return nil }
            guard let terminalPid = findTerminalPid(forProcess: info.pid, tree: tree) else { return nil }

            let loweredCommand = info.command.lowercased()
            let hostMatchCount = hostTokens.filter { loweredCommand.contains($0) }.count
            if !hostTokens.isEmpty, hostMatchCount == 0 {
                return nil
            }

            let tty = info.tty
            let candidatePIDs: [Int]
            if let tty {
                candidatePIDs = self.candidateProcessIDs(forTTY: tty, tree: tree)
            } else {
                candidatePIDs = Array(Set([info.pid, terminalPid])).sorted()
            }

            var score = hostMatchCount * 100
            if tty != nil {
                score += 10
            }

            return (
                SSHCarrierMatch(
                    sshPid: info.pid,
                    terminalPid: terminalPid,
                    tty: tty,
                    candidateProcessIDs: candidatePIDs
                ),
                score
            )
        }
    }

    private nonisolated func remoteHostTokens(from remoteHostHint: String?) -> [String] {
        guard let remoteHostHint = remoteHostHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !remoteHostHint.isEmpty else {
            return []
        }

        let withoutUser = remoteHostHint.split(separator: "@").last.map(String.init) ?? remoteHostHint
        let withoutBrackets = withoutUser
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        let withoutPort: String
        if let colonIndex = withoutBrackets.lastIndex(of: ":"),
           withoutBrackets[withoutBrackets.index(after: colonIndex)...].allSatisfy(\.isNumber) {
            withoutPort = String(withoutBrackets[..<colonIndex])
        } else {
            withoutPort = withoutBrackets
        }

        let shortHost = withoutPort.split(separator: ".").first.map(String.init)
        return Array(
            Set(
                [
                    remoteHostHint,
                    withoutUser,
                    withoutBrackets,
                    withoutPort,
                    shortHost
                ]
                .compactMap { value in
                    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else {
                        return nil
                    }
                    return value
                }
            )
        )
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
