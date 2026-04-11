import XCTest
@testable import Ping_Island

final class FeatureFlagsTests: XCTestCase {
    func testEnvironmentOverridesUserDefaultsForTruthyValues() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: RuntimeFeatureFlag.nativeClaudeRuntime.defaultsKey)

        XCTAssertTrue(
            FeatureFlags.isEnabled(
                .nativeClaudeRuntime,
                defaults: defaults,
                environment: [RuntimeFeatureFlag.nativeClaudeRuntime.environmentKey: "true"]
            )
        )
    }

    func testEnvironmentOverridesUserDefaultsForFalsyValues() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: RuntimeFeatureFlag.nativeCodexRuntime.defaultsKey)

        XCTAssertFalse(
            FeatureFlags.isEnabled(
                .nativeCodexRuntime,
                defaults: defaults,
                environment: [RuntimeFeatureFlag.nativeCodexRuntime.environmentKey: "off"]
            )
        )
    }

    func testFallsBackToUserDefaultsWhenEnvironmentIsMissing() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: RuntimeFeatureFlag.nativeCodexRuntime.defaultsKey)

        XCTAssertTrue(
            FeatureFlags.isEnabled(
                .nativeCodexRuntime,
                defaults: defaults,
                environment: [:]
            )
        )
    }
}
