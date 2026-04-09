import AppKit
import Foundation

struct IDEExtensionInstaller {
    nonisolated private static let extensionPublisher = "ping-island"
    nonisolated private static let extensionName = "session-focus"
    nonisolated private static let extensionIconFilename = "icon.png"
    nonisolated private static let extensionReadmeFilename = "README.md"
    nonisolated private static let projectHomepage = "https://github.com/erha19/ping-island"
    nonisolated private static let projectRepository = "https://github.com/erha19/ping-island.git"
    nonisolated private static let projectIssues = "https://github.com/erha19/ping-island/issues"

    nonisolated private static var extensionVersion: String {
        applicationVersion()
    }

    nonisolated static var extensionIdentifier: String {
        "\(extensionPublisher).\(extensionName)"
    }

    nonisolated static var extensionDirectoryName: String {
        "\(extensionIdentifier)-\(extensionVersion)"
    }

    nonisolated static func isInstalled(_ profile: ManagedIDEExtensionProfile) -> Bool {
        profile.extensionRootURLs.contains { rootURL in
            let manifestURL = extensionDirectoryURL(rootURL: rootURL).appendingPathComponent("package.json")
            return FileManager.default.fileExists(atPath: manifestURL.path)
        }
    }

    static func install(_ profile: ManagedIDEExtensionProfile) {
        for rootURL in installationTargets(for: profile) {
            installExtension(in: rootURL, profile: profile)
        }
    }

    static func reinstall(_ profile: ManagedIDEExtensionProfile) {
        uninstall(profile)
        install(profile)
    }

    static func uninstall(_ profile: ManagedIDEExtensionProfile) {
        for rootURL in profile.extensionRootURLs {
            try? FileManager.default.removeItem(at: extensionDirectoryURL(rootURL: rootURL))
        }
    }

    static func cleanupLegacyTraeExtension() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyRoots = [
            ".trae/extensions",
            ".trae-cn/extensions"
        ]

