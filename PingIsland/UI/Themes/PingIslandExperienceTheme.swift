import SwiftUI

/// The product's own visual and audio identity. The persisted ID remains
/// `standard` for backwards compatibility, but this is intentionally not a
/// generic macOS skin.
enum PingIslandExperienceTheme {
    static let definition = IslandExperienceTheme(
        id: .standard,
        pixelPaletteID: nil,
        metadata: ExperienceThemeMetadata(
            displayName: "PingIsland 原生",
            description: "延续 PingIsland 的深色玻璃界面与原有 8-bit 声音语言。",
            extensionNote: "在不改变原有五个阶段音色的前提下，补充会话、提醒和用量反馈。"
        ),
        visual: ExperienceThemeVisualTokens(
            detachedSurface: .black,
            settingsSurface: .clear,
            settingsSidebarSurface: Color.white.opacity(0.055),
            settingsDetailSurface: Color.white.opacity(0.035),
            settingsCardSurface: Color.white.opacity(0.045),
            settingsCardBorder: Color.white.opacity(0.11),
            previewSurface: Color.primary.opacity(0.055),
            previewSidebarSurface: Color.primary.opacity(0.10),
            primaryText: .white,
            secondaryText: Color.white.opacity(0.72),
            accent: .accentColor,
            controlCornerRadius: 18,
            settingsCornerRadius: 24,
            sectionCornerRadius: 18,
            controlFontDesign: .rounded,
            customFontName: nil,
            preferredColorScheme: .dark,
            settingsChromeStyle: .pingIsland,
            usesPixelGrid: false,
            usesGlassMaterial: true
        ),
        interaction: ExperienceThemeInteractionTokens(
            approve: .init(
                foreground: .white,
                background: Color(red: 0.12, green: 0.52, blue: 0.30),
                border: Color(red: 0.39, green: 0.86, blue: 0.56)
            ),
            scopedApproval: .init(
                foreground: .white,
                background: Color(red: 0.13, green: 0.36, blue: 0.74),
                border: Color(red: 0.43, green: 0.67, blue: 1.00)
            ),
            deny: .init(
                foreground: .white,
                background: Color(red: 0.67, green: 0.20, blue: 0.24),
                border: Color(red: 1.00, green: 0.49, blue: 0.51)
            ),
            neutral: .init(
                foreground: .white,
                background: Color.white.opacity(0.12),
                border: Color.white.opacity(0.24)
            )
        ),
        motion: ExperienceThemeMotionTokens(
            controlPressScale: 0.98,
            controlPressDuration: 0.12,
            panelResponse: 0.42,
            panelDampingFraction: 0.8
        ),
        sound: ExperienceThemeSoundProfile(
            recommendedMode: .island8Bit,
            lifecycleCues: [
                .processingStarted: cue(.tink, .menuSelect, .processingStarted),
                .attentionRequired: cue(.glass, .approvalAlert, .attentionRequired),
                .taskCompleted: cue(.blow, .submitBlip, .taskCompleted),
                .taskError: cue(.basso, .hurt, .taskError),
                .resourceLimit: cue(.morse, .completeDing, .resourceLimit)
            ],
            auxiliaryCues: [
                .clientStarted: cue(.hero, .powerUp, .processingStarted),
                .islandDetached: cue(.pop, .bubblePop, .processingStarted),
                .sessionStarted: cue(.hero, .startChime, .processingStarted),
                .approvalAccepted: cue(.ping, .itemPickup, .attentionRequired),
                .approvalScoped: cue(.glass, .menuSelect, .attentionRequired),
                .approvalRejected: cue(.basso, .hurt, .taskError),
                .idleReminder: cue(.purr, .menuHighlight, .attentionRequired),
                .usageWarning: cue(.submarine, .approvalAlert, .resourceLimit),
                .usageReset: cue(.glass, .completeDing, .taskCompleted),
                .rapidSubmit: cue(.pop, .submitBlip, .processingStarted)
            ]
        )
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
}
