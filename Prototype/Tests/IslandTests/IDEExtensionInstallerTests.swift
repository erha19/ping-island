import Foundation
@testable import IslandApp
import Testing

private let repositoryURL = "https://github.com/erha19/ping-island"

@Test
func installerWritesVSCodeCompatibleExtensionPayload() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = IDEExtensionInstaller(homeDirectory: root)
    let version = IDEExtensionInstaller.extensionVersion
    #expect(version == projectMarketingVersion())
    try installer.installVSCodeExtension()
    try installer.installCursorExtension()
    try installer.installQoderExtension()

    let vscodeExtensionURL = root
        .appending(path: ".vscode/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let packageJSON = try String(contentsOf: vscodeExtensionURL.appending(path: "package.json"))
    let extensionJS = try String(contentsOf: vscodeExtensionURL.appending(path: "extension.js"))
    let readme = try String(contentsOf: vscodeExtensionURL.appending(path: "README.md"))
    let manifest = try String(contentsOf: vscodeExtensionURL.appending(path: ".vsixmanifest"))
    let iconData = try Data(contentsOf: vscodeExtensionURL.appending(path: "icon.png"))
    let referenceIconData = try Data(contentsOf: repositoryAppIconURL())

    #expect(packageJSON.contains("\"publisher\": \"ping-island\""))
    #expect(packageJSON.contains("\"displayName\": \"Ping Island\""))
    #expect(packageJSON.contains(#""version": "\#(version)""#))
    #expect(packageJSON.contains("\"activationEvents\""))
    #expect(packageJSON.contains("\"icon\": \"icon.png\""))
    #expect(packageJSON.contains(repositoryURL))
    #expect(extensionJS.contains("registerUriHandler"))
    #expect(extensionJS.contains("Received setup URI"))
    #expect(extensionJS.contains("showInformationMessage"))
    #expect(extensionJS.contains("writeProbeFile"))
    #expect(extensionJS.contains("childProcess.execFileSync"))
    #expect(extensionJS.contains("focusTerminalByHint"))
    #expect(extensionJS.contains("bestMatch.terminal.show(false)"))
    #expect(!extensionJS.contains("aicoding.chat.history"))
    #expect(!extensionJS.contains("uri.path === '/session'"))
    #expect(readme.contains(repositoryURL))
    #expect(readme.contains("Repository:\n\(repositoryURL)"))
    #expect(readme.contains("Releases:\n\(repositoryURL)/releases"))
    #expect(manifest.contains("Microsoft.VisualStudio.Code"))
    #expect(manifest.contains("Microsoft.VisualStudio.Services.Content.Details"))
    #expect(manifest.contains("Microsoft.VisualStudio.Services.Icons.Default"))
    #expect(!iconData.isEmpty)
    #expect(iconData == referenceIconData)

    let cursorExtensionURL = root
        .appending(path: ".cursor/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    #expect(FileManager.default.fileExists(atPath: cursorExtensionURL.appending(path: "package.json").path()))

    let qoderExtensionURL = root
        .appending(path: ".qoder/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let qoderExtensionJS = try String(contentsOf: qoderExtensionURL.appending(path: "extension.js"))
    let qoderReadme = try String(contentsOf: qoderExtensionURL.appending(path: "README.md"))
    #expect(FileManager.default.fileExists(atPath: qoderExtensionURL.appending(path: "package.json").path()))
    #expect(qoderExtensionJS.contains("aicoding.chat.history"))
    #expect(qoderExtensionJS.contains("uri.path === '/session'"))
    #expect(qoderExtensionJS.contains("processName"))
    #expect(qoderExtensionJS.contains("sessionId"))
    #expect(qoderExtensionJS.contains("onDidOpenTerminal"))
    #expect(qoderExtensionJS.contains("Unable to match terminal for focus request"))
    #expect(qoderReadme.contains("chat session"))
    #expect(qoderReadme.contains(repositoryURL))
}

@Test
func installerRemovesGeneratedExtensionFolders() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = IDEExtensionInstaller(homeDirectory: root)
    let version = IDEExtensionInstaller.extensionVersion
    try installer.installCodeBuddyExtension()
    try installer.installQoderExtension()
    try installer.uninstallExtensions(relativeRoots: [".codebuddy/extensions", ".qoder/extensions"])

    let codeBuddyExtensionURL = root
        .appending(path: ".codebuddy/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let qoderExtensionURL = root
        .appending(path: ".qoder/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)

    #expect(!FileManager.default.fileExists(atPath: codeBuddyExtensionURL.path()))
    #expect(!FileManager.default.fileExists(atPath: qoderExtensionURL.path()))
}

private func repositoryAppIconURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "PingIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png")
}

private func projectMarketingVersion() -> String {
    let projectURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "PingIsland.xcodeproj/project.pbxproj")
    let contents = try? String(contentsOf: projectURL, encoding: .utf8)
    let regex = try? NSRegularExpression(pattern: #"MARKETING_VERSION = ([^;]+);"#)
    guard
        let contents,
        let regex,
        let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
        let range = Range(match.range(at: 1), in: contents)
    else {
        return "1.0"
    }

    let version = contents[range].trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? "1.0" : version
}
