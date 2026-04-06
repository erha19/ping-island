import Combine
import Foundation

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case found(version: String, releaseNotes: String?)
    case downloading(progress: Double)
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    var isActive: Bool {
        switch self {
        case .idle, .upToDate, .error:
            false
        default:
            true
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate = false

    private init() {}

    func checkForUpdates() {
        state = .upToDate
        Task {
            try? await Task.sleep(for: .seconds(2))
            if state == .upToDate {
                state = .idle
            }
        }
    }

    func downloadAndInstall() {}
    func installAndRelaunch() {}
    func skipUpdate() { state = .idle }
    func dismissUpdate() { state = .idle }
    func cancelDownload() { state = .idle }
    func markUpdateSeen() { hasUnseenUpdate = false }
}
