//
//  NotchHeaderView.swift
//  ClaudeIsland
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

enum NotchIndicatorTone: Equatable {
    case normal
    case claude
    case codex
    case qoder
    case warning
    case intervention

    var emphasisColor: Color {
        switch self {
        case .normal:
            return TerminalColors.green
        case .claude:
            return Color(red: 0.98, green: 0.73, blue: 0.30)
        case .codex:
            return TerminalColors.blue
        case .qoder:
            return Color(red: 0.12, green: 0.88, blue: 0.56)
        case .warning:
            return Color(red: 1.0, green: 0.66, blue: 0.18)
        case .intervention:
            return TerminalColors.prompt
        }
    }

    var petPalette: NotchPetPalette {
        switch self {
        case .normal:
            return NotchPetPalette(
                primary: Color(red: 0.34, green: 0.93, blue: 0.61),
                secondary: Color(red: 0.29, green: 0.87, blue: 0.57),
                accent: Color(red: 0.23, green: 0.74, blue: 0.48),
                shade: Color(red: 0.17, green: 0.55, blue: 0.35),
                detail: Color(red: 0.11, green: 0.38, blue: 0.24),
                highlight: Color(red: 0.78, green: 1.00, blue: 0.88),
                feature: Color(red: 0.58, green: 0.97, blue: 0.74),
                glow: Color(red: 0.31, green: 0.95, blue: 0.63),
                outerGlow: Color(red: 0.21, green: 0.83, blue: 0.50)
            )
        case .claude:
            return NotchPetPalette(
                primary: Color(red: 0.98, green: 0.76, blue: 0.34),
                secondary: Color(red: 0.96, green: 0.67, blue: 0.28),
                accent: Color(red: 0.89, green: 0.54, blue: 0.22),
                shade: Color(red: 0.70, green: 0.37, blue: 0.14),
                detail: Color(red: 0.49, green: 0.23, blue: 0.09),
                highlight: Color(red: 1.00, green: 0.91, blue: 0.68),
                feature: Color(red: 1.00, green: 0.82, blue: 0.47),
                glow: Color(red: 0.99, green: 0.73, blue: 0.30),
                outerGlow: Color(red: 0.94, green: 0.56, blue: 0.18)
            )
        case .codex:
            return NotchPetPalette(
                primary: Color(red: 0.42, green: 0.78, blue: 1.00),
                secondary: Color(red: 0.34, green: 0.68, blue: 0.99),
                accent: Color(red: 0.24, green: 0.56, blue: 0.96),
                shade: Color(red: 0.16, green: 0.40, blue: 0.79),
                detail: Color(red: 0.09, green: 0.24, blue: 0.53),
                highlight: Color(red: 0.82, green: 0.94, blue: 1.00),
                feature: Color(red: 0.58, green: 0.86, blue: 1.00),
                glow: Color(red: 0.33, green: 0.67, blue: 1.00),
                outerGlow: Color(red: 0.18, green: 0.49, blue: 0.90)
            )
        case .qoder:
            return NotchPetPalette(
                primary: Color(red: 0.22, green: 0.95, blue: 0.63),
                secondary: Color(red: 0.17, green: 0.86, blue: 0.56),
                accent: Color(red: 0.12, green: 0.73, blue: 0.47),
                shade: Color(red: 0.08, green: 0.54, blue: 0.34),
                detail: Color(red: 0.06, green: 0.35, blue: 0.22),
                highlight: Color(red: 0.79, green: 1.00, blue: 0.88),
                feature: Color(red: 0.48, green: 0.99, blue: 0.73),
                glow: Color(red: 0.12, green: 0.88, blue: 0.56),
                outerGlow: Color(red: 0.06, green: 0.69, blue: 0.43)
            )
        case .warning:
            return NotchPetPalette(
                primary: Color(red: 0.97, green: 0.69, blue: 0.30),
                secondary: Color(red: 0.93, green: 0.60, blue: 0.25),
                accent: Color(red: 0.84, green: 0.48, blue: 0.20),
                shade: Color(red: 0.67, green: 0.34, blue: 0.14),
                detail: Color(red: 0.47, green: 0.23, blue: 0.10),
                highlight: Color(red: 1.00, green: 0.90, blue: 0.70),
                feature: Color(red: 1.00, green: 0.80, blue: 0.52),
                glow: Color(red: 0.98, green: 0.70, blue: 0.28),
                outerGlow: Color(red: 0.95, green: 0.57, blue: 0.18)
            )
        case .intervention:
            return NotchPetPalette(
                primary: Color(red: 0.95, green: 0.58, blue: 0.42),
                secondary: Color(red: 0.90, green: 0.50, blue: 0.36),
                accent: Color(red: 0.80, green: 0.38, blue: 0.27),
                shade: Color(red: 0.62, green: 0.26, blue: 0.16),
                detail: Color(red: 0.42, green: 0.17, blue: 0.11),
                highlight: Color(red: 1.00, green: 0.84, blue: 0.74),
                feature: Color(red: 0.98, green: 0.69, blue: 0.56),
                glow: TerminalColors.prompt,
                outerGlow: Color(red: 0.92, green: 0.49, blue: 0.32)
            )
        }
    }
}

