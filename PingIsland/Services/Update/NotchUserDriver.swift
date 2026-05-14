import AppKit
import Combine
import Foundation
#if !APP_STORE
import Sparkle
#endif

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
    case appStoreManaged

    var message: String {
        switch self {
        case .configured:
            "更新源已准备就绪"
        case .unconfigured:
            "缺少 Sparkle 更新源或公钥配置"
        case .appStoreManaged:
            "更新由 Mac App Store 管理"
        }
    }
}

#if APP_STORE
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    nonisolated static let silentCheckInterval: TimeInterval = 10 * 60

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate = false
    @Published private(set) var latestReleaseNotes: UpdateReleaseNotes?
    @Published private(set) var configurationStatus = UpdateConfigurationStatus.appStoreManaged
    @Published private(set) var availableVersion: String?

    private init() {}

    var isConfigured: Bool {
        false
    }

    var canShowReleaseNotes: Bool {
        false
    }

    var releaseNotesActionTitle: String {
        "版本历史由 App Store 管理"
    }

    var releaseNotesActionSubtitle: String {
        "Mac App Store 版本不包含独立更新器"
    }

    func start() {}

    func checkForUpdates() {
        state = .upToDate
    }

    func checkForUpdatesInBackground() {}

    func downloadAndInstall() {}

    func installAndRelaunch() {}

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

    func showReleaseNotes() {}

    nonisolated static func hasActiveSessions(in sessions: [SessionState]) -> Bool {
        sessions.contains(where: { $0.phase.isActive })
    }

    nonisolated static func isValidFeedURL(_ value: String) -> Bool {
        false
    }
}
#else
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()
    nonisolated static let silentCheckInterval: TimeInterval = 10 * 60

    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate = false
    @Published private(set) var latestReleaseNotes: UpdateReleaseNotes?
    @Published private(set) var configurationStatus = UpdateConfigurationStatus.unconfigured
    @Published private(set) var availableVersion: String?

    private var updaterController: SPUStandardUpdaterController?
    private var latestAppcastItem: SUAppcastItem?
    private var releaseNotesTask: Task<Void, Never>?
    private var sessionActivityObserver: AnyCancellable?
    private var updatePreferenceObserver: AnyCancellable?
    private var energyPolicyObserver: AnyCancellable?
    private var inactiveCheckTimer: Timer?
    private var pendingSilentInstall: (() -> Void)?
    private var hasActiveSessions = false

    private override init() {
        super.init()
    }

    private enum UpdateCheckTrigger {
        case automatic
        case manual
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

    private var automaticUpdateChecksEnabled: Bool {
        AppSettings.shared.automaticUpdateChecksEnabled
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
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = true
        _ = updater.clearFeedURLFromUserDefaults()

        beginObservingUpdatePreferenceIfNeeded()
        beginObservingSessionActivityIfNeeded()
        beginObservingEnergyPolicyIfNeeded()
        refreshSilentUpdateSchedule(hasActiveSessions: Self.hasActiveSessions(in: []))
        performUpdateCheck(trigger: .automatic)
    }

    func checkForUpdates() {
        guard updaterController != nil else {
            state = .error(message: configurationStatus.message)
            return
        }

        performUpdateCheck(trigger: .manual)
    }

    func checkForUpdatesInBackground() {
        performUpdateCheck(trigger: .automatic)
    }

    func downloadAndInstall() {
        performUpdateCheck(trigger: .manual)
    }

    func installAndRelaunch() {
        installPendingUpdateIfPossible(userInitiated: true)
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

    private func beginObservingSessionActivityIfNeeded() {
        guard sessionActivityObserver == nil else { return }

        sessionActivityObserver = SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.refreshSilentUpdateSchedule(hasActiveSessions: Self.hasActiveSessions(in: sessions))
            }
    }

    private func beginObservingUpdatePreferenceIfNeeded() {
        guard updatePreferenceObserver == nil else { return }

        updatePreferenceObserver = AppSettings.shared.$automaticUpdateChecksEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshSilentUpdateSchedule(hasActiveSessions: self.hasActiveSessions)
            }
    }

    private func beginObservingEnergyPolicyIfNeeded() {
        guard energyPolicyObserver == nil else { return }

        energyPolicyObserver = EnergyGovernor.shared.$policy
            .map(\.allowsSilentUpdates)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshSilentUpdateSchedule(hasActiveSessions: self.hasActiveSessions)
            }
    }

    private func refreshSilentUpdateSchedule(hasActiveSessions: Bool) {
        self.hasActiveSessions = hasActiveSessions

        if hasActiveSessions || !automaticUpdateChecksEnabled || !EnergyGovernor.shared.policy.allowsSilentUpdates {
            inactiveCheckTimer?.invalidate()
            inactiveCheckTimer = nil
            return
        }

        installPendingUpdateIfPossible(userInitiated: false)

        guard inactiveCheckTimer == nil else { return }

        inactiveCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.silentCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performUpdateCheck(trigger: .automatic)
            }
        }

        if let inactiveCheckTimer {
            RunLoop.main.add(inactiveCheckTimer, forMode: .common)
        }
    }

    private func performUpdateCheck(trigger: UpdateCheckTrigger) {
        if case .automatic = trigger, !automaticUpdateChecksEnabled {
            return
        }

        guard let updater = updaterController?.updater else {
            state = .error(message: configurationStatus.message)
            return
        }

        guard updater.canCheckForUpdates else {
            let userInitiated: Bool
            switch trigger {
            case .automatic:
                userInitiated = false
            case .manual:
                userInitiated = true
            }

            installPendingUpdateIfPossible(userInitiated: userInitiated)
            return
        }

        state = .checking
        updater.checkForUpdatesInBackground()
    }

    private func installPendingUpdateIfPossible(userInitiated: Bool) {
        guard let pendingSilentInstall else { return }
        guard userInitiated
            || (
                automaticUpdateChecksEnabled
                    && !hasActiveSessions
                    && EnergyGovernor.shared.policy.allowsSilentUpdates
            ) else { return }

        self.pendingSilentInstall = nil
        hasUnseenUpdate = false
        state = .installing
        pendingSilentInstall()
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

    private func handleUpdateCycleError(_ error: NSError) {
        switch Self.terminalState(forUpdateCycleError: error) {
        case .upToDate:
            handleNoUpdateFound()
        case .error(let message):
            state = .error(message: message)
        default:
            break
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

    nonisolated static func hasActiveSessions(in sessions: [SessionState]) -> Bool {
        sessions.contains(where: { $0.phase.isActive })
    }

    nonisolated static func isValidFeedURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return false
        }

        switch scheme {
        case "https", "http":
            return !(components.host?.isEmpty ?? true)
        case "file":
            return !components.path.isEmpty
        default:
            return false
        }
    }

    nonisolated static func terminalState(forUpdateCycleError error: NSError) -> UpdateState {
        if let noUpdateReason = noUpdateReason(from: error) {
            switch noUpdateReason {
            case .onLatestVersion, .onNewerThanLatestVersion, .unknown:
                return .upToDate
            case .systemIsTooOld:
                return .error(message: "当前系统版本过低，无法安装可用更新")
            case .systemIsTooNew:
                return .error(message: "当前系统版本过新，暂时没有兼容的更新")
            case .hardwareDoesNotSupportARM64:
                return .error(message: "当前设备架构不支持可用更新")
            @unknown default:
                return .upToDate
            }
        }

        if let actionableMessage = actionableMessage(forUpdateCycleError: error) {
            return .error(message: actionableMessage)
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .error(message: "更新失败，请稍后再试")
        }

        return .error(message: message)
    }

    private nonisolated static func noUpdateReason(from error: NSError) -> SPUNoUpdateFoundReason? {
        guard error.domain == SUSparkleErrorDomain,
              error.code == Int(SUError.noUpdateError.rawValue) else {
            return nil
        }

        if let rawReason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue,
           let reason = SPUNoUpdateFoundReason(rawValue: OSStatus(rawReason)) {
            return reason
        }

        return .unknown
    }

    private nonisolated static func actionableMessage(forUpdateCycleError error: NSError) -> String? {
        if let networkMessage = updateFeedNetworkMessage(from: error) {
            return networkMessage
        }

        return nil
    }

    private nonisolated static func updateFeedNetworkMessage(from error: NSError) -> String? {
        guard error.domain == SUSparkleErrorDomain,
              error.code == Int(SUError.downloadError.rawValue) else {
            return nil
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            if let statusCode = httpStatusCode(from: underlyingError) {
                switch statusCode {
                case 401, 403:
                    return "更新源拒绝访问，请确认 appcast 发布资源仍可公开访问"
                case 404:
                    return "更新源不可用：未找到已发布的 appcast.xml"
                case 500 ... 599:
                    return "更新服务器暂时不可用，请稍后再试"
                default:
                    break
                }
            }

            if underlyingError.domain == NSURLErrorDomain {
                switch underlyingError.code {
                case NSURLErrorNotConnectedToInternet:
                    return "网络不可用，请检查连接后重试"
                case NSURLErrorTimedOut:
                    return "连接更新源超时，请稍后重试"
                case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                    return "无法连接更新源，请稍后再试"
                default:
                    break
                }
            }
        }

        return nil
    }

    private nonisolated static func httpStatusCode(from error: NSError) -> Int? {
        if let numericStatusCode = error.userInfo["HTTPStatusCode"] as? NSNumber {
            return numericStatusCode.intValue
        }

        let message = error.localizedDescription
        let pattern = #"\((\d{3})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else {
            return nil
        }

        return Int(message[range])
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerformUpdateCheck updateCheck: SPUUpdateCheck, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool {
        true
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        guard let newestItem = appcast.items.first else { return }
        latestAppcastItem = newestItem
        availableVersion = newestItem.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        handleLatestAppcastItem(item, userInitiated: false)
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading(progress: 0)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        state = .readyToInstall(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        state = .extracting(progress: 0)
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        state = .readyToInstall(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        hasUnseenUpdate = false
        state = .installing
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        state = .readyToInstall(version: item.displayVersionString)
        pendingSilentInstall = { [weak self] in
            self?.hasUnseenUpdate = false
            self?.state = .installing
            immediateInstallHandler()
        }

        installPendingUpdateIfPossible(userInitiated: false)
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        handleUpdateCycleError(error as NSError)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        handleUpdateCycleError(error as NSError)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            handleUpdateCycleError(error as NSError)
        } else if case .checking = state {
            handleNoUpdateFound()
        }
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

extension UpdateManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool {
        false
    }

    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        true
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        handleLatestAppcastItem(item, userInitiated: true)
        showReleaseNotes()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state userState: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        handleLatestAppcastItem(update, userInitiated: userState.userInitiated)

        guard handleShowingUpdate || userState.userInitiated else {
            if userState.stage == .downloaded {
                state = .readyToInstall(version: update.displayVersionString)
            }
            return
        }

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
              UpdateManager.isValidFeedURL(feedURL),
              !publicKey.isEmpty else {
            return .unconfigured
        }

        return .configured
    }
}
#endif
