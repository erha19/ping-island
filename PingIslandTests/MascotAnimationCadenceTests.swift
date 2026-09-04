import XCTest
@testable import Ping_Island

final class MascotAnimationCadenceTests: XCTestCase {
    func testStandardSurfacePreservesExistingFullCadence() {
        XCTAssertEqual(frameRate(for: .idle), 12, accuracy: 0.001)
        XCTAssertEqual(frameRate(for: .working), 24, accuracy: 0.001)
        XCTAssertEqual(frameRate(for: .warning), 24, accuracy: 0.001)
        XCTAssertEqual(frameRate(for: .dragging), 30, accuracy: 0.001)
    }

    func testDetachedWorkingPetUsesTwelveFramesPerSecond() {
        XCTAssertEqual(
            frameRate(for: .working, surface: .detachedPet),
            12,
            accuracy: 0.001
        )
    }

    func testDetachedAttentionAndDraggingKeepFullCadence() {
        XCTAssertEqual(
            frameRate(for: .warning, surface: .detachedPet),
            24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            frameRate(for: .dragging, surface: .detachedPet),
            30,
            accuracy: 0.001
        )
    }

    func testReducedEnergyPolicyComposesWithDetachedWorkingCadence() {
        XCTAssertEqual(
            frameRate(
                for: .working,
                surface: .detachedPet,
                animationLevel: .reduced
            ),
            7.5,
            accuracy: 0.001
        )
    }

    private func frameRate(
        for mode: MascotRenderMode,
        surface: MascotAnimationSurface = .standard,
        animationLevel: EnergyAnimationLevel = .full
    ) -> Double {
        1.0 / MascotAnimationCadence.frameInterval(
            for: mode,
            surface: surface,
            animationLevel: animationLevel
        )
    }
}
