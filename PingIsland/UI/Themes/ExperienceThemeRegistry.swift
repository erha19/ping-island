import Foundation

/// The single registration point for compiled-in themes. Adding a theme is a
/// deliberate product change: add its stable ID, create its own definition
/// file, and register that definition here.
enum ExperienceThemeRegistry {
    static let all: [IslandExperienceTheme] = [
        PingIslandExperienceTheme.definition,
        MacOSExperienceTheme.definition,
        PixelExperienceTheme.definition(for: .arcadeNeon)
    ]

    static func theme(
        for id: ExperienceThemeID,
        pixelPalette: PixelThemePaletteID = .arcadeNeon
    ) -> IslandExperienceTheme {
        switch id {
        case .standard:
            return PingIslandExperienceTheme.definition
        case .macOS:
            return MacOSExperienceTheme.definition
        case .pixel:
            return PixelExperienceTheme.definition(for: pixelPalette)
        }
    }
}
