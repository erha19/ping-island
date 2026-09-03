import AppKit
import SwiftUI

/// A system-native interpretation: dynamic semantic colors, SF Symbols,
/// macOS spacing and the platform sound set.
enum MacOSExperienceTheme {
    static let definition = IslandExperienceTheme(
        id: .macOS,
        pixelPaletteID: nil,
        metadata: ExperienceThemeMetadata(
            displayName: "macOS",
            description: "系统材质、原生侧栏和 SF Symbols 组成的 macOS 风格。",
            extensionNote: "界面使用系统材质与层级，反馈使用 macOS 系统音。"
        ),
        visual: ExperienceThemeVisualTokens(
            detachedSurface: Color(nsColor: .windowBackgroundColor),
            settingsSurface: Color(nsColor: .windowBackgroundColor),
            settingsSidebarSurface: Color(nsColor: .underPageBackgroundColor),
            settingsDetailSurface: Color(nsColor: .windowBackgroundColor),
            settingsCardSurface: Color(nsColor: .controlBackgroundColor),
            settingsCardBorder: Color(nsColor: .separatorColor),
            previewSurface: Color(nsColor: .controlBackgroundColor),
            previewSidebarSurface: Color(nsColor: .underPageBackgroundColor),
            primaryText: Color(nsColor: .labelColor),
            secondaryText: Color(nsColor: .secondaryLabelColor),
            accent: .accentColor,
            controlCornerRadius: 8,
            settingsCornerRadius: 12,
            sectionCornerRadius: 10,
            controlFontDesign: .default,
            customFontName: nil,
            preferredColorScheme: .dark,
            settingsChromeStyle: .macOS,
            usesPixelGrid: false,
            usesGlassMaterial: true
        ),
        interaction: ExperienceThemeInteractionTokens(
            approve: .init(
                foreground: .white,
                background: Color(nsColor: .systemGreen),
                border: Color(nsColor: .systemGreen).opacity(0.72)
            ),
            scopedApproval: .init(
                foreground: .white,
                background: Color(nsColor: .systemBlue),
                border: Color(nsColor: .systemBlue).opacity(0.72)
            ),
            deny: .init(
                foreground: .white,
                background: Color(nsColor: .systemRed),
                border: Color(nsColor: .systemRed).opacity(0.72)
            ),
            neutral: .init(
                foreground: Color(nsColor: .labelColor),
                background: Color(nsColor: .controlColor),
                border: Color(nsColor: .separatorColor)
            )
        ),
        motion: ExperienceThemeMotionTokens(
            controlPressScale: 0.99,
            controlPressDuration: 0.12,
            panelResponse: 0.30,
            panelDampingFraction: 0.86
        ),
        sound: ExperienceThemeSoundProfile(
            recommendedMode: .builtIn,
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
                .usageReset: cue(.glass, .powerUp, .taskCompleted),
                .rapidSubmit: cue(.pop, .itemPickup, .processingStarted)
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
