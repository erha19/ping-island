import AppKit
import CoreGraphics

struct FullscreenAppDetector {
    static func isFullscreenAppActive(screenFrame: CGRect) -> Bool {
        guard let frontmostApp = frontmostApplicationExcludingSelf() else {
            return false
        }

        return isFullscreenWindowOwned(by: frontmostApp.processIdentifier, screenFrame: screenFrame)
    }

    static func isFullscreenBrowserActive(screenFrame: CGRect) -> Bool {
        guard let frontmostApp = frontmostApplicationExcludingSelf(),
              isBrowserBundleIdentifier(frontmostApp.bundleIdentifier) else {
            return false
        }

        return isFullscreenWindowOwned(by: frontmostApp.processIdentifier, screenFrame: screenFrame)
    }

    static func isBrowserBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let normalized = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }

        let knownBundleIdentifiers: Set<String> = [
            "com.apple.safari",
            "com.apple.safaritechnologypreview",
            "com.google.chrome",
            "com.google.chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "company.thebrowser.browser",
            "com.operasoftware.opera",
            "org.mozilla.firefox"
        ]

        if knownBundleIdentifiers.contains(normalized) {
            return true
        }

        return normalized.contains("chrome")
            || normalized.contains("safari")
            || normalized.contains("edge")
            || normalized.contains("brave")
            || normalized.contains("opera")
            || normalized.contains("firefox")
    }

    private static func frontmostApplicationExcludingSelf() -> NSRunningApplication? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let currentAppBundleId = Bundle.main.bundleIdentifier
        if frontmostApp.bundleIdentifier == currentAppBundleId {
            return nil
        }

        return frontmostApp
    }

    private static func isFullscreenWindowOwned(by processIdentifier: pid_t, screenFrame: CGRect) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            if isLikelyFullscreenWindow(bounds: bounds, screenFrame: screenFrame) {
                return true
            }
        }

        return false
    }

    static func isLikelyFullscreenWindow(bounds: CGRect, screenFrame: CGRect, tolerance: CGFloat = 2) -> Bool {
        let visibleBounds = bounds.intersection(screenFrame)
        guard !visibleBounds.isNull else { return false }

        let widthRatio = visibleBounds.width / screenFrame.width
        let heightRatio = visibleBounds.height / screenFrame.height
        guard widthRatio >= 0.985, heightRatio >= 0.985 else {
            return false
        }

        let leftInset = abs(visibleBounds.minX - screenFrame.minX)
        let rightInset = abs(screenFrame.maxX - visibleBounds.maxX)
        let bottomInset = abs(visibleBounds.minY - screenFrame.minY)
        let topInset = abs(screenFrame.maxY - visibleBounds.maxY)

        return leftInset <= tolerance
            && rightInset <= tolerance
            && bottomInset <= tolerance
            && topInset <= tolerance
    }
}
