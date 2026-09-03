import Foundation

/// Stable persisted identity for a compiled-in experience theme. Visual tokens
/// and sound cues live with each implementation under `UI/Themes/`.
enum ExperienceThemeID: String, CaseIterable, Identifiable {
    /// Kept as `standard` on disk so existing installations migrate without
    /// losing their selected theme. In the UI this is the PingIsland theme.
    case standard
    case macOS
    case pixel

    /// The theme used for fresh installs and as the safe fallback when a
    /// persisted identifier is missing or no longer recognized.
    static let appDefault: ExperienceThemeID = .standard

    var id: String { rawValue }

    var recommendedSoundThemeMode: SoundThemeMode {
        switch self {
        case .standard:
            return .island8Bit
        case .macOS:
            return .builtIn
        case .pixel:
            return .island8Bit
        }
    }
}

/// Pixel is one experience family with multiple visual palettes. Keeping the
/// palette separate avoids duplicating its component and sound implementation.
enum PixelThemePaletteID: String, CaseIterable, Identifiable {
    case arcadeNeon
    case gameBoyOlive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arcadeNeon:
            return "Arcade Neon"
        case .gameBoyOlive:
            return "Game Boy Olive"
        }
    }

    var description: String {
        switch self {
        case .arcadeNeon:
            return "街机厅深色底与高对比霓虹色。"
        case .gameBoyOlive:
            return "经典掌机的四阶橄榄绿色调。"
        }
    }
}

/// Visual and feedback intent for an action that affects a pending operation.
/// Views use this rather than choosing colors ad hoc.
enum ConfirmationActionRole: String, CaseIterable, Identifiable {
    case approve
    case scopedApproval
    case deny
    case neutral

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .approve:
            return "checkmark"
        case .scopedApproval:
            return "checkmark.circle"
        case .deny:
            return "xmark"
        case .neutral:
            return "arrow.up.right.square"
        }
    }

    var soundFeedbackEvent: AppSoundFeedbackEvent? {
        switch self {
        case .approve:
            return .approvalAccepted
        case .scopedApproval:
            return .approvalScoped
        case .deny:
            return .approvalRejected
        case .neutral:
            return nil
        }
    }
}
