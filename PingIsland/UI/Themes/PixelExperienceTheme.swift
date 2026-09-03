import SwiftUI

/// A single component/sound implementation with two classic visual palettes.
enum PixelExperienceTheme {
    static let allDefinitions = PixelThemePaletteID.allCases.map(definition(for:))

    static func definition(for paletteID: PixelThemePaletteID) -> IslandExperienceTheme {
        let palette = Palette(id: paletteID)
        return IslandExperienceTheme(
            id: .pixel,
            pixelPaletteID: paletteID,
            metadata: ExperienceThemeMetadata(
                displayName: "Pixel",
                description: "像素字形、游戏机图标和 AgentIsland 8-bit 音效。",
                extensionNote: "\(paletteID.displayName)：\(paletteID.description)"
            ),
            visual: ExperienceThemeVisualTokens(
                detachedSurface: palette.background,
                settingsSurface: palette.background,
                settingsSidebarSurface: palette.sidebar,
                settingsDetailSurface: palette.detail,
                settingsCardSurface: palette.card,
                settingsCardBorder: palette.border,
                previewSurface: palette.detail,
                previewSidebarSurface: palette.sidebar,
                primaryText: palette.primaryText,
                secondaryText: palette.secondaryText,
                accent: palette.accent,
                controlCornerRadius: 2,
                settingsCornerRadius: 4,
                sectionCornerRadius: 3,
                controlFontDesign: .monospaced,
                customFontName: "Silkscreen-Bold",
                preferredColorScheme: .dark,
                settingsChromeStyle: .pixel,
                usesPixelGrid: true,
                usesGlassMaterial: false
            ),
            interaction: ExperienceThemeInteractionTokens(
                approve: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.08, green: 0.42, blue: 0.22),
                    border: Color(red: 0.32, green: 0.98, blue: 0.53)
                ),
                scopedApproval: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.10, green: 0.28, blue: 0.64),
                    border: Color(red: 0.34, green: 0.70, blue: 1.00)
                ),
                deny: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.58, green: 0.12, blue: 0.20),
                    border: Color(red: 1.00, green: 0.42, blue: 0.48)
                ),
                neutral: .init(
                    foreground: palette.primaryText,
                    background: palette.neutralControl,
                    border: palette.border
                )
            ),
            motion: ExperienceThemeMotionTokens(
                controlPressScale: 0.97,
                controlPressDuration: 0.10,
                panelResponse: 0.24,
                panelDampingFraction: 0.90
            ),
            sound: soundProfile
        )
    }

    /// Exact game-style mappings carried forward from AgentIsland.
    private static let soundProfile = ExperienceThemeSoundProfile(
        recommendedMode: .island8Bit,
        lifecycleCues: [
            .processingStarted: cue(.tink, .menuSelect, .processingStarted),
            .attentionRequired: cue(.glass, .approvalAlert, .attentionRequired),
            .taskCompleted: cue(.blow, .completeDing, .taskCompleted),
            .taskError: cue(.basso, .errorBuzz, .taskError),
            .resourceLimit: cue(.morse, .hurt, .resourceLimit)
        ],
        auxiliaryCues: [
            .clientStarted: cue(.hero, .bootJingle, .processingStarted),
            .islandDetached: cue(.pop, .bubblePop, .processingStarted),
            .sessionStarted: cue(.hero, .bootJingle, .processingStarted),
            .approvalAccepted: cue(.ping, .itemPickup, .attentionRequired),
            .approvalScoped: cue(.glass, .menuSelect, .attentionRequired),
            .approvalRejected: cue(.basso, .errorBuzz, .taskError),
            .idleReminder: cue(.purr, .menuHighlight, .attentionRequired),
            .usageWarning: cue(.submarine, .approvalAlert, .resourceLimit),
            .usageReset: cue(.glass, .powerUp, .taskCompleted),
            .rapidSubmit: cue(.pop, .itemPickup, .processingStarted)
        ]
    )

    private static func cue(
        _ systemSound: NotificationSound,
        _ islandSound: Island8BitSound,
        _ fallback: NotificationEvent
    ) -> ExperienceThemeSoundCue {
        ExperienceThemeSoundCue(
            systemSound: systemSound,
            island8BitSound: islandSound,
            soundPackFallback: fallback
        )
    }

    private struct Palette {
        let background: Color
        let sidebar: Color
        let detail: Color
        let card: Color
        let border: Color
        let primaryText: Color
        let secondaryText: Color
        let accent: Color
        let neutralControl: Color
        let actionForeground: Color

        init(id: PixelThemePaletteID) {
            switch id {
            case .arcadeNeon:
                background = Color(red: 0.059, green: 0.090, blue: 0.165)
                sidebar = Color(red: 0.098, green: 0.129, blue: 0.204)
                detail = Color(red: 0.073, green: 0.106, blue: 0.180)
                card = Color(red: 0.098, green: 0.129, blue: 0.204)
                border = Color(red: 0.145, green: 0.824, blue: 0.871).opacity(0.58)
                primaryText = Color(red: 0.925, green: 0.973, blue: 1.00)
                secondaryText = Color(red: 0.580, green: 0.773, blue: 0.843)
                accent = Color(red: 0.145, green: 0.824, blue: 0.871)
                neutralControl = Color(red: 0.115, green: 0.157, blue: 0.235)
                actionForeground = .white
            case .gameBoyOlive:
                background = Color(red: 0.059, green: 0.220, blue: 0.059)
                sidebar = Color(red: 0.129, green: 0.310, blue: 0.129)
                detail = Color(red: 0.086, green: 0.227, blue: 0.094)
                card = Color(red: 0.165, green: 0.341, blue: 0.157)
                border = Color(red: 0.608, green: 0.737, blue: 0.059).opacity(0.72)
                primaryText = Color(red: 0.878, green: 0.973, blue: 0.812)
                secondaryText = Color(red: 0.722, green: 0.831, blue: 0.643)
                accent = Color(red: 0.608, green: 0.737, blue: 0.059)
                neutralControl = Color(red: 0.137, green: 0.302, blue: 0.125)
                actionForeground = .white
            }
        }
    }
}
