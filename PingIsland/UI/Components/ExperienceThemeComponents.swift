import SwiftUI

/// Shared control for decisions that resolve a pending operation. Its visual
/// meaning comes from the current experience theme, not from each call site.
struct ConfirmationActionButton: View {
    let title: String
    let role: ConfirmationActionRole
    var compact = false
    let action: () -> Void

    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        Button {
            if let soundFeedbackEvent = role.soundFeedbackEvent {
                AppSoundFeedback.play(soundFeedbackEvent)
            }
            action()
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                ConfirmationActionSymbol(role: role, compact: compact)

                Text(title)
                    .font(theme.visual.font(size: compact ? 10 : 12, weight: .semibold))
            }
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(minHeight: compact ? 26 : 36)
        }
        .buttonStyle(
            ConfirmationActionButtonStyle(
                appearance: theme.interaction.appearance(for: role),
                cornerRadius: compact
                    ? min(13, theme.visual.controlCornerRadius)
                    : theme.visual.controlCornerRadius,
                motion: theme.motion
            )
        )
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        switch role {
        case .approve:
            return "允许这一次操作"
        case .scopedApproval:
            return "在当前会话中持续允许这类操作"
        case .deny:
            return "拒绝这次操作"
        case .neutral:
            return "在原应用中继续处理"
        }
    }
}

struct ExperienceThemeOptionCard: View {
    let themeID: ExperienceThemeID
    var pixelPaletteID: PixelThemePaletteID = .arcadeNeon
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.islandExperienceTheme) private var activeTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var previewTheme: IslandExperienceTheme {
        ExperienceThemeRegistry.theme(for: themeID, pixelPalette: pixelPaletteID)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(appLocalized: previewTheme.metadata.displayName)
                        .font(previewTheme.visual.font(size: 14, weight: .semibold))
                        .foregroundStyle(activeTheme.visual.primaryText)

                    Spacer(minLength: 0)

                    selectionIndicator
                }

                ExperienceThemePreview(theme: previewTheme)
                    .environment(\.islandExperienceTheme, previewTheme)

                Text(appLocalized: previewTheme.metadata.description)
                    .font(activeTheme.visual.font(size: 11, weight: .medium))
                    .foregroundStyle(activeTheme.visual.secondaryText)
                    .lineLimit(3)
                    .frame(minHeight: 42, alignment: .top)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(
            ExperienceThemeOptionCardStyle(
                activeTheme: activeTheme,
                previewTheme: previewTheme,
                isSelected: isSelected,
                isHovered: isHovered,
                reduceMotion: reduceMotion
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityIdentifier("settings.theme.\(themeID.rawValue)")
        .accessibilityLabel("\(previewTheme.metadata.displayName) 体验主题")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(
                    isSelected
                        ? previewTheme.visual.accent
                        : activeTheme.visual.primaryText.opacity(0.045)
                )
            Circle()
                .strokeBorder(
                    isSelected
                        ? previewTheme.visual.accent
                        : activeTheme.visual.settingsCardBorder,
                    lineWidth: 1
                )

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(selectionForeground)
            }
        }
        .frame(width: 18, height: 18)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isSelected
        )
    }

    private var selectionForeground: Color {
        previewTheme.visual.settingsChromeStyle == .pixel
            ? previewTheme.visual.settingsSurface
            : .white
    }
}

struct PixelThemePalettePicker: View {
    @Binding var selection: PixelThemePaletteID

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PixelThemePaletteID.allCases) { paletteID in
                let theme = ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: paletteID)
                Button {
                    selection = paletteID
                } label: {
                    HStack(spacing: 9) {
                        HStack(spacing: 2) {
                            theme.visual.settingsSidebarSurface
                            theme.visual.settingsCardSurface
                            theme.visual.accent
                            theme.visual.primaryText
                        }
                        .frame(width: 46, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(theme.visual.settingsCardBorder, lineWidth: 1)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(appLocalized: paletteID.displayName)
                                .font(theme.visual.font(size: 11, weight: .bold))
                            Text(appLocalized: paletteID.description)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: selection == paletteID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == paletteID ? theme.visual.accent : .secondary)
                    }
                    .foregroundStyle(theme.visual.primaryText)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.visual.previewSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                selection == paletteID ? theme.visual.accent : theme.visual.settingsCardBorder,
                                lineWidth: selection == paletteID ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(paletteID.displayName) Pixel 配色")
                .accessibilityValue(selection == paletteID ? "已选择" : "未选择")
            }
        }
    }
}

