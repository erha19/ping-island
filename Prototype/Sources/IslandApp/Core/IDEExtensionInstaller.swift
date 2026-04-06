import Foundation

private enum SessionFocusStrategy {
    case qoderChatHistory
}

struct IDEExtensionInstaller {
    let homeDirectory: URL
    static let extensionIdentifier = "ping-island.session-focus"
    static let extensionVersion = "1.0.0"

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
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try Data(packageJSON(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: "package.json"), options: .atomic)
        try Data(extensionJS(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: "extension.js"), options: .atomic)
        try Data(vsixManifest(sessionFocusStrategy: sessionFocusStrategy).utf8).write(to: extensionURL.appending(path: ".vsixmanifest"), options: .atomic)
    }

    private func extensionDirectoryURL(rootURL: URL) -> URL {
        rootURL.appending(path: "\(Self.extensionIdentifier)-\(Self.extensionVersion)", directoryHint: .isDirectory)
    }

    private func packageJSON(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let description = sessionFocusStrategy == nil
            ? "Lets Ping Island focus the matching terminal tab"
            : "Lets Ping Island focus the matching chat session or terminal tab"

        return """
        {
          "name": "session-focus",
          "displayName": "Ping Island",
          "description": "\(description)",
          "version": "\(Self.extensionVersion)",
          "publisher": "ping-island",
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

        async function focusTerminalByPid(pids) {
            if (!pids.length) return false;

            for (const terminal of vscode.window.terminals) {
                const termPid = await terminal.processId;
                if (pids.includes(termPid)) {
                    terminal.show(false);
                    return true;
                }
            }

            return false;
        }

        \(sessionFocusLogic)

        function activate(context) {
            context.subscriptions.push(
                vscode.window.registerUriHandler({
                    async handleUri(uri) {
                        if (uri.path === '/setup') return;

                        const params = new URLSearchParams(uri.query);
                        const sessionId = params.get('sessionId') || params.get('session_id');
                        const pids = params.getAll('pid')
                            .map(p => parseInt(p, 10))
                            .filter(p => !isNaN(p) && p > 0);

        \(sessionRouteLogic)                if (await focusTerminalByPid(pids)) {
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

    private func vsixManifest(sessionFocusStrategy: SessionFocusStrategy?) -> String {
        let description = sessionFocusStrategy == nil
            ? "Lets Ping Island focus the matching terminal tab in VS Code compatible IDEs."
            : "Lets Ping Island focus the matching chat session or terminal tab in VS Code compatible IDEs."

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
          <Metadata>
            <Identity Language="en-US" Id="session-focus" Version="1.0.0" Publisher="ping-island"/>
            <DisplayName>Ping Island</DisplayName>
            <Description xml:space="preserve">\(description)</Description>
          </Metadata>
      <Installation>
        <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
      </Installation>
      <Dependencies/>
      <Assets>
        <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="package.json" Addressable="true"/>
      </Assets>
    </PackageManifest>
    """
    }
}
