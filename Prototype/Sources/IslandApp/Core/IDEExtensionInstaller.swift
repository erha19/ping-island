import Foundation

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

    func installTraeExtension() throws {
        try installExtension(in: ".trae/extensions")
    }

    func installCodeBuddyExtension() throws {
        try installExtension(in: ".codebuddy/extensions")
    }

    func installQoderExtension() throws {
        try installExtension(in: ".qoder/extensions")
    }

    func uninstallExtensions(relativeRoots: [String]) throws {
        for root in relativeRoots {
            let rootURL = homeDirectory.appending(path: root, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: extensionDirectoryURL(rootURL: rootURL))
        }
    }

    private func installExtension(in relativeRoot: String) throws {
        let rootURL = homeDirectory.appending(path: relativeRoot, directoryHint: .isDirectory)
        let extensionURL = extensionDirectoryURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try Data(packageJSON.utf8).write(to: extensionURL.appending(path: "package.json"), options: .atomic)
        try Data(extensionJS.utf8).write(to: extensionURL.appending(path: "extension.js"), options: .atomic)
        try Data(vsixManifest.utf8).write(to: extensionURL.appending(path: ".vsixmanifest"), options: .atomic)
    }

    private func extensionDirectoryURL(rootURL: URL) -> URL {
        rootURL.appending(path: "\(Self.extensionIdentifier)-\(Self.extensionVersion)", directoryHint: .isDirectory)
    }

    private var packageJSON: String {
        """
        {
          "name": "session-focus",
          "displayName": "Ping Island",
          "description": "Lets Ping Island focus the matching chat session or terminal tab",
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

    private let extensionJS = """
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

                    if (uri.path === '/session') {
                        if (await focusChatSession(sessionId)) {
                            return;
                        }
                    }

                    if (await focusTerminalByPid(pids)) {
                        return;
                    }

                    if (sessionId) {
                        await focusChatSession(sessionId);
                    }
                }
            })
        );
    }

    function deactivate() {}
    module.exports = { activate, deactivate };
    """

    private let vsixManifest = """
        <?xml version="1.0" encoding="utf-8"?>
        <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
          <Metadata>
            <Identity Language="en-US" Id="session-focus" Version="1.0.0" Publisher="ping-island"/>
            <DisplayName>Ping Island</DisplayName>
            <Description xml:space="preserve">Lets Ping Island focus the matching chat session or terminal tab in VS Code compatible IDEs.</Description>
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
