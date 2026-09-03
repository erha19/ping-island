import Foundation
import SwiftUI

/// A compiled-in experience profile. Views receive this value through the
/// environment and must use its semantic tokens instead of screen-local colors.
struct IslandExperienceTheme {
    let id: ExperienceThemeID
    let pixelPaletteID: PixelThemePaletteID?
    let metadata: ExperienceThemeMetadata
    let visual: ExperienceThemeVisualTokens
    let interaction: ExperienceThemeInteractionTokens
    let motion: ExperienceThemeMotionTokens
    let sound: ExperienceThemeSoundProfile
}

/// Controls the themed content inside the shared native Settings window shell.
/// Window buttons, dragging, resizing and full-screen behavior stay in AppKit.
enum ExperienceThemeSettingsChromeStyle: Equatable {
    case pingIsland
    case macOS
    case pixel
}

struct ExperienceThemeMetadata {
    let displayName: String
    let description: String
    let extensionNote: String
}

struct ExperienceThemeVisualTokens {
    let detachedSurface: Color
    let settingsSurface: Color
    let settingsSidebarSurface: Color
    let settingsDetailSurface: Color
    let settingsCardSurface: Color
    let settingsCardBorder: Color
    let previewSurface: Color
    let previewSidebarSurface: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let controlCornerRadius: CGFloat
    let settingsCornerRadius: CGFloat
    let sectionCornerRadius: CGFloat
    let controlFontDesign: Font.Design
    let customFontName: String?
    let preferredColorScheme: ColorScheme?
    let settingsChromeStyle: ExperienceThemeSettingsChromeStyle
    let usesPixelGrid: Bool
    let usesGlassMaterial: Bool

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let customFontName {
            return .custom(customFontName, size: size)
        }
        return .system(size: size, weight: weight, design: controlFontDesign)
    }
}

struct ExperienceThemeMotionTokens {
    let controlPressScale: CGFloat
    let controlPressDuration: TimeInterval
    let panelResponse: TimeInterval
    let panelDampingFraction: CGFloat
}

struct ConfirmationActionAppearance {
    let foreground: Color
    let background: Color
    let border: Color
}

struct ExperienceThemeInteractionTokens {
    let approve: ConfirmationActionAppearance
    let scopedApproval: ConfirmationActionAppearance
    let deny: ConfirmationActionAppearance
    let neutral: ConfirmationActionAppearance

    func appearance(for role: ConfirmationActionRole) -> ConfirmationActionAppearance {
        switch role {
        case .approve:
            approve
        case .scopedApproval:
            scopedApproval
        case .deny:
            deny
        case .neutral:
            neutral
        }
    }
}

struct ExperienceThemeSoundCue: Equatable {
    let systemSound: NotificationSound
    let island8BitSound: Island8BitSound
    let soundPackFallback: NotificationEvent
}

struct ExperienceThemeSoundProfile {
    let recommendedMode: SoundThemeMode
    let lifecycleCues: [NotificationEvent: ExperienceThemeSoundCue]
    let auxiliaryCues: [AppSoundFeedbackEvent: ExperienceThemeSoundCue]

    func cue(for event: AppSoundFeedbackEvent) -> ExperienceThemeSoundCue? {
        if let notificationEvent = event.notificationEvent {
            return lifecycleCues[notificationEvent]
        }
        return auxiliaryCues[event]
    }

    func cue(for event: NotificationEvent) -> ExperienceThemeSoundCue? {
        lifecycleCues[event]
    }
}

private struct IslandExperienceThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ExperienceThemeRegistry.theme(
        for: .appDefault,
        pixelPalette: .arcadeNeon
    )
}

extension EnvironmentValues {
    var islandExperienceTheme: IslandExperienceTheme {
        get { self[IslandExperienceThemeEnvironmentKey.self] }
        set { self[IslandExperienceThemeEnvironmentKey.self] = newValue }
    }
}

/// Decorative texture for Pixel surfaces. Place it inside a surface background
/// (or before content in a ZStack), never as a root overlay above controls.
struct ExperienceThemeGridTexture: View {
    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        if theme.visual.usesPixelGrid {
            Canvas { context, size in
                let step: CGFloat = 6
                let lineColor = theme.visual.primaryText.opacity(0.065)

                for x in stride(from: 0, through: size.width, by: step) {
                    context.stroke(
                        Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)),
                        with: .color(lineColor)
                    )
                }

                for y in stride(from: 0, through: size.height, by: step) {
                    context.stroke(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                        with: .color(lineColor)
                    )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
