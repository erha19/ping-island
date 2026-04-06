import AppKit
import CoreGraphics

struct FullscreenAppDetector {
    static func isFullscreenAppActive(screenFrame: CGRect) -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let currentAppBundleId = Bundle.main.bundleIdentifier
        if frontmostApp.bundleIdentifier == currentAppBundleId {
            return false
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostApp.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            let visibleBounds = bounds.intersection(screenFrame)
            guard !visibleBounds.isNull else { continue }

            let widthRatio = visibleBounds.width / screenFrame.width
            let heightRatio = visibleBounds.height / screenFrame.height
            if widthRatio >= 0.96 && heightRatio >= 0.94 {
                return true
            }
        }

        return false
    }
}
