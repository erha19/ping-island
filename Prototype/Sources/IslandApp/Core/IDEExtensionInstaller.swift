import Foundation

private enum SessionFocusStrategy {
    case qoderChatHistory
}

struct IDEExtensionInstaller {
    let homeDirectory: URL
    static let extensionIdentifier = "ping-island.session-focus"
    private static let extensionIconFilename = "icon.png"
    private static let extensionReadmeFilename = "README.md"
    private static let projectHomepage = "https://github.com/erha19/ping-island"
    private static let projectRepository = "https://github.com/erha19/ping-island.git"
    private static let projectIssues = "https://github.com/erha19/ping-island/issues"

    static var extensionVersion: String {
        applicationVersion()
    }

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func installVSCodeExtension() throws {
        try installExtension(in: ".vscode/extensions")
    }

    func installCursorExtension() throws {
        try installExtension(in: ".cursor/extensions")
    }

    func installCodeBuddyExtension() throws {
        try installExtension(in: ".codebuddy/extensions")
    }

    func installQoderExtension() throws {
        try installExtension(in: ".qoder/extensions", sessionFocusStrategy: .qoderChatHistory)
    }

    func uninstallExtensions(relativeRoots: [String]) throws {
        for root in relativeRoots {
            let rootURL = homeDirectory.appending(path: root, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: extensionDirectoryURL(rootURL: rootURL))
        }
    }

    private func installExtension(
        in relativeRoot: String,
        sessionFocusStrategy: SessionFocusStrategy? = nil
    ) throws {
        let rootURL = homeDirectory.appending(path: relativeRoot, directoryHint: .isDirectory)
        let extensionURL = extensionDirectoryURL(rootURL: rootURL)
        try removeStaleGeneratedExtensions(in: rootURL)
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try Data(packageJSON(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: "package.json"), options: .atomic)
        try Data(extensionJS(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: "extension.js"), options: .atomic)
        try Data(extensionReadme(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: Self.extensionReadmeFilename), options: .atomic)
        if let iconData = extensionIconPNGData() {
            try iconData.write(to: extensionURL.appending(path: Self.extensionIconFilename), options: .atomic)
        }
        try Data(vsixManifest(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: ".vsixmanifest"), options: .atomic)
    }

    private func removeStaleGeneratedExtensions(in rootURL: URL) throws {
        let prefix = "\(Self.extensionIdentifier)-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func extensionDirectoryURL(rootURL: URL) -> URL {
        rootURL.appending(path: "\(Self.extensionIdentifier)-\(Self.extensionVersion)", directoryHint: .isDirectory)
    }

    private func packageJSON(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let description = extensionDescription(sessionFocusStrategy: sessionFocusStrategy)

        return """
        {
          "name": "session-focus",
          "displayName": "Ping Island",
          "description": "\(description)",
          "version": "\(Self.extensionVersion)",
          "publisher": "ping-island",
          "icon": "\(Self.extensionIconFilename)",
          "homepage": "\(Self.projectHomepage)",
          "license": "Apache-2.0",
          "repository": {
            "type": "git",
            "url": "\(Self.projectRepository)"
          },
          "bugs": {
            "url": "\(Self.projectIssues)"
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

    private func extensionJS(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let sessionFocusLogic: String
        let sessionRouteLogic: String
        let sessionFallbackLogic: String

        if sessionFocusStrategy == .qoderChatHistory {
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
        } else {
            sessionFocusLogic = ""
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

            await vscode.window.showInformationMessage('Ping Island is ready.');
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

    private func extensionReadme(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let capabilityLine = sessionFocusStrategy == .qoderChatHistory
            ? "It can reopen the matching chat session when the host IDE supports it, and otherwise falls back to the matching terminal tab."
            : "It reopens the matching terminal tab from Ping Island's session context."

        return """
        # Ping Island

        Ping Island installs this VS Code-compatible extension so the app can jump back into the right IDE window for your active coding session.

        \(capabilityLine)

        Manage installs, reinstalls, and authorization from Ping Island's **Settings -> Integration** panel.

        Repository:
        \(Self.projectHomepage)

        Releases:
        \(Self.projectHomepage)/releases
        """
    }

    private func extensionIconPNGData() -> Data? {
        try? Data(contentsOf: repositoryAppIconURL())
    }

    private static func applicationVersion() -> String {
        let projectURL = repositoryRootURL().appending(path: "PingIsland.xcodeproj/project.pbxproj")
        guard
            let contents = try? String(contentsOf: projectURL, encoding: .utf8),
            let regex = try? NSRegularExpression(pattern: #"MARKETING_VERSION = ([^;]+);"#),
            let match = regex.firstMatch(
                in: contents,
                range: NSRange(contents.startIndex..., in: contents)
            ),
            let range = Range(match.range(at: 1), in: contents)
        else {
            return "1.0"
        }

        let version = contents[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "1.0" : version
    }

    private static func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repositoryAppIconURL() -> URL {
        Self.repositoryRootURL()
            .appending(path: "PingIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png")
    }

    private func extensionDescription(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        sessionFocusStrategy == nil
            ? "Lets Ping Island focus the matching terminal tab"
            : "Lets Ping Island focus the matching chat session or terminal tab"
    }

    private func vsixManifest(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let description = sessionFocusStrategy == nil
            ? "Lets Ping Island focus the matching terminal tab in VS Code compatible IDEs."
            : "Lets Ping Island focus the matching chat session or terminal tab in VS Code compatible IDEs."

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
          <Metadata>
            <Identity Language="en-US" Id="session-focus" Version="\(Self.extensionVersion)" Publisher="ping-island"/>
            <DisplayName>Ping Island</DisplayName>
            <Description xml:space="preserve">\(description)</Description>
          </Metadata>
      <Installation>
        <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
      </Installation>
      <Dependencies/>
      <Assets>
        <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="package.json" Addressable="true"/>
        <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="\(Self.extensionReadmeFilename)" Addressable="true"/>
        <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="\(Self.extensionIconFilename)" Addressable="true"/>
      </Assets>
    </PackageManifest>
    """
    }
}
