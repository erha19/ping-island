import XCTest
@testable import Ping_Island

@MainActor
final class SettingsPanelViewModelTests: XCTestCase {
    private actor StubRuntimeLauncher: NativeRuntimeLaunching {
        var started: [(SessionProvider, String)] = []
        var nextError: Error?

        func startSession(provider: SessionProvider, cwd: String) async throws {
            if let nextError {
                throw nextError
            }
            started.append((provider, cwd))
        }

        func launches() -> [(SessionProvider, String)] {
            started
        }
    }

    func testStartNativeRuntimeSessionValidatesDirectoryBeforeLaunch() async {
        let launcher = StubRuntimeLauncher()
        let viewModel = SettingsPanelViewModel(
            runtimeLauncher: launcher,
            fileExists: { _ in false }
        )
        viewModel.nativeRuntimeWorkingDirectory = "/missing/path"

        viewModel.startNativeRuntimeSession(provider: .claude)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.nativeRuntimeStatusMessage, "目录不存在：/missing/path")
        let launches = await launcher.launches()
        XCTAssertTrue(launches.isEmpty)
    }

    func testStartNativeRuntimeSessionCallsLauncherAndUpdatesStatus() async {
        let launcher = StubRuntimeLauncher()
        let viewModel = SettingsPanelViewModel(
            runtimeLauncher: launcher,
            fileExists: { _ in true }
        )
        viewModel.nativeRuntimeWorkingDirectory = "/tmp/native-ui-test"

        viewModel.startNativeRuntimeSession(provider: .codex)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let launches = await launcher.launches()
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.0, .codex)
        XCTAssertEqual(launches.first?.1, "/tmp/native-ui-test")
        XCTAssertEqual(viewModel.nativeRuntimeStatusMessage, "Codex Native Runtime 已启动")
    }
}
