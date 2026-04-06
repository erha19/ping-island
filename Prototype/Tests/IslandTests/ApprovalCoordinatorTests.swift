import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func approvalCoordinatorReturnsResolvedDecision() async throws {
    let coordinator = ApprovalCoordinator()
    let requestID = UUID()

    let waitingTask = Task {
        await coordinator.waitForDecision(requestID: requestID)
    }

    Task.detached {
        try? await Task.sleep(for: .milliseconds(50))
        await coordinator.resolve(requestID: requestID, decision: .approveForSession)
    }

    let resolved = await waitingTask.value

    #expect(resolved == .approveForSession)
}
