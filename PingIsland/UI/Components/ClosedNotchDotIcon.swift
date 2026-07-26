import SwiftUI

/// Docked closed-notch icon: miniaturized settings pet + pixel status bar.
/// Pet uses the live status (so working is not shown as sleeping); the bar mirrors the same status.
struct ClosedNotchDotIcon: View {
    let kind: MascotKind
    let status: MascotStatus
    var size: CGFloat = 16

    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private var tone: ClosedNotchDotTone {
        ClosedNotchDotTone.from(status: status)
    }

    private var motion: ClosedNotchDotStatusMotion {
        ClosedNotchDotStatusMotion.from(status: status)
    }

    private let interItemSpacing: CGFloat = 2

    /// Leave room for a 2-column status strip + gap; do not overlap the pet.
    private var petSize: CGFloat {
        max(8, size * 0.58)
    }

    private var statusWidth: CGFloat {
        max(4, size - petSize - interItemSpacing)
    }

    var body: some View {
        HStack(spacing: interItemSpacing) {
            MascotView(kind: kind, status: status, size: petSize)
                .frame(width: petSize, height: petSize)
                .clipped()

            Group {
                if shouldAnimate {
                    TimelineView(.periodic(from: .now, by: animationInterval)) { context in
                        statusCanvas(at: context.date)
                    }
                } else {
                    statusCanvas(at: nil)
                }
            }
            .frame(width: statusWidth, height: size)
            .clipped()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(kind.title), \(status.displayName)"))
    }

    private var shouldAnimate: Bool {
        guard energyGovernor.policy.animationLevel != .staticFrames else { return false }
        switch motion {
        case .spin, .blink:
            return true
        case .staticBar:
            return false
        }
    }

    private var animationInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            return 1.0 / 12.0
        case .reduced:
            return 1.0 / 5.0
        case .staticFrames:
            return 1.0 / 12.0
        }
    }

    private func statusCanvas(at date: Date?) -> some View {
        let color = tone.color
        let columns = ClosedNotchDotGlyph.canvasColumns
        let rows = ClosedNotchDotGlyph.canvasRows
        let gapFraction: CGFloat = 0.18
        let spinAngle = spinAngleRadians(at: date)
        let blink = blinkOpacity(at: date)

        return Canvas { context, canvasSize in
            let cell = min(canvasSize.width / CGFloat(columns), canvasSize.height / CGFloat(rows))
            let drawnWidth = cell * CGFloat(columns)
            let drawnHeight = cell * CGFloat(rows)
            let originX = (canvasSize.width - drawnWidth) / 2
            let originY = (canvasSize.height - drawnHeight) / 2
            let dot = max(1, cell * (1 - gapFraction))
            let inset = (cell - dot) / 2

            func fillGrid(_ point: ClosedNotchDotPoint, opacity: Double) {
                let rect = CGRect(
                    x: originX + CGFloat(point.x) * cell + inset,
                    y: originY + CGFloat(point.y) * cell + inset,
                    width: dot,
                    height: dot
                )
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }

            func fillLogical(x: CGFloat, y: CGFloat, opacity: Double) {
                let rect = CGRect(
                    x: originX + x * cell + inset,
                    y: originY + y * cell + inset,
                    width: dot,
                    height: dot
                )
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }

            switch motion {
            case .staticBar:
                for point in ClosedNotchDotGlyph.statusBarPoints {
                    fillGrid(point, opacity: 0.55)
                }
            case .spin:
                for center in ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: spinAngle) {
                    fillLogical(x: center.x, y: center.y, opacity: 1.0)
                }
            case .blink:
                for point in ClosedNotchDotGlyph.statusBarPoints {
                    fillGrid(point, opacity: blink)
                }
            }
        }
        .frame(width: statusWidth, height: size)
    }

    private func spinAngleRadians(at date: Date?) -> Double {
        guard let date else { return 0 }
        let period: TimeInterval = energyGovernor.policy.animationLevel == .reduced ? 1.6 : 1.0
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return progress * 2 * .pi
    }

    private func blinkOpacity(at date: Date?) -> Double {
        guard let date else { return 0.95 }
        let period: TimeInterval = energyGovernor.policy.animationLevel == .reduced ? 1.6 : 0.9
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.45 + 0.55 * (0.5 + 0.5 * sin(progress * 2 * .pi))
    }
}
