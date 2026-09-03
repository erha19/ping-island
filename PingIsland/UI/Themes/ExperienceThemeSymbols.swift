import CoreText
import SwiftUI

enum ExperienceThemeFontRegistry {
    @MainActor
    static func registerBundledFonts() {
        let candidates = [
            Bundle.main.url(forResource: "Silkscreen-Bold", withExtension: "ttf", subdirectory: "Fonts"),
            Bundle.main.url(forResource: "Silkscreen-Bold", withExtension: "ttf")
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

enum ExperienceThemePixelGlyph {
    case settings
    case shortcuts
    case display
    case mascot
    case sound
    case analytics
    case integration
    case remote
    case labs
    case info

    fileprivate var rows: [String] {
        switch self {
        case .settings:
            return ["0011100", "0111110", "1100011", "1110111", "1100011", "0111110", "0011100"]
        case .shortcuts:
            return ["0100010", "1110111", "0100010", "0011100", "0100010", "1110111", "0100010"]
        case .display:
            return ["1111111", "1000001", "1011101", "1011101", "1000001", "1111111", "0011100"]
        case .mascot:
            return ["0111110", "1101011", "1111111", "1010101", "1111111", "0111110", "0101010"]
        case .sound:
            return ["0001000", "0011001", "0111011", "1111011", "0111011", "0011001", "0001000"]
        case .analytics:
            return ["1000001", "1001001", "1011001", "1011011", "1111011", "1111111", "1111111"]
        case .integration:
            return ["0111000", "1101100", "1000110", "0000011", "0110001", "1101011", "0011100"]
        case .remote:
            return ["0011100", "0100010", "1010101", "1000001", "1010101", "0100010", "0011100"]
        case .labs:
            return ["0011100", "0001000", "0001000", "0011100", "0111110", "1111111", "0111110"]
        case .info:
            return ["0011100", "0100010", "0001000", "0011000", "0001000", "0001000", "0011100"]
        }
    }
}

extension SettingsCategory {
    var pixelGlyph: ExperienceThemePixelGlyph {
        switch self {
        case .general: return .settings
        case .shortcuts: return .shortcuts
        case .display: return .display
        case .mascot: return .mascot
        case .sound: return .sound
        case .analytics: return .analytics
        case .integration: return .integration
        case .remote: return .remote
        case .labs: return .labs
        case .about: return .info
        }
    }
}

struct ExperienceThemeSidebarSymbol: View {
    let category: SettingsCategory
    let color: Color

    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        Group {
            if theme.visual.usesPixelGrid {
                PixelGlyphView(glyph: category.pixelGlyph, color: color)
            } else {
                Image(systemName: category.icon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PixelGlyphView: View {
    let glyph: ExperienceThemePixelGlyph
    let color: Color

    var body: some View {
        Canvas { context, size in
            let rows = glyph.rows
            let columns = rows.first?.count ?? 7
            let pixel = floor(min(size.width / CGFloat(columns), size.height / CGFloat(rows.count)))
            let originX = floor((size.width - CGFloat(columns) * pixel) / 2)
            let originY = floor((size.height - CGFloat(rows.count) * pixel) / 2)

            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, value) in row.enumerated() where value == "1" {
                    context.fill(
                        Path(CGRect(
                            x: originX + CGFloat(columnIndex) * pixel,
                            y: originY + CGFloat(rowIndex) * pixel,
                            width: pixel,
                            height: pixel
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        .drawingGroup(opaque: false)
    }
}
