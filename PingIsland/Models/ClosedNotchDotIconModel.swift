import Foundation
import SwiftUI

/// Logical pixel inside the closed-notch status-bar canvas (2×4).
struct ClosedNotchDotPoint: Hashable, Sendable {
    let x: Int
    let y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

/// Status coloring for the docked closed-notch dot icon.
enum ClosedNotchDotTone: Equatable, Sendable {
    case idle
    case working
    case warning

    struct RGB: Equatable, Sendable {
        let r: Double
        let g: Double
        let b: Double
    }

    static func from(status: MascotStatus) -> ClosedNotchDotTone {
        switch status {
        case .idle, .dragging:
            return .idle
        case .working:
            return .working
        case .warning:
            return .warning
        }
    }

    /// Matches TerminalColors amber / green / red for testable equality.
    var rgb: RGB {
        switch self {
        case .idle:
            return RGB(r: 1.0, g: 0.7, b: 0.0)
        case .working:
            return RGB(r: 0.4, g: 0.75, b: 0.45)
        case .warning:
            return RGB(r: 1.0, g: 0.3, b: 0.3)
        }
    }

    var color: Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// How the right-hand status column animates.
enum ClosedNotchDotStatusMotion: Equatable, Sendable {
    case staticBar
    case spin
    case blink

    static func from(status: MascotStatus) -> ClosedNotchDotStatusMotion {
        switch status {
        case .working:
            return .spin
        case .warning:
            return .blink
        case .idle, .dragging:
            return .staticBar
        }
    }
}

/// Status-bar pixel grid for the closed docked notch (identity is `MascotView`).
enum ClosedNotchDotGlyph {
    static let canvasColumns = 2
    static let canvasRows = 4

    /// Geometric center of the status bar (pivot for working spin).
    static var statusBarCenter: (x: CGFloat, y: CGFloat) {
        (x: 0.5, y: 1.5)
    }

    /// Full 2×4 status column.
    static let statusBarPoints: [ClosedNotchDotPoint] = [
        ClosedNotchDotPoint(0, 0), ClosedNotchDotPoint(1, 0),
        ClosedNotchDotPoint(0, 1), ClosedNotchDotPoint(1, 1),
        ClosedNotchDotPoint(0, 2), ClosedNotchDotPoint(1, 2),
        ClosedNotchDotPoint(0, 3), ClosedNotchDotPoint(1, 3),
    ]

    static func rotatedPoint(
        _ point: ClosedNotchDotPoint,
        angleRadians: Double,
        around center: (x: CGFloat, y: CGFloat)
    ) -> (x: CGFloat, y: CGFloat) {
        let dx = CGFloat(point.x) - center.x
        let dy = CGFloat(point.y) - center.y
        let cosA = CGFloat(cos(angleRadians))
        let sinA = CGFloat(sin(angleRadians))
        return (
            x: center.x + dx * cosA - dy * sinA,
            y: center.y + dx * sinA + dy * cosA
        )
    }

    /// Rigid-body spin of the status bar around its own center.
    static func rotatedStatusBarCenters(angleRadians: Double) -> [(x: CGFloat, y: CGFloat)] {
        statusBarPoints.map {
            rotatedPoint($0, angleRadians: angleRadians, around: statusBarCenter)
        }
    }
}