private struct ConfirmationActionButtonStyle: ButtonStyle {
    let appearance: ConfirmationActionAppearance
    let cornerRadius: CGFloat
    let motion: ExperienceThemeMotionTokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(appearance.foreground.opacity(configuration.isPressed ? 0.82 : 1))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: cornerRadius <= 3 ? .circular : .continuous)
                    .fill(appearance.background.opacity(configuration.isPressed ? 0.76 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: cornerRadius <= 3 ? .circular : .continuous)
                    .strokeBorder(appearance.border.opacity(configuration.isPressed ? 0.55 : 0.82), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? motion.controlPressScale : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: motion.controlPressDuration),
                value: configuration.isPressed
            )
    }
}

private struct ConfirmationActionSymbol: View {
    let role: ConfirmationActionRole
    let compact: Bool
    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        if theme.visual.usesPixelGrid {
            PixelActionGlyph(role: role)
                .frame(width: compact ? 10 : 12, height: compact ? 10 : 12)
        } else {
            Image(systemName: role.systemImage)
                .font(.system(size: compact ? 9 : 11, weight: .bold, design: .default))
        }
    }
}

private struct PixelActionGlyph: View {
    let role: ConfirmationActionRole
    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 7
            let path = pixelPath(unit: unit)
            context.fill(path, with: .color(theme.interaction.appearance(for: role).foreground))
        }
        .accessibilityHidden(true)
    }

    private func pixelPath(unit: CGFloat) -> Path {
        var path = Path()
        for point in points {
            path.addRect(CGRect(x: CGFloat(point.x) * unit, y: CGFloat(point.y) * unit, width: unit, height: unit))
        }
        return path
    }

    private var points: [(x: Int, y: Int)] {
        switch role {
        case .approve:
            return [(1, 3), (2, 4), (3, 5), (4, 4), (5, 3), (6, 2), (5, 1)]
        case .scopedApproval:
            return [(2, 1), (3, 1), (1, 2), (5, 2), (1, 3), (5, 3), (2, 4), (3, 5), (4, 4), (5, 5)]
        case .deny:
            return [(1, 1), (5, 1), (2, 2), (4, 2), (3, 3), (2, 4), (4, 4), (1, 5), (5, 5)]
        case .neutral:
            return [(1, 2), (2, 2), (3, 2), (4, 2), (4, 1), (5, 1), (5, 2), (3, 3), (3, 4), (3, 5)]
        }
    }
}

private struct ExperienceThemeOptionCardStyle: ButtonStyle {
    let activeTheme: IslandExperienceTheme
    let previewTheme: IslandExperienceTheme
    let isSelected: Bool
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(
                    cornerRadius: activeTheme.visual.sectionCornerRadius,
                    style: activeTheme.visual.sectionCornerRadius <= 3 ? .circular : .continuous
                )
                .fill(activeTheme.visual.previewSurface)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: activeTheme.visual.sectionCornerRadius,
                        style: activeTheme.visual.sectionCornerRadius <= 3 ? .circular : .continuous
                    )
                    .fill(previewTheme.visual.accent.opacity(selectionTintOpacity))
                }
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: activeTheme.visual.sectionCornerRadius,
                    style: activeTheme.visual.sectionCornerRadius <= 3 ? .circular : .continuous
                )
                .strokeBorder(
                    isSelected
                        ? previewTheme.visual.accent.opacity(0.92)
                        : activeTheme.visual.settingsCardBorder.opacity(isHovered ? 1 : 0.72),
                    lineWidth: isSelected ? 1.5 : 1
                )
            }
            .shadow(
                color: isSelected ? previewTheme.visual.accent.opacity(0.12) : .clear,
                radius: 12,
                y: 5
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: isHovered
            )
    }

    private var selectionTintOpacity: Double {
        if isSelected {
            return activeTheme.visual.usesPixelGrid ? 0.18 : 0.11
        }
        return isHovered ? 0.055 : 0
    }
}

private struct ExperienceThemePreview: View {
    let theme: IslandExperienceTheme

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.86))
                Circle().fill(Color.yellow.opacity(0.86))
                Circle().fill(Color.green.opacity(0.86))
                Spacer()
                RoundedRectangle(cornerRadius: theme.visual.controlCornerRadius <= 3 ? 1 : 3)
                    .fill(theme.visual.secondaryText.opacity(0.52))
                    .frame(width: 28, height: 5)
            }
            .frame(height: 9)

            HStack(spacing: 4) {
                theme.visual.previewSidebarSurface

                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        theme.interaction.approve.background
                        theme.interaction.scopedApproval.background
                        theme.interaction.deny.background
                    }
                    .frame(height: 7)

                    RoundedRectangle(cornerRadius: theme.visual.controlCornerRadius <= 3 ? 1 : 3)
                        .fill(theme.visual.primaryText.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.visual.sectionCornerRadius))
            .frame(height: 28)
        }
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: theme.visual.sectionCornerRadius)
                .fill(theme.visual.previewSurface)
                .overlay(ExperienceThemeGridTexture())
        }
    }
}
