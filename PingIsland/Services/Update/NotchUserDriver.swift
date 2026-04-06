import AppKit
import Combine
import Foundation
import Sparkle

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

enum UpdateConfigurationStatus: Equatable {
    case configured
    case unconfigured

    var message: String {
        switch self {
        case .configured:
            "更新源已准备就绪"
        case .unconfigured:
            "缺少 Sparkle 更新源或公钥配置"
        }
    }
}

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate = false
    @Published private(set) var latestReleaseNotes: UpdateReleaseNotes?
    @Published private(set) var configurationStatus = UpdateConfigurationStatus.unconfigured
    @Published private(set) var availableVersion: String?

    private var updaterController: SPUStandardUpdaterController?
    private var latestAppcastItem: SUAppcastItem?
    private var releaseNotesTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    var isConfigured: Bool {
        configurationStatus == .configured
    }

    var canShowReleaseNotes: Bool {
        latestReleaseNotes != nil || latestAppcastItem != nil
    }

    var releaseNotesActionTitle: String {
        if let version = availableVersion {
            return "查看 v\(version) 更新日志"
        }
        return "查看版本历史"
    }

    var releaseNotesActionSubtitle: String {
        "使用独立弹窗查看 Markdown 更新日志"
    }

    func start() {
        guard updaterController == nil else { return }

        let configuration = UpdateConfiguration(bundle: .main)
        configurationStatus = configuration.status
        guard configuration.status == .configured else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller
        controller.startUpdater()
        _ = controller.updater.clearFeedURLFromUserDefaults()
    }

    func checkForUpdates() {
        guard let updater = updaterController?.updater else {
            state = .error(message: configurationStatus.message)
            return
        }

        state = .checking
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updaterController?.updater.checkForUpdatesInBackground()
    }

    func downloadAndInstall() {
        updaterController?.updater.checkForUpdates()
    }

    func installAndRelaunch() {
        updaterController?.updater.checkForUpdates()
    }

    func skipUpdate() {
        state = .idle
    }

    func dismissUpdate() {
        state = .idle
    }

    func cancelDownload() {
        state = .idle
    }

    func markUpdateSeen() {
        hasUnseenUpdate = false
    }

    func showReleaseNotes() {
        if let notes = latestReleaseNotes {
            ReleaseNotesWindowController.shared.present(notes: notes)
            return
        }

        guard let item = latestAppcastItem else { return }

        Task { [weak self] in
            guard let self else { return }
            let notes = await Self.loadReleaseNotes(for: item, installedVersion: Self.installedVersion)

            await MainActor.run {
                if let notes {
                    self.latestReleaseNotes = notes
                    ReleaseNotesWindowController.shared.present(notes: notes)
                } else if let fallbackURL = item.fullReleaseNotesURL ?? item.releaseNotesURL {
                    NSWorkspace.shared.open(fallbackURL)
                }
            }
        }
    }

    private func handleLatestAppcastItem(_ item: SUAppcastItem, userInitiated: Bool) {
        if latestReleaseNotes?.targetVersion != item.displayVersionString {
            latestReleaseNotes = nil
        }
        latestAppcastItem = item
        availableVersion = item.displayVersionString
        hasUnseenUpdate = true
        state = .found(version: item.displayVersionString, releaseNotes: latestReleaseNotes?.markdown)

        releaseNotesTask?.cancel()
        releaseNotesTask = Task { [weak self] in
            let notes = await Self.loadReleaseNotes(for: item, installedVersion: Self.installedVersion)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.latestAppcastItem?.versionString == item.versionString else { return }

                self.latestReleaseNotes = notes
                self.state = .found(version: item.displayVersionString, releaseNotes: notes?.markdown)

                if userInitiated, let notes {
                    ReleaseNotesWindowController.shared.present(notes: notes)
                }
            }
        }
    }

    private func handleNoUpdateFound() {
        state = .upToDate

        Task {
            try? await Task.sleep(for: .seconds(2))
            if state == .upToDate {
                state = .idle
            }
        }
    }

    private static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "当前版本"
    }

    private static func preferredReleaseNotesURL(for item: SUAppcastItem) -> URL? {
        if let fullURL = item.fullReleaseNotesURL {
            return fullURL
        }

        if let releaseURL = item.releaseNotesURL {
            return releaseURL
        }

        guard let fileURL = item.fileURL else {
            return nil
        }

        return fileURL.deletingPathExtension().appendingPathExtension("md")
    }

    private static func loadReleaseNotes(for item: SUAppcastItem, installedVersion: String) async -> UpdateReleaseNotes? {
        let targetVersion = item.displayVersionString
        let sourceURL = preferredReleaseNotesURL(for: item)

        if let sourceURL,
           let markdown = await fetchMarkdown(from: sourceURL),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return UpdateReleaseNotes(
                currentVersion: installedVersion,
                targetVersion: targetVersion,
                markdown: markdown,
                sourceURL: sourceURL,
                publishedAt: item.date
            )
        }

        if let embedded = embeddedReleaseNotes(for: item) {
            return UpdateReleaseNotes(
                currentVersion: installedVersion,
                targetVersion: targetVersion,
                markdown: embedded,
                sourceURL: sourceURL,
                publishedAt: item.date
            )
        }

        return nil
    }

    private static func fetchMarkdown(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let body = String(data: data, encoding: .utf8) else {
                return nil
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let isMarkdown = contentType.contains("markdown")
                || contentType.contains("text/plain")
                || url.pathExtension.lowercased() == "md"
                || url.pathExtension.lowercased() == "markdown"

            return isMarkdown ? body : nil
        } catch {
            return nil
        }
    }

    private static func embeddedReleaseNotes(for item: SUAppcastItem) -> String? {
        guard let description = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return nil
        }

        let format = item.itemDescriptionFormat?.lowercased() ?? "html"
        guard format == "plain-text" else {
            return nil
        }

        return description
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        guard let newestItem = appcast.items.first else { return }
        latestAppcastItem = newestItem
        availableVersion = newestItem.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        handleLatestAppcastItem(item, userInitiated: false)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        handleNoUpdateFound()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state userState: SPUUserUpdateState) {
        availableVersion = updateItem.displayVersionString

        switch choice {
        case .install:
            switch userState.stage {
            case .notDownloaded:
                state = .downloading(progress: 0)
            case .downloaded:
                state = .readyToInstall(version: updateItem.displayVersionString)
            case .installing:
                state = .installing
            @unknown default:
                state = .installing
            }
        case .dismiss, .skip:
            state = .idle
        @unknown default:
            state = .idle
        }
    }
}

extension UpdateManager: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        true
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        handleLatestAppcastItem(item, userInitiated: true)
        showReleaseNotes()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state userState: SPUUserUpdateState) {
        availableVersion = update.displayVersionString

        switch userState.stage {
        case .notDownloaded:
            state = .found(version: update.displayVersionString, releaseNotes: latestReleaseNotes?.markdown)
        case .downloaded:
            state = .readyToInstall(version: update.displayVersionString)
        case .installing:
            state = .installing
        @unknown default:
            state = .found(version: update.displayVersionString, releaseNotes: latestReleaseNotes?.markdown)
        }

        handleLatestAppcastItem(update, userInitiated: userState.userInitiated)
    }
}

private struct UpdateConfiguration {
    let feedURL: String
    let publicKey: String

    init(bundle: Bundle) {
        self.feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var status: UpdateConfigurationStatus {
        guard !feedURL.isEmpty,
              URL(string: feedURL) != nil,
              !publicKey.isEmpty else {
            return .unconfigured
        }

        return .configured
    }
}
