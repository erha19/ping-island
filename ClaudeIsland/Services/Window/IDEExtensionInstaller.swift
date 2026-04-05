import AppKit
import Foundation

struct IDEExtensionInstaller {
    nonisolated private static let extensionPublisher = "ping-island"
    nonisolated private static let extensionName = "session-focus"
    nonisolated private static let extensionVersion = "1.0.0"

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
            installExtension(in: rootURL)
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

    private static func installExtension(in rootURL: URL) {
        let fileManager = FileManager.default
        let extensionURL = extensionDirectoryURL(rootURL: rootURL)

        try? fileManager.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try? Data(packageJSON.utf8).write(
            to: extensionURL.appendingPathComponent("package.json"),
            options: .atomic
        )
        try? Data(extensionJS.utf8).write(
            to: extensionURL.appendingPathComponent("extension.js"),
            options: .atomic
        )
        try? Data(vsixManifest.utf8).write(
            to: extensionURL.appendingPathComponent(".vsixmanifest"),
            options: .atomic
        )
    }

    private static var packageJSON: String {
        """
        {
          "name": "\(extensionName)",
          "displayName": "Ping Island",
          "description": "Lets Ping Island focus the matching chat session or terminal tab",
          "version": "\(extensionVersion)",
          "publisher": "\(extensionPublisher)",
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

    private static let extensionJS = """
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

    private static var vsixManifest: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
          <Metadata>
            <Identity Language="en-US" Id="\(extensionName)" Version="\(extensionVersion)" Publisher="\(extensionPublisher)"/>
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
}
