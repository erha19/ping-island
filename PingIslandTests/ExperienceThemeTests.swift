import AppKit
import SwiftUI
import XCTest
@testable import Ping_Island

final class ExperienceThemeTests: XCTestCase {
    func testPingIslandIsTheAppDefaultTheme() {
        XCTAssertEqual(ExperienceThemeID.appDefault, .standard)
        XCTAssertEqual(
            ExperienceThemeRegistry.theme(for: .appDefault).metadata.displayName,
            "PingIsland 原生"
        )
    }

    func testRegistryContainsEveryPersistedBuiltInThemeExactlyOnce() {
        let registeredIDs = ExperienceThemeRegistry.all.map(\.id)

        XCTAssertEqual(Set(registeredIDs), Set(ExperienceThemeID.allCases))
        XCTAssertEqual(registeredIDs.count, Set(registeredIDs).count)
    }

    func testThreeThemeFamiliesKeepTheirOwnVisualContracts() {
        let pingIsland = ExperienceThemeRegistry.theme(for: .standard)
        let macOS = ExperienceThemeRegistry.theme(for: .macOS)
        let pixel = ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: .arcadeNeon)

        XCTAssertEqual(pingIsland.metadata.displayName, "PingIsland 原生")
        XCTAssertEqual(pingIsland.sound.recommendedMode, .island8Bit)
        XCTAssertEqual(pingIsland.visual.settingsChromeStyle, .pingIsland)

        XCTAssertEqual(macOS.metadata.displayName, "macOS")
        XCTAssertEqual(macOS.sound.recommendedMode, .builtIn)
        XCTAssertEqual(macOS.visual.settingsChromeStyle, .macOS)
        XCTAssertNil(macOS.pixelPaletteID)

        XCTAssertEqual(pixel.metadata.displayName, "Pixel")
        XCTAssertTrue(pixel.visual.usesPixelGrid)
        XCTAssertFalse(pixel.visual.usesGlassMaterial)
        XCTAssertEqual(pixel.visual.controlCornerRadius, 2)
        XCTAssertEqual(pixel.pixelPaletteID, .arcadeNeon)
        XCTAssertEqual(pixel.visual.customFontName, "Silkscreen-Bold")
    }

    func testDockedNotchKeepsCanonicalBlackStyleAcrossExperienceThemes() throws {
        let surface = try XCTUnwrap(
            NSColor(DockedNotchVisualStyle.surfaceColor).usingColorSpace(.deviceRGB)
        )
        let separator = try XCTUnwrap(
            NSColor(DockedNotchVisualStyle.topSeparatorColor).usingColorSpace(.deviceRGB)
        )

        for color in [surface, separator] {
            XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
            XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
            XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }

        XCTAssertEqual(DockedNotchVisualStyle.contentTheme.id, .standard)
        XCTAssertEqual(DockedNotchVisualStyle.openResponse, 0.42)
        XCTAssertEqual(DockedNotchVisualStyle.openDampingFraction, 0.8)
        XCTAssertEqual(DockedNotchVisualStyle.closeResponse, 0.45)
        XCTAssertEqual(DockedNotchVisualStyle.closeDampingFraction, 1.0)
    }

    func testThemeSoundProfilesMatchTheirRecommendedModes() {
        for id in ExperienceThemeID.allCases {
            let theme = ExperienceThemeRegistry.theme(for: id)
            XCTAssertEqual(theme.sound.recommendedMode, id.recommendedSoundThemeMode)
        }

        XCTAssertEqual(
            ExperienceThemeRegistry.theme(for: .pixel).sound.cue(for: .clientStarted)?.island8BitSound,
            .bootJingle
        )
    }

    func testPixelPalettesShareTheAgentIslandSoundProfile() {
        let arcade = ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: .arcadeNeon)
        let gameBoy = ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: .gameBoyOlive)

        XCTAssertNotEqual(
            String(describing: arcade.visual.accent),
            String(describing: gameBoy.visual.accent)
        )
        XCTAssertEqual(
            arcade.sound.cue(for: NotificationEvent.taskCompleted),
            gameBoy.sound.cue(for: NotificationEvent.taskCompleted)
        )
        XCTAssertEqual(
            arcade.sound.cue(for: NotificationEvent.taskError),
            gameBoy.sound.cue(for: NotificationEvent.taskError)
        )
        XCTAssertEqual(
            arcade.sound.cue(for: NotificationEvent.taskCompleted)?.island8BitSound,
            .completeDing
        )
        XCTAssertEqual(
            arcade.sound.cue(for: NotificationEvent.taskError)?.island8BitSound,
            .errorBuzz
        )
        XCTAssertEqual(
            arcade.sound.cue(for: NotificationEvent.resourceLimit)?.island8BitSound,
            .hurt
        )
    }

    func testConfirmationActionRolesKeepTheirSemanticsDistinct() {
        XCTAssertEqual(ConfirmationActionRole.approve.systemImage, "checkmark")
        XCTAssertEqual(ConfirmationActionRole.scopedApproval.systemImage, "checkmark.circle")
        XCTAssertEqual(ConfirmationActionRole.deny.systemImage, "xmark")
        XCTAssertEqual(ConfirmationActionRole.neutral.systemImage, "arrow.up.right.square")
        XCTAssertEqual(ConfirmationActionRole.approve.soundFeedbackEvent, .approvalAccepted)
        XCTAssertEqual(ConfirmationActionRole.scopedApproval.soundFeedbackEvent, .approvalScoped)
        XCTAssertEqual(ConfirmationActionRole.deny.soundFeedbackEvent, .approvalRejected)
        XCTAssertNil(ConfirmationActionRole.neutral.soundFeedbackEvent)
    }

    func testEveryThemeSuppliesCuesForAuxiliaryFeedback() {
        let auxiliaryEvents = AppSoundFeedbackEvent.allCases.filter { $0.notificationEvent == nil }

        for theme in ExperienceThemeRegistry.all {
            for event in auxiliaryEvents {
                XCTAssertNotNil(
                    theme.sound.cue(for: event),
                    "\(theme.id.rawValue) must define a cue for \(event.id)"
                )
            }
        }
    }

    func testEveryThemeSuppliesCuesForConfigurableLifecycleFeedback() {
        for theme in ExperienceThemeRegistry.all {
            for event in NotificationEvent.allCases {
                XCTAssertNotNil(
                    theme.sound.cue(for: event),
                    "\(theme.id.rawValue) must define a lifecycle cue for \(event.rawValue)"
                )
            }
        }
    }
}
