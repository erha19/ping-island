import Foundation
@testable import IslandApp
import Testing

@Test
func installerWritesVSCodeCompatibleExtensionPayload() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = IDEExtensionInstaller(homeDirectory: root)
    let version = IDEExtensionInstaller.extensionVersion
    try installer.installVSCodeExtension()
    try installer.installCursorExtension()
    try installer.installQoderExtension()

    let vscodeExtensionURL = root
        .appending(path: ".vscode/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let packageJSON = try String(contentsOf: vscodeExtensionURL.appending(path: "package.json"))
    let extensionJS = try String(contentsOf: vscodeExtensionURL.appending(path: "extension.js"))
    let manifest = try String(contentsOf: vscodeExtensionURL.appending(path: ".vsixmanifest"))

    #expect(packageJSON.contains("\"publisher\": \"ping-island\""))
    #expect(packageJSON.contains("\"displayName\": \"Ping Island\""))
    #expect(packageJSON.contains("\"activationEvents\""))
    #expect(extensionJS.contains("registerUriHandler"))
    #expect(extensionJS.contains("childProcess.execFileSync"))
    #expect(extensionJS.contains("focusTerminalByHint"))
    #expect(extensionJS.contains("bestMatch.terminal.show(false)"))
    #expect(!extensionJS.contains("aicoding.chat.history"))
    #expect(!extensionJS.contains("uri.path === '/session'"))
    #expect(manifest.contains("Microsoft.VisualStudio.Code"))

    let cursorExtensionURL = root
        .appending(path: ".cursor/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    #expect(FileManager.default.fileExists(atPath: cursorExtensionURL.appending(path: "package.json").path()))

    let qoderExtensionURL = root
        .appending(path: ".qoder/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let qoderExtensionJS = try String(contentsOf: qoderExtensionURL.appending(path: "extension.js"))
    #expect(FileManager.default.fileExists(atPath: qoderExtensionURL.appending(path: "package.json").path()))
    #expect(qoderExtensionJS.contains("aicoding.chat.history"))
    #expect(qoderExtensionJS.contains("uri.path === '/session'"))
    #expect(qoderExtensionJS.contains("processName"))
    #expect(qoderExtensionJS.contains("sessionId"))
    #expect(qoderExtensionJS.contains("onDidOpenTerminal"))
    #expect(qoderExtensionJS.contains("Unable to match terminal for focus request"))
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
