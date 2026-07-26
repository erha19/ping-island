import CoreGraphics

/// Layout helpers for closed detailed mode on camera-notch MacBooks.
///
/// The hardware cutout cannot show pixels, so detailed closed mode grows the
/// black island downward and places pet / title / badge on one row strictly
/// below the system notch inset (plus a small lip) so center text is not covered.
/// The below-camera visible band is slightly taller than the content row; the
/// row stays top-aligned inside that band with padding underneath.
enum ClosedNotchPhysicalLayout {
    /// Height of the content row under the camera (pet + title + badge).
    static let textBandHeight: CGFloat = 16

    /// Extra points under the content row inside the below-camera visible band.
    static let visibleBandBottomPadding: CGFloat = 6

    /// Full below-camera band: content row plus bottom breathing room.
    static var visibleBandHeight: CGFloat {
        textBandHeight + visibleBandBottomPadding
    }

    /// Extra points below the system notch inset before the content row starts.
    /// Clears the camera housing lip that still covers glyphs when the row is
    /// flush with `safeAreaTop`.
    static let cameraLipPadding: CGFloat = 6

    /// Empty band kept above the content row so center text clears the camera.
    static func cameraClearanceHeight(deviceNotchHeight: CGFloat) -> CGFloat {
        let base = deviceNotchHeight > 0 ? deviceNotchHeight : 32
        return base + cameraLipPadding
    }

    /// Closed island height: camera clearance plus the below-camera visible band.
    static func preferredClosedHeight(deviceNotchHeight: CGFloat) -> CGFloat {
        cameraClearanceHeight(deviceNotchHeight: deviceNotchHeight) + visibleBandHeight
    }
}