        for path in legacyRoots {
            let rootURL = path
                .split(separator: "/")
                .reduce(home) { partialURL, component in
                    partialURL.appendingPathComponent(String(component))
                }
            try? FileManager.default.removeItem(at: extensionDirectoryURL(rootURL: rootURL))
        }
    }

    @discardableResult
    static func authorize(_ profile: ManagedIDEExtensionProfile) -> Bool {
        guard let url = makeURI(profile: profile, path: "/setup") else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    nonisolated static func makeURI(
        profile: ManagedIDEExtensionProfile,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(string: "\(profile.uriScheme)://\(extensionIdentifier)") else {
            return nil
        }
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    nonisolated private static func installationTargets(for profile: ManagedIDEExtensionProfile) -> [URL] {
        let fileManager = FileManager.default
        let existingTargets = profile.extensionRootURLs.filter { rootURL in
            fileManager.fileExists(atPath: rootURL.path)
        }

        return existingTargets.isEmpty ? [profile.primaryExtensionRootURL] : existingTargets
    }

    nonisolated private static func extensionDirectoryURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(extensionDirectoryName, isDirectory: true)
    }

    private static func installExtension(in rootURL: URL, profile: ManagedIDEExtensionProfile) {
        let fileManager = FileManager.default
        let extensionURL = extensionDirectoryURL(rootURL: rootURL)

        removeStaleGeneratedExtensions(in: rootURL)
        try? fileManager.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try? Data(packageJSON(for: profile).utf8).write(
            to: extensionURL.appendingPathComponent("package.json"),
            options: .atomic
        )
        try? Data(extensionJS(for: profile).utf8).write(
            to: extensionURL.appendingPathComponent("extension.js"),
            options: .atomic
        )
        try? Data(extensionReadme(for: profile).utf8).write(
            to: extensionURL.appendingPathComponent(extensionReadmeFilename),
            options: .atomic
        )
        if let iconData = extensionIconPNGData() {
            try? iconData.write(
                to: extensionURL.appendingPathComponent(extensionIconFilename),
                options: .atomic
            )
        }
        try? Data(vsixManifest(for: profile).utf8).write(
            to: extensionURL.appendingPathComponent(".vsixmanifest"),
            options: .atomic
        )
    }

    private static func removeStaleGeneratedExtensions(in rootURL: URL) {
        let prefix = "\(extensionIdentifier)-"
        guard let existingEntries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in existingEntries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func packageJSON(for profile: ManagedIDEExtensionProfile) -> String {
        let description = extensionDescription(for: profile)

        return """
        {
          "name": "\(extensionName)",
          "displayName": "Ping Island",
          "description": "\(description)",
          "version": "\(extensionVersion)",
          "publisher": "\(extensionPublisher)",
          "icon": "\(extensionIconFilename)",
          "homepage": "\(projectHomepage)",
          "license": "Apache-2.0",
          "repository": {
            "type": "git",
            "url": "\(projectRepository)"
          },
          "bugs": {
            "url": "\(projectIssues)"
          },
          "engines": {
            "vscode": "^1.85.0"
          },
          "categories": [
            "Other"
          ],
          "activationEvents": [
            "onUri"
          ],
          "main": "./extension.js",
          "contributes": {}
        }
        """
    }

    private static func extensionJS(for profile: ManagedIDEExtensionProfile) -> String {
        let sessionFocusLogic: String

        switch profile.sessionFocusStrategy {
        case .qoderChatHistory:
            sessionFocusLogic = """
                async function focusChatSession(sessionId) {
                    if (!sessionId) return false;

                    try {
                        await vscode.commands.executeCommand('aicoding.chat.history', sessionId);
                        return true;
                    } catch (error) {
                        console.warn('[ping-island] Failed to focus chat session', sessionId, error);
                        return false;
                    }
                }
            """
        case nil:
            sessionFocusLogic = ""
        }

        let sessionRouteLogic: String
        let sessionFallbackLogic: String

        switch profile.sessionFocusStrategy {
        case .qoderChatHistory:
            sessionRouteLogic = """
                    if (uri.path === '/session') {
                        if (await focusChatSession(sessionId)) {
                            return;
                        }
                    }

            """
            sessionFallbackLogic = """
                    if (sessionId) {
                        await focusChatSession(sessionId);
                    }
            """
        case nil:
            sessionRouteLogic = ""
            sessionFallbackLogic = ""
        }

        return """
        const vscode = require('vscode');
        const childProcess = require('child_process');
        const fs = require('fs');

        function runCommand(command, args) {
            try {
                return childProcess.execFileSync(command, args, { encoding: 'utf8' }).trim();
            } catch (error) {
                return '';
            }
        }

        function normalizeTTY(value) {
            if (!value) return null;

            const normalized = String(value).trim();
            if (!normalized || normalized === '??' || normalized === '-') {
                return null;
            }

            return normalized.replace(/^\\/dev\\//, '');
        }

        function normalizePath(value) {
            if (!value) return null;

            const normalized = String(value).trim().replace(/\\/+$/, '');
            return normalized || '/';
        }

        function sleep(ms) {
            return new Promise(resolve => setTimeout(resolve, ms));
        }

        function logInfo(message, details) {
            if (details === undefined) {
                console.info(`[ping-island] ${message}`);
                return;
            }

            console.info(`[ping-island] ${message}`, JSON.stringify(details));
        }

        function logWarn(message, details) {
            if (details === undefined) {
                console.warn(`[ping-island] ${message}`);
                return;
            }

            console.warn(`[ping-island] ${message}`, JSON.stringify(details));
        }

        function writeProbeFile(path, contents) {
            if (!path) return false;

            try {
                fs.writeFileSync(path, contents, { encoding: 'utf8' });
                return true;
            } catch (error) {
                logWarn('Failed to write setup probe file', {
                    path,
                    message: error?.message || String(error),
                });
                return false;
            }
        }

        function readTTY(pid) {
            return normalizeTTY(runCommand('/bin/ps', ['-p', String(pid), '-o', 'tty=']));
        }

        function readCwd(pid) {
            const output = runCommand('/usr/sbin/lsof', ['-a', '-d', 'cwd', '-p', String(pid), '-Fn']);
            if (!output) return null;

            let foundCwdMarker = false;
            for (const line of output.split(/\\r?\\n/)) {
                if (line === 'fcwd') {
                    foundCwdMarker = true;
                    continue;
                }

                if (foundCwdMarker && line.startsWith('n')) {
                    return normalizePath(line.slice(1));
                }
            }

            return null;
        }

        function buildProcessTree() {
            const output = runCommand('/bin/ps', ['-axww', '-o', 'pid=,ppid=,command=']);
            const entries = new Map();

            for (const line of output.split(/\\r?\\n/)) {
                const trimmed = line.trim();
                if (!trimmed) continue;

                const match = trimmed.match(/^(\\d+)\\s+(\\d+)\\s+(.+)$/);
                if (!match) continue;

                const pid = Number.parseInt(match[1], 10);
                const ppid = Number.parseInt(match[2], 10);
                const command = match[3].trim();
                if (!Number.isFinite(pid) || !Number.isFinite(ppid) || !command) continue;

                entries.set(pid, { pid, ppid, command });
            }

            return entries;
        }

        function collectProcessEntries(rootPid, processTree) {
            const entries = [];
            const queue = [rootPid];
            const visited = new Set();

            while (queue.length) {
                const pid = queue.shift();
                if (visited.has(pid)) continue;
                visited.add(pid);

                const entry = processTree.get(pid);
                if (!entry) continue;
                entries.push(entry);

                for (const child of processTree.values()) {
                    if (child.ppid === pid && !visited.has(child.pid)) {
                        queue.push(child.pid);
                    }
                }
            }

            return entries;
        }

        function uniqueValues(values) {
            return Array.from(new Set(values.filter(Boolean)));
        }

        async function describeTerminal(terminal, processTree) {
            const processId = await terminal.processId;
            if (!Number.isFinite(processId) || processId <= 0) {
                return null;
            }

            const processEntries = collectProcessEntries(processId, processTree);
            const candidatePids = uniqueValues([processId, ...processEntries.map(entry => entry.pid)]).slice(0, 12);
            return {
                terminal,
                terminalName: terminal.name || null,
                processId,
                ttyCandidates: uniqueValues(candidatePids.map(readTTY)),
                cwdCandidates: uniqueValues(candidatePids.map(readCwd)),
                processEntries,
            };
        }

        function summarizeDescriptor(descriptor) {
            return {
                terminalName: descriptor.terminalName,
                processId: descriptor.processId,
                ttyCandidates: descriptor.ttyCandidates,
                cwdCandidates: descriptor.cwdCandidates.slice(0, 4),
                commands: descriptor.processEntries.slice(0, 6).map(entry => entry.command.slice(0, 160)),
            };
        }

        function processTreeContainsName(entries, processName) {
            if (!processName) return false;

            const loweredName = processName.toLowerCase();
            return entries.some(entry => entry.command.toLowerCase().includes(loweredName));
        }

        function scoreTerminalMatch(descriptor, hints) {
            let score = 0;

            if (hints.processIds.has(descriptor.processId)) {
                score += 500;
            }

            if (descriptor.processEntries.some(entry => hints.processIds.has(entry.pid))) {
                score += 420;
            }

            if (hints.tty && descriptor.ttyCandidates.includes(hints.tty)) {
                score += 260;
            }

            if (hints.cwd) {
                if (descriptor.cwdCandidates.includes(hints.cwd)) {
                    score += 220;
                } else if (descriptor.cwdCandidates.some(candidate =>
                    hints.cwd.startsWith(candidate + '/') || candidate.startsWith(hints.cwd + '/')
                )) {
                    score += 110;
                }
            }

            if (processTreeContainsName(descriptor.processEntries, hints.processName)) {
                score += 40;
            }

            const terminalName = descriptor.terminalName?.toLowerCase();
            if (terminalName && terminalName.includes(hints.processName.toLowerCase())) {
                score += 20;
            }

            return score;
        }

        async function waitForTerminalSignal(timeoutMs) {
            return new Promise(resolve => {
                const disposables = [];
                let finished = false;

                const finish = reason => {
                    if (finished) return;
                    finished = true;
                    clearTimeout(timer);
                    for (const disposable of disposables) {
                        try {
                            disposable.dispose();
                        } catch (error) {
                            // Ignore cleanup failures while we are retrying focus.
                        }
                    }
                    resolve(reason);
                };

                const subscribe = (event, reason) => {
                    if (typeof event !== 'function') return;
                    disposables.push(event(() => finish(reason)));
                };

                subscribe(vscode.window.onDidOpenTerminal, 'open');
                subscribe(vscode.window.onDidCloseTerminal, 'close');
                subscribe(vscode.window.onDidChangeActiveTerminal, 'active');
                subscribe(vscode.window.onDidChangeTerminalShellIntegration, 'shellIntegration');

                const timer = setTimeout(() => finish('timeout'), timeoutMs);
            });
        }

        async function focusTerminalByHint({ sessionId, pids, tty, cwd, processName }) {
            const hints = {
                sessionId: sessionId ? String(sessionId).trim() : null,
                processIds: new Set((pids || []).filter(pid => Number.isFinite(pid) && pid > 0)),
                tty: normalizeTTY(tty),
                cwd: normalizePath(cwd),
                processName: processName ? String(processName).trim() : null,
            };

            if (
                hints.processIds.size === 0 &&
                !hints.tty &&
                !hints.cwd &&
                !hints.processName
            ) {
                logWarn('Skipping focus request without usable terminal hints', {
                    sessionId: hints.sessionId,
                });
                return false;
            }

            logInfo('Received terminal focus request', {
                sessionId: hints.sessionId,
                pids: Array.from(hints.processIds),
                tty: hints.tty,
                cwd: hints.cwd,
                processName: hints.processName,
                terminalCount: vscode.window.terminals.length,
            });

            let lastDescriptors = [];
            for (let attempt = 0; attempt < 30; attempt += 1) {
                const processTree = buildProcessTree();
                const descriptors = (await Promise.all(
                    vscode.window.terminals.map(terminal => describeTerminal(terminal, processTree))
                )).filter(Boolean);
                lastDescriptors = descriptors;

                let bestMatch = null;
                let bestScore = 0;

                for (const descriptor of descriptors) {
                    const score = scoreTerminalMatch(descriptor, hints);
                    if (score > bestScore) {
                        bestMatch = descriptor;
                        bestScore = score;
                    }
                }

                if (bestMatch && bestScore > 0) {
                    logInfo('Matched terminal for focus request', {
                        sessionId: hints.sessionId,
                        attempt: attempt + 1,
                        score: bestScore,
                        descriptor: summarizeDescriptor(bestMatch),
                    });
                    bestMatch.terminal.show(false);
                    await vscode.commands.executeCommand('workbench.action.terminal.focus');
                    return true;
                }

                if (attempt < 29) {
                    const reason = await waitForTerminalSignal(500);
                    logInfo('Retrying terminal focus after waiting for IDE state', {
                        sessionId: hints.sessionId,
                        attempt: attempt + 1,
                        reason,
                        terminalCount: vscode.window.terminals.length,
                    });
                }
            }

            logWarn('Unable to match terminal for focus request', {
                sessionId: hints.sessionId,
                pids: Array.from(hints.processIds),
                tty: hints.tty,
                cwd: hints.cwd,
                processName: hints.processName,
                descriptors: lastDescriptors.map(summarizeDescriptor),
            });
            return false;
        }

        \(sessionFocusLogic)

        async function handleSetupURI(uri) {
            const params = new URLSearchParams(uri.query);
            const probePath = params.get('probe') || params.get('probePath');
            const details = {
                path: uri.path,
                query: uri.query || null,
                probePath,
            };

            logInfo('Received setup URI', details);

            if (probePath) {
                writeProbeFile(probePath, JSON.stringify({
                    ok: true,
                    path: uri.path,
                    query: uri.query || '',
                    handledAt: new Date().toISOString(),
                }));
            }

            await vscode.window.showInformationMessage('Ping Island is ready in \(profile.title).');
        }

        function activate(context) {
            context.subscriptions.push(
                vscode.window.registerUriHandler({
                    async handleUri(uri) {
                        if (uri.path === '/setup') {
                            await handleSetupURI(uri);
                            return;
                        }

                        const params = new URLSearchParams(uri.query);
                        const sessionId = params.get('sessionId') || params.get('session_id');
                        const pids = params.getAll('pid')
                            .map(p => parseInt(p, 10))
                            .filter(p => !isNaN(p) && p > 0);
                        const tty = params.get('tty');
                        const cwd = params.get('cwd');
                        const processName = params.get('processName') || params.get('process_name');

        \(sessionRouteLogic)                if (await focusTerminalByHint({ sessionId, pids, tty, cwd, processName })) {
                            return;
                        }

        \(sessionFallbackLogic)            }
                })
            );
        }

        function deactivate() {}
        module.exports = { activate, deactivate };
        """
    }

    private static func extensionReadme(for profile: ManagedIDEExtensionProfile) -> String {
        let capabilityLine = profile.supportsSessionFocus
            ? "It can reopen the matching chat session when the host IDE supports it, and otherwise falls back to the matching terminal tab."
            : "It reopens the matching terminal tab from Ping Island's session context."

        return """
        # Ping Island

        Ping Island installs this VS Code-compatible extension so the app can jump back into the right IDE window for your active coding session.

        \(capabilityLine)

        Manage installs, reinstalls, and authorization from Ping Island's **Settings -> Integration** panel.

        Repository:
        \(projectHomepage)

        Releases:
        \(projectHomepage)/releases
        """
    }

    private static func extensionIconPNGData() -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let size = NSSize(width: 128, height: 128)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        icon.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func extensionDescription(for profile: ManagedIDEExtensionProfile) -> String {
        profile.supportsSessionFocus
            ? "Lets Ping Island focus the matching chat session or terminal tab"
            : "Lets Ping Island focus the matching terminal tab"
    }

    nonisolated private static func applicationVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let normalized = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized?.isEmpty == false) ? normalized! : "1.0"
    }

    private static func vsixManifest(for profile: ManagedIDEExtensionProfile) -> String {
        let description = profile.supportsSessionFocus
            ? "Lets Ping Island focus the matching chat session or terminal tab in VS Code compatible IDEs."
            : "Lets Ping Island focus the matching terminal tab in VS Code compatible IDEs."

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
          <Metadata>
            <Identity Language="en-US" Id="\(extensionName)" Version="\(extensionVersion)" Publisher="\(extensionPublisher)"/>
            <DisplayName>Ping Island</DisplayName>
            <Description xml:space="preserve">\(description)</Description>
          </Metadata>
          <Installation>
            <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
          </Installation>
          <Dependencies/>
          <Assets>
            <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="package.json" Addressable="true"/>
            <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="\(extensionReadmeFilename)" Addressable="true"/>
            <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="\(extensionIconFilename)" Addressable="true"/>
          </Assets>
        </PackageManifest>
        """
    }
}
