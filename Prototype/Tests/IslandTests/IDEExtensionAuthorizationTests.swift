import Foundation
@testable import IslandApp
import Testing

@Test
func installerWritesSetupURIHandlerFeedback() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = IDEExtensionInstaller(homeDirectory: root)
    let version = IDEExtensionInstaller.extensionVersion
    try installer.installVSCodeExtension()

    let vscodeExtensionURL = root
        .appending(path: ".vscode/extensions", directoryHint: .isDirectory)
        .appending(path: "ping-island.session-focus-\(version)", directoryHint: .isDirectory)
    let extensionJS = try String(contentsOf: vscodeExtensionURL.appending(path: "extension.js"))

    #expect(extensionJS.contains("async function handleSetupURI(uri)"))
    #expect(extensionJS.contains("writeProbeFile(probePath"))
    #expect(extensionJS.contains("Received setup URI"))
    #expect(extensionJS.contains("showInformationMessage('Ping Island is ready.');"))
    #expect(extensionJS.contains("if (uri.path === '/setup')"))
}
