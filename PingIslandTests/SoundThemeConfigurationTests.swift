import XCTest
@testable import Ping_Island

final class SoundThemeConfigurationTests: XCTestCase {
    func testIsland8BitThemeModeIsAvailable() {
        XCTAssertTrue(SoundThemeMode.allCases.contains(.island8Bit))
        XCTAssertEqual(SoundThemeMode.island8Bit.title, "内置 8-bit")
        XCTAssertEqual(
            SoundThemeMode(rawValue: "missing-theme") ?? .island8Bit,
            .island8Bit
        )
    }

    func testIsland8BitPaletteRawValuesMatchBundledFilenames() {
        XCTAssertEqual(Island8BitSound.allCases.count, 13)
        XCTAssertEqual(Island8BitSound.powerUp.rawValue, "8bit_power_up")
        XCTAssertEqual(Island8BitSound.winJingle.rawValue, "8bit_win_jingle")
        XCTAssertEqual(Island8BitSound.menuSelect.rawValue, "8bit_menu_select")
        XCTAssertEqual(Island8BitSound.itemPickup.rawValue, "8bit_item_pickup")
        XCTAssertEqual(Island8BitSound.menuHighlight.rawValue, "8bit_menu_highlight")
        XCTAssertEqual(Island8BitSound.hurt.rawValue, "8bit_hurt")
        XCTAssertEqual(Island8BitSound.bootJingle.rawValue, "8bit_boot_jingle")
        XCTAssertEqual(Island8BitSound.startChime.rawValue, "8bit_start_chime")
        XCTAssertEqual(Island8BitSound.submitBlip.rawValue, "8bit_submit_blip")
        XCTAssertEqual(Island8BitSound.completeDing.rawValue, "8bit_complete_ding")
        XCTAssertEqual(Island8BitSound.errorBuzz.rawValue, "8bit_error_buzz")
        XCTAssertEqual(Island8BitSound.approvalAlert.rawValue, "8bit_approval_alert")
        XCTAssertEqual(Island8BitSound.bubblePop.rawValue, "bubbles_pop")
    }

    func testIsland8BitLabelsCoverAllThirteenCharacters() {
        XCTAssertEqual(Island8BitSound.powerUp.label, "Power Up")
        XCTAssertEqual(Island8BitSound.winJingle.label, "Win Jingle")
        XCTAssertEqual(Island8BitSound.menuSelect.label, "Menu Select")
        XCTAssertEqual(Island8BitSound.itemPickup.label, "Item Pickup")
        XCTAssertEqual(Island8BitSound.menuHighlight.label, "Menu Highlight")
        XCTAssertEqual(Island8BitSound.hurt.label, "Hurt")
        XCTAssertEqual(Island8BitSound.bootJingle.label, "Boot Jingle")
        XCTAssertEqual(Island8BitSound.startChime.label, "Start Chime")
        XCTAssertEqual(Island8BitSound.submitBlip.label, "Submit Blip")
        XCTAssertEqual(Island8BitSound.completeDing.label, "Complete Ding")
        XCTAssertEqual(Island8BitSound.errorBuzz.label, "Error Buzz")
        XCTAssertEqual(Island8BitSound.approvalAlert.label, "Approval Alert")
        XCTAssertEqual(Island8BitSound.bubblePop.label, "Bubble Pop")
    }

    func testIsland8BitAllOrderedIsAlphabeticalByLabel() {
        let labels = Island8BitSound.allOrdered.map { $0.label }
        XCTAssertEqual(labels, labels.sorted())
        XCTAssertEqual(labels.first, "Approval Alert")
        XCTAssertEqual(labels.last, "Win Jingle")
    }

    func testIsland8BitPaletteResourcesAreReachable() {
        for sound in Island8BitSound.allCases {
            let bundle = Bundle(for: type(of: self))
                .url(forResource: sound.rawValue, withExtension: "wav")
                ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav")
                ?? Bundle.main.url(
                    forResource: sound.rawValue,
                    withExtension: "wav",
                    subdirectory: "Sounds"
                )
            XCTAssertNotNil(
                bundle,
                "Missing bundled wav for Island8BitSound.\(sound.rawValue)"
            )
        }
    }

    @MainActor
    func testPerEventIsland8BitDefaultsMatchSpec() {
        // Defaults documented in openspec change `customize-8bit-sound-per-event`.
        let defaults = UserDefaults(suiteName: "test.island8bit.defaults.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")

        // The init path on the live AppSettings reads UserDefaults.standard, so
        // we verify the documented mapping by inspecting the static defaults table.
        XCTAssertEqual(AppSettings.bundledSound(for: .processingStarted), AppSettings.shared.island8BitProcessingStartSound)
        XCTAssertEqual(AppSettings.bundledSound(for: .attentionRequired), AppSettings.shared.island8BitAttentionRequiredSound)
        XCTAssertEqual(AppSettings.bundledSound(for: .taskCompleted), AppSettings.shared.island8BitTaskCompletedSound)
        XCTAssertEqual(AppSettings.bundledSound(for: .taskError), AppSettings.shared.island8BitTaskErrorSound)
        XCTAssertEqual(AppSettings.bundledSound(for: .resourceLimit), AppSettings.shared.island8BitResourceLimitSound)
    }
}
