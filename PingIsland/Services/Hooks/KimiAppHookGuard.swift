//
//  KimiAppHookGuard.swift
//  PingIsland
//
//  Kimi's desktop app runs a vendored kimi-code kernel out of its own support
//  directory, and its daimon runner rewrites that kernel's config.toml every
//  time it starts - which silently drops the managed hook block Island wrote.
//  This guard re-applies the block whenever it goes missing so the integration
//  survives a Kimi restart without the user having to toggle the target again.
//
//  Polling (rather than a file descriptor watch) is deliberate: the file is
//  replaced, not modified in place, and a modification-date probe on a single
//  small file is cheap enough to run on the same adaptive cadence the other
//  desktop watchers use.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "KimiAppHooks")

enum KimiAppHookPaths {
    /// Home-relative path of the `config.toml` read by the kimi-code kernel that
    /// Kimi.app bundles. The CLI's own `~/.kimi-code/config.toml` is a separate
    /// target, managed by the `kimi-hooks` profile.
    nonisolated static let kernelConfigurationRelativePath =
        "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/config.toml"

    nonisolated static let managedProfileID = "kimi-app-hooks"
}

actor KimiAppHookGuard {
    static let shared = KimiAppHookGuard()

    /// Cadence used while the managed block is present and the file is stable.
    private static let idleInterval: Duration = .seconds(30)
    /// Cadence used when the target is disabled or Kimi.app has never run.
    private static let dormantInterval: Duration = .seconds(120)
    /// Cadence used right after a repair, to confirm the write survived.
    private static let verifyInterval: Duration = .seconds(5)

    enum CheckOutcome: Equatable {
        /// The target is off, or the kernel config does not exist yet.
        case dormant
        /// The managed block is present, or the file has not changed since the last probe.
        case intact
        /// The managed block was missing and has just been rewritten.
        case repaired
    }

    private var loopTask: Task<Void, Never>?
    private var lastSeenModification: Date?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard loopTask == nil else { return }
        logger.info("Starting Kimi app hook guard")
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        lastSeenModification = nil
        logger.info("Stopped Kimi app hook guard")
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let outcome = checkOnce()
            do {
                try await Task.sleep(for: Self.interval(for: outcome))
            } catch {
                break
            }
        }
    }

    nonisolated static func interval(for outcome: CheckOutcome) -> Duration {
        switch outcome {
        case .dormant:
            return dormantInterval
        case .intact:
            return idleInterval
        case .repaired:
            return verifyInterval
        }
    }

    // MARK: - Repair

    @discardableResult
    func checkOnce() -> CheckOutcome {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: KimiAppHookPaths.managedProfileID),
              HookInstaller.isPreferred(profile) else {
            lastSeenModification = nil
            return .dormant
        }

        let url = profile.primaryConfigurationURL
        guard let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            // Kimi.app has not created its kernel config yet; nothing to guard.
            lastSeenModification = nil
            return .dormant
        }

        // The daimon runner replaces the whole file, so an unchanged timestamp
        // means the managed block cannot have been dropped since the last probe.
        if let lastSeenModification, lastSeenModification == modified {
            return .intact
        }
        lastSeenModification = modified

        guard !HookInstaller.isInstalled(profile) else {
            return .intact
        }

        logger.notice("Kimi app rewrote its kernel config; reinstalling managed hooks")
        HookInstaller.install(profile)

        // Re-read the timestamp so our own write does not look like a Kimi rewrite
        // on the next probe.
        lastSeenModification = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return .repaired
    }
}
