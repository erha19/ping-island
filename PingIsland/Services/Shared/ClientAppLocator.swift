import AppKit
import Foundation

enum ClientAppLocator {
    nonisolated static func applicationURL(bundleIdentifiers: [String]) -> URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return appURL
            }
        }
        return nil
    }

    nonisolated static func isInstalled(bundleIdentifiers: [String]) -> Bool {
        applicationURL(bundleIdentifiers: bundleIdentifiers) != nil
    }

    nonisolated static func icon(bundleIdentifiers: [String]) -> NSImage? {
        guard let appURL = applicationURL(bundleIdentifiers: bundleIdentifiers) else {
            return nil
        }

        if let bundledIcon = bundleIcon(at: appURL) {
            bundledIcon.size = NSSize(width: 64, height: 64)
            return bundledIcon
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    nonisolated private static func bundleIcon(at appURL: URL) -> NSImage? {
        guard
            let bundle = Bundle(url: appURL),
            let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        else {
            return nil
        }

        let iconFileName: String
        if URL(fileURLWithPath: iconFile).pathExtension.isEmpty {
            iconFileName = iconFile + ".icns"
        } else {
            iconFileName = iconFile
        }

        let iconURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(iconFileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            return nil
        }

        return NSImage(contentsOf: iconURL)
    }
}
