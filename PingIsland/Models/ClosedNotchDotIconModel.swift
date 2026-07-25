import Foundation
import SwiftUI

/// Logical pixel inside the closed-notch dot canvas (10×4).
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

/// Left identity silhouette + shared right status bar for the closed docked notch.
enum ClosedNotchDotGlyph {
    static let canvasColumns = 10
    static let canvasRows = 4

    /// Geometric center of the right-hand status bar (pivot for working spin).
    static var statusBarCenter: (x: CGFloat, y: CGFloat) {
        (x: 8.5, y: 1.5)
    }

    /// Shared 2×4 status column on the right of the 10×4 canvas.
    static let statusBarPoints: [ClosedNotchDotPoint] = [
        ClosedNotchDotPoint(8, 0), ClosedNotchDotPoint(9, 0),
        ClosedNotchDotPoint(8, 1), ClosedNotchDotPoint(9, 1),
        ClosedNotchDotPoint(8, 2), ClosedNotchDotPoint(9, 2),
        ClosedNotchDotPoint(8, 3), ClosedNotchDotPoint(9, 3),
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

    static func silhouette(for kind: MascotKind) -> Set<ClosedNotchDotPoint> {
        Set(points(for: kind).map { ClosedNotchDotPoint($0.0, $0.1) })
    }

    /// Distinct 6×4 agent outlines (columns 0…5, rows 0…3).
    private static func points(for kind: MascotKind) -> [(Int, Int)] {
        switch kind {
        case .claude:
            // Cat ears + face (matches the reference silhouette).
            return [
                (1, 0), (3, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
                (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2),
                (0, 3), (1, 3), (4, 3), (5, 3),
            ]
        case .codex:
            // Soft cloud blob.
            return [
                (1, 0), (2, 0), (3, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1),
                (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2),
                (1, 3), (2, 3), (3, 3), (4, 3),
            ]
        case .gemini:
            // Twin diamond / dual spark.
            return [
                (1, 0), (4, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
                (1, 2), (2, 2), (3, 2), (4, 2),
                (2, 3), (3, 3),
            ]
        case .hermes:
            // Winged helmet / fox ears.
            return [
                (0, 0), (2, 0), (4, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1),
                (1, 2), (2, 2), (3, 2),
                (1, 3), (3, 3),
            ]
        case .pi:
            // π stem with orbit dots.
            return [
                (0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0),
                (1, 1), (4, 1),
                (1, 2), (4, 2),
                (1, 3), (2, 3), (4, 3),
            ]
        case .qwen:
            // Round capybara head + scarf hint.
            return [
                (1, 0), (2, 0), (3, 0), (4, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
                (0, 2), (1, 2), (4, 2), (5, 2),
                (1, 3), (2, 3), (3, 3), (4, 3),
            ]
        case .openclaw:
            // Twin claws.
            return [
                (0, 0), (1, 0), (4, 0), (5, 0),
                (0, 1), (2, 1), (3, 1), (5, 1),
                (1, 2), (2, 2), (3, 2), (4, 2),
                (2, 3), (3, 3),
            ]
        case .opencode:
            // Tall octopus head + tentacles.
            return [
                (2, 0), (3, 0),
                (1, 1), (2, 1), (3, 1), (4, 1),
                (1, 2), (2, 2), (3, 2), (4, 2),
                (0, 3), (2, 3), (3, 3), (5, 3),
            ]
        case .cursor:
            // Crystal / chevron.
            return [
                (2, 0), (3, 0),
                (1, 1), (2, 1), (3, 1), (4, 1),
                (0, 2), (1, 2), (4, 2), (5, 2),
                (0, 3), (5, 3),
            ]
        case .qoder:
            // Q letter.
            return [
                (1, 0), (2, 0), (3, 0), (4, 0),
                (0, 1), (5, 1),
                (0, 2), (2, 2), (3, 2), (5, 2),
                (1, 3), (2, 3), (3, 3), (4, 3), (5, 3),
            ]
        case .codebuddy:
            // Astronaut helmet.
            return [
                (1, 0), (2, 0), (3, 0), (4, 0),
                (0, 1), (1, 1), (4, 1), (5, 1),
                (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2),
                (1, 3), (4, 3),
            ]
        case .copilot:
            // Glasses robot.
            return [
                (0, 0), (1, 0), (4, 0), (5, 0),
                (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
                (1, 2), (2, 2), (3, 2), (4, 2),
                (2, 3), (3, 3),
            ]
        case .kimi:
            // Round keyboard ball.
            return [
                (2, 0), (3, 0),
                (1, 1), (2, 1), (3, 1), (4, 1),
                (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2),
                (1, 3), (2, 3), (3, 3), (4, 3),
            ]
        }
    }
}
