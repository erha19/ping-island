import XCTest
@testable import NotchCode

final class DiagnosticsCommandRunnerTests: XCTestCase {
    func testRunnerHandlesLargeOutputWithoutHanging() async throws {
        let result = try await DiagnosticsCommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes 'ping-island-diagnostics' | head -n 20000"],
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("ping-island-diagnostics"))
        XCTAssertGreaterThan(result.output.count, 100_000)
    }

    func testRunnerTimesOutLongRunningCommand() async throws {
        do {
            _ = try await DiagnosticsCommandRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 0.1
            )
            XCTFail("Expected command to time out")
        } catch let error as DiagnosticsCommandError {
            guard case .timedOut(let executable, let timeout) = error else {
                return XCTFail("Expected timeout error, got \(error)")
            }

            XCTAssertEqual(executable, "/bin/sh")
            XCTAssertEqual(timeout, 0.1, accuracy: 0.001)
        }
    }
}