struct NotchPetPalette {
    let primary: Color
    let secondary: Color
    let accent: Color
    let shade: Color
    let detail: Color
    let highlight: Color
    let feature: Color
    let glow: Color
    let outerGlow: Color
}

struct NotchPetIcon: View {
    let style: NotchPetStyle
    let size: CGFloat
    let tone: NotchIndicatorTone
    var isProcessing: Bool = false

    @State private var phase: Int = 0

    private let animationTimer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    init(style: NotchPetStyle, size: CGFloat = 16, tone: NotchIndicatorTone = .normal, isProcessing: Bool = false) {
        self.style = style
        self.size = size
        self.tone = tone
        self.isProcessing = isProcessing
    }

    var body: some View {
        let palette = tone.petPalette
        let frames = style.frames(isProcessing: isProcessing, tone: tone)

        Canvas { context, canvasSize in
            guard !frames.isEmpty else { return }

            let frame = frames[phase % frames.count]
            let logicalSize = style.logicalSize
            let scale = min(canvasSize.width / CGFloat(logicalSize.width), canvasSize.height / CGFloat(logicalSize.height))
            let pixelSize = max(1, floor(scale))
            let contentWidth = CGFloat(logicalSize.width) * pixelSize
            let contentHeight = CGFloat(logicalSize.height) * pixelSize
            let xOffset = (canvasSize.width - contentWidth) / 2
            let yOffset = (canvasSize.height - contentHeight) / 2

            for (rowIndex, row) in frame.enumerated() {
                for (columnIndex, symbol) in row.enumerated() {
                    guard let color = style.color(for: symbol, palette: palette) else { continue }
                    let rect = CGRect(
                        x: xOffset + CGFloat(columnIndex) * pixelSize,
                        y: yOffset + CGFloat(rowIndex) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    let glowRect = rect.insetBy(dx: -pixelSize * 0.42, dy: -pixelSize * 0.42)
                    context.fill(
                        Path(roundedRect: glowRect, cornerRadius: pixelSize * 0.28),
                        with: .color(style.glowColor(for: symbol, palette: palette))
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size * style.aspectRatio, height: size)
        .shadow(color: palette.outerGlow.opacity(0.72), radius: 6, y: 0)
        .onReceive(animationTimer) { _ in
            phase = (phase + 1) % max(1, frames.count)
        }
        .onChange(of: isProcessing) { _, _ in
            phase = 0
        }
        .onChange(of: tone) { _, _ in
            phase = 0
        }
    }
}

private extension NotchPetStyle {
    var logicalSize: (width: Int, height: Int) {
        switch self {
        case .crab:
            return (11, 8)
        case .slime:
            return (8, 8)
        case .cat:
            return (10, 8)
        case .sittingCat:
            return (10, 8)
        case .owl:
            return (8, 8)
        case .snowyOwl:
            return (10, 8)
        case .bee:
            return (11, 8)
        case .roundBlob:
            return (8, 8)
        case .antennaBean:
            return (8, 8)
        case .tinyDino:
            return (10, 8)
        }
    }

    var aspectRatio: CGFloat {
        CGFloat(logicalSize.width) / CGFloat(logicalSize.height)
    }

    func color(for symbol: Character, palette: NotchPetPalette) -> Color? {
        switch symbol {
        case "P":
            return palette.primary
        case "M":
            return palette.secondary
        case "S":
            return palette.accent
        case "E":
            return palette.shade
        case "D":
            return palette.detail
        case "H":
            return palette.highlight
        case "C":
            return palette.feature
        default:
            return nil
        }
    }

    func glowColor(for symbol: Character, palette: NotchPetPalette) -> Color {
        switch symbol {
        case "H":
            return palette.highlight.opacity(0.22)
        case "C":
            return palette.feature.opacity(0.16)
        case "D":
            return palette.detail.opacity(0.08)
        case "E":
            return palette.shade.opacity(0.10)
        case "M":
            return palette.secondary.opacity(0.14)
        default:
            return palette.glow.opacity(0.18)
        }
    }

    func frames(isProcessing: Bool, tone: NotchIndicatorTone) -> [[String]] {
        if isProcessing {
            return activeFrames
        }

        switch tone {
        case .normal:
            return idleFrames
        case .claude:
            return idleFrames
        case .codex:
            return idleFrames
        case .qoder:
            return idleFrames
        case .warning:
            return warningFrames
        case .intervention:
            return interventionFrames
        }
    }

    private var idleFrames: [[String]] {
        switch self {
        case .crab:
            return crabIdleFrames
        case .slime:
            return slimeIdleFrames
        case .cat:
            return catIdleFrames
        case .sittingCat:
            return sittingCatIdleFrames
        case .owl:
            return owlIdleFrames
        case .snowyOwl:
            return snowyOwlIdleFrames
        case .bee:
            return beeIdleFrames
        case .roundBlob:
            return roundBlobIdleFrames
        case .antennaBean:
            return antennaBeanIdleFrames
        case .tinyDino:
            return tinyDinoIdleFrames
        }
    }

    private var activeFrames: [[String]] {
        switch self {
        case .crab:
            return crabActiveFrames
        case .slime:
            return slimeActiveFrames
        case .cat:
            return catActiveFrames
        case .sittingCat:
            return sittingCatActiveFrames
        case .owl:
            return owlActiveFrames
        case .snowyOwl:
            return snowyOwlActiveFrames
        case .bee:
            return beeActiveFrames
        case .roundBlob:
            return roundBlobActiveFrames
        case .antennaBean:
            return antennaBeanActiveFrames
        case .tinyDino:
            return tinyDinoActiveFrames
        }
    }

    private var warningFrames: [[String]] {
        switch self {
        case .cat:
            return catWarningFrames
        case .sittingCat:
            return sittingCatWarningFrames
        default:
            return activeFrames
        }
    }

    private var interventionFrames: [[String]] {
        switch self {
        case .cat:
            return catInterventionFrames
        case .sittingCat:
            return sittingCatInterventionFrames
        default:
            return activeFrames
        }
    }

    private var crabIdleFrames: [[String]] {
        [
            [
                " H       H ",
                "  MPPPPPM  ",
                " MPPHCHPPM ",
                "MPPSDDDSPPM",
                "PPPPSSSPPPP",
                " MPPPMPPPM ",
                "M  M   M  M",
                "  M     M  "
            ],
            [
                " H       H ",
                "  MPPPPPM  ",
                " MPPHCHPPM ",
                "MPPSDDDSPPM",
                "PPPPSSSPPPP",
                " MPPPMPPPM ",
                " M  M M  M ",
                "M   M M   M"
            ]
        ]
    }

    private var crabActiveFrames: [[String]] {
        [
            [
                " H       H ",
                "  MPPPPPM  ",
                " MPPHCHPPM ",
                "MPPSDDDSPPM",
                "PPPPSSSPPPP",
                " MPPPMPPPM ",
                "M  M   M  M",
                "  M     M  "
            ],
            [
                " H       H ",
                "  MPPPPPM  ",
                " MPPHCHPPM ",
                "MPPSDDDSPPM",
                "PPPPSSSPPPP",
                " MPPPMPPPM ",
                " M  M M  M ",
                "M   M M   M"
            ],
            [
                " H       H ",
                "  MPPPPPM  ",
                " MPPHCHPPM ",
                "MPPSDDDSPPM",
                "PPPPSSSPPPP",
                " MPPPMPPPM ",
                "  M M M M  ",
                " M  M M  M "
            ]
        ]
    }

    private var slimeIdleFrames: [[String]] {
        [
            [
                "  HHH   ",
                " HMPMH  ",
                "HMPPPMH ",
                "MPPCCPPM",
                "PPSEESPP",
                " MPPPPM ",
                "  MPPM  ",
                "        "
            ],
            [
                "  HHH   ",
                " HMPMH  ",
                "HMPPPMH ",
                "MPPCCPPM",
                "PPSEESPP",
                " MPPPPM ",
                " MPPPPM ",
                "        "
            ],
            [
                "  HHH   ",
                " HMPMH  ",
                "HMPPPMH ",
                "MPP  PPM",
                "PPSCCSPP",
                " MPPPPM ",
                "  MPPM  ",
                "        "
            ]
        ]
    }

    private var slimeActiveFrames: [[String]] {
        [
            [
                "  HHH   ",
                " HMPMH  ",
                "HMPPPMH ",
                "MPPCCPPM",
                "PPSEESPP",
                " MPPPPM ",
                "  MPPM  ",
                "        "
            ],
            [
                "   HH   ",
                " HMPPMH ",
                "MPPPPPPM",
                "PPCCSCPP",
                "PPSEESPP",
                "PPPPPPPP",
                " MPPPPM ",
                "        "
            ],
            [
                "  HHH   ",
                "  HMMH  ",
                " HPPPPS ",
                "MPPCCPPM",
                "PPSEESPP",
                " MPPPPM ",
                "  MPPM  ",
                "   MM   "
            ]
        ]
    }

    private var catIdleFrames: [[String]] {
        [
            [
                " S    H  P",
                "SS MPPM PP",
                "S MPPPPM P",
                " MPPHHPPM ",
                "PPSECDECPP",
                " MPPCCPPM ",
                "  MP  MPP ",
                " P      P "
            ],
            [
                "  S   H  P",
                " S MPPM PP",
                "S MPPPPM P",
                " MPPHHPPM ",
                "PPSECDECPP",
                " MPPCCPPM ",
                "  MPP M P ",
                " P     P  "
            ],
            [
                "   S  H  P",
                "  SMPPM PP",
                " SMPPPPM P",
                " MPPHHPPM ",
                "PP CDDC PP",
                " MPPCCPPM ",
                "  MP  MPP ",
                " P      P "
            ]
        ]
    }

    private var catActiveFrames: [[String]] {
        [
            [
                " S    H  P",
                "SS MPPM PP",
                "S MPPPPM P",
                " MPPHHPPM ",
                "PPSECDECPP",
                " MPPCCPPM ",
                "  MP M MPP",
                " P  M   P "
            ],
            [
                "  S   H  P",
                " S MPPM PP",
                "SMPPPPPM P",
                " MPPHHPPM ",
                "PPSECDECPP",
                " MPPCCPPM ",
                "  MPP MPP ",
                " P      P "
            ],
            [
                "   S  H  P",
                "  SMPPM PP",
                " SMPPPPM P",
                " MPPHHPPM ",
                "PPSECDECPP",
                " MPPCCPPM ",
                "  MP  MMPP",
                " P   M  P "
            ]
        ]
    }

    private var catWarningFrames: [[String]] {
        [
            [
                " S    H  P",
                "SS MPPM PP",
                "S MPPPPM P",
                " MPPHHPPM ",
                "PPHCDDCHPP",
                " MPPCCPPM ",
                "  MPP MPP ",
                " P   M  P "
            ],
            [
                "  S   H  P",
                " S MPPM PP",
                "SMPPPPPM P",
                " MPPHHPPM ",
                "PPHCDDCHPP",
                " MPPCCPPM ",
                "  MP  MMPP",
                " P  M   P "
            ]
        ]
    }

    private var catInterventionFrames: [[String]] {
        [
            [
                "  S   H  P",
                " S MPPM PP",
                " SMPPPPM P",
                " MPPHCCPM ",
                "PPSEDDECPP",
                " MPPCCPPM ",
                "  MPP  MPP",
                " P  M   P "
            ],
            [
                "   S  H  P",
                "  SMPPM PP",
                " SMPPPPM P",
                " MPPCCHPM ",
                "PPSEDDCEPP",
                " MPPCCPPM ",
                "  MP M MPP",
                " P   M  P "
            ]
        ]
    }

    private var sittingCatIdleFrames: [[String]] {
        [
            [
                " PP  PP   ",
                "PPPMMMPP  ",
                "PPPPPPPP  ",
                "PPHCCHPP  ",
                "PPSEEDSPP ",
                " PPPPPPP  ",
                " PPP  PPP ",
                "PP     PPP"
            ],
            [
                " PP  PP   ",
                "PPPMMMPP  ",
                "PPPPPPPP  ",
                "PPH  HPP  ",
                "PP CDDCPP ",
                " PPPPPPP  ",
                " PPPP PPP ",
                " P     PPP"
            ],
            [
                " PP  PP   ",
                "PPPMMMPP  ",
                "PPPPPPPP  ",
                "PPDCCDPP  ",
                "PPSEEDCPP ",
                " PPPPPPP  ",
                " PPP  PPP ",
                "PP    PPP "
            ]
        ]
    }

    private var sittingCatActiveFrames: [[String]] {
        [
            [
                "PPP  PPP  ",
                "PPPMMMPPP ",
                "PPPPPPPPP ",
                "PPHCCHPPP ",
                "PPSEEDSPPP",
                " PPPPPPPP ",
                " PPP M PPP",
                "PP   M  PP"
            ],
            [
                " PP  PPP  ",
                "PPPMMMPPP ",
                "PPPPPPPPP ",
                "PPHCCDHPP ",
                "PPSEEDSPPP",
                " PPPPPPPP ",
                " PPPP  PPP",
                " P   M  PP"
            ],
            [
                "PPP  PP   ",
                "PPPMMMPPP ",
                "PPPPPPPPP ",
                "PPHCCDHPP ",
                "PPSEEDSPPP",
                " PPPPPPPP ",
                " PPP  MPPP",
                "PP  M   PP"
            ]
        ]
    }

    private var sittingCatWarningFrames: [[String]] {
        [
            [
                "PPP  PPP  ",
                "PPPMMMPPP ",
                "PPPPPPPPP ",
                "PPHHCHHPP ",
                "PPSCDDCSPP",
                " PPPPPPPP ",
                " PPP  MPPP",
                "PP  M   PP"
            ],
            [
                " PP  PPP  ",
                "PPPMMMPPP ",
                "PPPPPPPPP ",
                "PPHCHCHPP ",
                "PPSCDDCSPP",
                " PPPPPPPP ",
                " PPPP  PPP",
                " P   M  PP"
            ]
        ]
    }

    private var sittingCatInterventionFrames: [[String]] {
        [
            [
                "  PP  PPP ",
                " PPPMMMPP ",
                " PPPPPPPP ",
                " PPHCCHPP ",
                "PPSEDDECPP",
                "  PPPPPP  ",
                "  PPP MPP ",
                " PP M   PP"
            ],
            [
                " PPP  PP  ",
                "PPPMMMPP  ",
                "PPPPPPPP  ",
                "PPHCCHPP  ",
                "PPCEDDESPP",
                " PPPPPP   ",
                " PPP  MPP ",
                "PP   M  PP"
            ]
        ]
    }

    private var owlIdleFrames: [[String]] {
        [
            [
                "  MPPM  ",
                " MSPPSM ",
                "MPHCCHPM",
                "MPEDDEPM",
                "MPSSSSPM",
                " MSPPSM ",
                "  MPPM  ",
                " M    M "
            ],
            [
                "  MPPM  ",
                " MSPPSM ",
                "MPHCCHPM",
                "MP    PM",
                "MPSSSSPM",
                " MSPPSM ",
                "  MPPM  ",
                " M    M "
            ]
        ]
    }

    private var owlActiveFrames: [[String]] {
        [
            [
                "  MPPM  ",
                " MSPPSM ",
                "MPHCCHPM",
                "MPEDDEPM",
                "MPSSSSPM",
                " MSPPSM ",
                "  MPPM  ",
                " M    M "
            ],
            [
                "  MPPM  ",
                "MSPPPPSM",
                "MPHCCHPM",
                "MPEDDEPM",
                "MPSSSSPM",
                "  MSPM  ",
                "  M  M  ",
                " M    M "
            ],
            [
                "  MPPM  ",
                " MSPPSM ",
                "MPHCCHPM",
                "MPEDDEPM",
                "MPSSSSPM",
                "MS    SM",
                " M    M ",
                "  M  M  "
            ]
        ]
    }

    private var snowyOwlIdleFrames: [[String]] {
        [
            [
                "  HH  HH  ",
                " MPPPPPPM ",
                "MPHCCHCHPM",
                "MPEDDDDEPM",
                "MPPSSSSPPM",
                " MPPCCPPM ",
                "  MPMMPM  ",
                " M      M "
            ],
            [
                "  HH  HH  ",
                " MPPPPPPM ",
                "MPH  HCHPM",
                "MPPCCCCPPM",
                "MPPSSSSPPM",
                " MPPCCPPM ",
                "  MPPPPM  ",
                "  M    M  "
            ]
        ]
    }

    private var snowyOwlActiveFrames: [[String]] {
        [
            [
                "  HH  HH  ",
                " MPPPPPPM ",
                "MPHCCHCHPM",
                "MPEDDDDEPM",
                "MPPSSSSPPM",
                " MPPCCPPM ",
                "  MPMMPM  ",
                " M      M "
            ],
            [
                " HHH  HHH ",
                "MPPPPPPPPM",
                "MPHCCHCHPM",
                "MPEDDDDEPM",
                "MPPSSSSPPM",
                "MSP    PSM",
                "  MM  MM  ",
                " M  MM  M "
            ],
            [
                "   HHHH   ",
                " MPPPPPPM ",
                "MPH  HCHPM",
                "MPPCCCCPPM",
                "MPPSSSSPPM",
                " MSPPSPM  ",
                "  M MM M  ",
                "  M    M  "
            ]
        ]
    }

    private var roundBlobIdleFrames: [[String]] {
        [
            [
                "  MPPM  ",
                " MPPPPM ",
                "MPHCCHPM",
                "PPSSSSPP",
                "PPEDDEPP",
                " MPPPPM ",
                "  MPPM  ",
                "  M  M  "
            ],
            [
                "  MPPM  ",
                " MPPPPM ",
                "MPH  HPM",
                "PPCCCCPP",
                "PPEDDEPP",
                " MPPPPM ",
                "  MPPM  ",
                "  M  M  "
            ],
            [
                " MPPPPM ",
                "MPPPPPPM",
                "PPHCCHPP",
                "PPSSSSPP",
                "PPEDDEPP",
                "  MPPM  ",
                "  MPPM  ",
                " M    M "
            ]
        ]
    }

    private var beeIdleFrames: [[String]] {
        [
            [
                "   HH      ",
                "  HCCMH    ",
                " MPPPPPM   ",
                "MPHSSSHPMS ",
                "MPPCDDCPMS ",
                " MPPSSPPM  ",
                "  M M  M   ",
                " M   MM    "
            ],
            [
                "    HH     ",
                "  HCMCH    ",
                " MPPPPPM   ",
                "MPHSSSHPMS ",
                "MPPCDDCPMS ",
                " MPPSSPPM  ",
                "   MM M    ",
                " M  M  M   "
            ]
        ]
    }

    private var beeActiveFrames: [[String]] {
        [
            [
                "   HH      ",
                "  HCCMH    ",
                " MPPPPPM   ",
                "MPHSSSHPMS ",
                "MPPCDDCPMS ",
                " MPPSSPPM  ",
                "  M M  M   ",
                " M   MM    "
            ],
            [
                "  HHH      ",
                " HCCCMH    ",
                "MPPPPPPM   ",
                "MPHSSSHPMS ",
                "MPPCDDCPMS ",
                " MPPSSPPMM ",
                "   MM MM   ",
                " M    M    "
            ],
            [
                "    HHH    ",
                "  HCMCCH   ",
                " MPPPPPM   ",
                "MPHSSSHPMS ",
                "MPPCDDCPMS ",
                " MPPSSPPM  ",
                "  MM  MM   ",
                "  M M      "
            ]
        ]
    }

    private var roundBlobActiveFrames: [[String]] {
        [
            [
                "  MPPM  ",
                " MPPPPM ",
                "MPHCCHPM",
                "PPSSSSPP",
                "PPEDDEPP",
                " MPPPPM ",
                "  MPPM  ",
                "  M  M  "
            ],
            [
                " MPPPPM ",
                "MPPPPPPM",
                "PPHCCHPP",
                "PPSSSSPP",
                "PPEDDEPP",
                "  MPPM  ",
                "  MPPM  ",
                " M    M "
            ],
            [
                "  MPPM  ",
                " MPPPPM ",
                "MPH  HPM",
                "PPCCCCPP",
                "PPEDDEPP",
                " MPPPPM ",
                " MPPPPM ",
                "  M  M  "
            ]
        ]
    }

    private var antennaBeanIdleFrames: [[String]] {
        [
            [
                " P    P ",
                "PPM  MPP",
                "PPPPPPPP",
                "PPHCCHPP",
                " PSEESP ",
                "  MPPM  ",
                "  M  M  ",
                " M    M "
            ],
            [
                "  P  P  ",
                " PPMMPP ",
                "PPPPPPPP",
                "PPH  HPP",
                " P CDDP ",
                "  MPPM  ",
                "  MPPM  ",
                "   MM   "
            ],
            [
                " P    P ",
                "PPM  MPP",
                "PPPPPPPP",
                "PPDCCDPP",
                " PSEESP ",
                "  MPPM  ",
                " M  M   ",
                "M    M  "
            ]
        ]
    }

    private var antennaBeanActiveFrames: [[String]] {
        [
            [
                " P    P ",
                "PPM  MPP",
                "PPPPPPPP",
                "PPHCCHPP",
                " PSEESP ",
                "  MPPM  ",
                "  M  M  ",
                " M    M "
            ],
            [
                "P      P",
                "PPM  MPP",
                "PPPPPPPP",
                "PPHCCHPP",
                " PSEESP ",
                "  MPPM  ",
                "  MPPM  ",
                " M MM M "
            ],
            [
                "  P  P  ",
                " PPMMPP ",
                "PPPPPPPP",
                "PPH  HPP",
                " P CDDP ",
                "  MPPM  ",
                " MPPM   ",
                "M    MM "
            ]
        ]
    }

    private var tinyDinoIdleFrames: [[String]] {
        [
            [
                "  MPP     ",
                " MPPPPM   ",
                "MPHCCHPP  ",
                "MPPSSSSPM ",
                " MPPEDSPPM",
                "  MPPPPMMM",
                " M  M  M M",
                " M M     M"
            ],
            [
                "  MPP     ",
                " MPPPPM   ",
                "MPH  HPP  ",
                "MPPCCCCPM ",
                " MPPEDSPPM",
                "  MPPPPMM ",
                " M  MM  MM",
                "  M M   M "
            ]
        ]
    }

    private var tinyDinoActiveFrames: [[String]] {
        [
            [
                "  MPP     ",
                " MPPPPM   ",
                "MPHCCHPP  ",
                "MPPSSSSPM ",
                " MPPEDSPPM",
                "  MPPPPMMM",
                " M  M  M M",
                " M M     M"
            ],
            [
                "   MPP    ",
                " MPPPPM   ",
                "MPHCCHPP  ",
                "MPPSSSSPM ",
                " MPPEDSPPM",
                "  MPPPPMMM",
                "  MM  M MM",
                " M   M   M"
            ],
            [
                "  MPP     ",
                " MPPPPM   ",
                "MPH  HPP  ",
                "MPPCCCCPM ",
                " MPPEDSPPM",
                "  MPPPPMM ",
                " M  MM  MM",
                "  M M   M "
            ]
        ]
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color
    @State private var phase: Int = 0

    private let animationTimer = Timer.publish(every: 0.34, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Bold pixel-art question mark with a small two-frame pulse.
    private let frames: [[(CGFloat, CGFloat)]] = [
        [
            (9, 3), (13, 3), (17, 3), (21, 3),
            (5, 7), (9, 7), (17, 7), (21, 7), (25, 7),
            (21, 11), (17, 15), (13, 19),
            (13, 27), (17, 27)
        ],
        [
            (9, 3), (13, 3), (17, 3), (21, 3),
            (5, 7), (9, 7), (17, 7), (21, 7), (25, 7),
            (21, 11), (17, 15), (17, 19),
            (13, 25), (17, 25)
        ]
    ]

    var body: some View {
        let pixels = frames[phase % frames.count]

        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.45), radius: phase.isMultiple(of: 2) ? 3 : 6)
        .scaleEffect(phase.isMultiple(of: 2) ? 1.0 : 1.08)
        .offset(y: phase.isMultiple(of: 2) ? 0 : -0.5)
        .animation(.easeInOut(duration: 0.22), value: phase)
        .onReceive(animationTimer) { _ in
            phase = (phase + 1) % frames.count
        }
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

struct BellIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.prompt) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: size - 2, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}
