import AppKit
import Carbon.HIToolbox
import Combine
import CoreImage
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct NativeRuntimeLaunchResult: Equatable, Sendable {
    let sessionID: String?
    let remoteControlURL: String?
    let statusMessage: String?
}

protocol NativeRuntimeLaunching {
    func startSession(provider: SessionProvider, cwd: String) async throws -> NativeRuntimeLaunchResult
    func terminateSession(provider: SessionProvider, sessionID: String) async throws
}

struct SharedRuntimeLauncher: NativeRuntimeLaunching {
    func startSession(provider: SessionProvider, cwd: String) async throws -> NativeRuntimeLaunchResult {
        if provider == .claude {
            return try await HappyClaudeLauncher().startSession(cwd: cwd)
        }

        let handle = try await RuntimeCoordinator.shared.launchPreferredSession(provider: provider, cwd: cwd)
        return NativeRuntimeLaunchResult(sessionID: handle.sessionID, remoteControlURL: nil, statusMessage: nil)
    }

    func terminateSession(provider: SessionProvider, sessionID: String) async throws {
        if provider == .claude {
            try await HappyClaudeLauncher().terminateSession(sessionID: sessionID)
            return
        }

        try await RuntimeCoordinator.shared.terminateSession(provider: provider, sessionID: sessionID)
    }
}

struct HappyClaudeLauncher {
    private struct DaemonState: Decodable {
        let pid: Int32
        let httpPort: Int
    }

    private struct SpawnRequest: Encodable {
        let directory: String
        let sessionId: String?
        let agent: String
    }

    private struct SpawnResponse: Decodable {
        let success: Bool
        let sessionId: String?
        let error: String?
        let requiresUserApproval: Bool?
        let actionRequired: String?
        let directory: String?
    }

    private enum LaunchError: LocalizedError {
        case daemonStateMissing
        case daemonUnavailable
        case spawnFailed(String)
        case missingSessionID

        var errorDescription: String? {
            switch self {
            case .daemonStateMissing:
                return "Happy daemon 未运行，请先执行 `happy daemon start`"
            case .daemonUnavailable:
                return "Happy daemon 不可用，请确认 `happy auth status` 正常且 daemon 仍在运行"
            case .spawnFailed(let message):
                return message
            case .missingSessionID:
                return "Happy 启动 Claude 成功，但没有返回会话 ID"
            }
        }
    }

    func startSession(cwd: String) async throws -> NativeRuntimeLaunchResult {
        let state = try loadDaemonState()
        try ensureProcessAlive(pid: state.pid)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.httpPort)/spawn-session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SpawnRequest(directory: cwd, sessionId: nil, agent: "claude")
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LaunchError.daemonUnavailable
        }

        let result = try JSONDecoder().decode(SpawnResponse.self, from: data)

        switch httpResponse.statusCode {
        case 200:
            guard result.success else {
                throw LaunchError.spawnFailed(result.error ?? "Happy daemon 启动 Claude 失败")
            }
            guard let sessionId = result.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty else {
                throw LaunchError.missingSessionID
            }

            let remoteURL = Self.makeSessionURL(sessionID: sessionId)
            return NativeRuntimeLaunchResult(
                sessionID: sessionId,
                remoteControlURL: remoteURL,
                statusMessage: "Claude Native Runtime 已通过 Happy 通道启动"
            )
        case 409:
            throw LaunchError.spawnFailed("Happy daemon 需要额外确认：\(result.actionRequired ?? "CREATE_DIRECTORY")")
        default:
            throw LaunchError.spawnFailed(result.error ?? "Happy daemon 请求失败（HTTP \(httpResponse.statusCode)）")
        }
    }

    private func loadDaemonState() throws -> DaemonState {
        let daemonStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".happy", isDirectory: true)
            .appendingPathComponent("daemon.state.json")

        guard FileManager.default.fileExists(atPath: daemonStateURL.path) else {
            throw LaunchError.daemonStateMissing
        }

        let data = try Data(contentsOf: daemonStateURL)
        return try JSONDecoder().decode(DaemonState.self, from: data)
    }

    private func ensureProcessAlive(pid: Int32) throws {
        guard kill(pid, 0) == 0 else {
            throw LaunchError.daemonUnavailable
        }
    }

    static func makeSessionURL(
        sessionID: String,
        environmentValue: String? = {
            guard let rawValue = getenv("HAPPY_WEBAPP_URL") else {
                return nil
            }
            return String(validatingUTF8: rawValue)
        }()
    ) -> String {
        let trimmedValue = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLString = (trimmedValue?.isEmpty == false ? trimmedValue : nil)
            ?? "https://app.happy.engineering"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://app.happy.engineering")!
        return baseURL.appendingPathComponent("session").appendingPathComponent(sessionID).absoluteString
    }

    func terminateSession(sessionID: String) async throws {
        let state = try loadDaemonState()
        try ensureProcessAlive(pid: state.pid)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.httpPort)/stop-session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["sessionId": sessionID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LaunchError.daemonUnavailable
        }

        struct StopResponse: Decodable { let success: Bool }
        let result = try JSONDecoder().decode(StopResponse.self, from: data)
        guard httpResponse.statusCode == 200, result.success else {
            throw LaunchError.spawnFailed("Happy daemon 终止 Claude 会话失败")
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case display
    case mascot
    case sound
    case integration
    case remote
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcuts: return "快捷键"
        case .display: return "显示"
        case .mascot: return "宠物"
        case .sound: return "声音"
        case .integration: return "集成"
        case .remote: return "远程"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "系统与基础行为"
        case .shortcuts: return "全局展开与自定义"
        case .display: return "显示器与位置"
        case .mascot: return "客户端宠物与动作"
        case .sound: return "通知与提示音"
        case .integration: return "Hooks 与 IDE 扩展"
        case .remote: return "SSH 主机与远程转发"
        case .about: return "版本与更新"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command.square.fill"
        case .display: return "rectangle.on.rectangle"
        case .mascot: return "face.smiling.fill"
        case .sound: return "speaker.wave.2.fill"
        case .integration: return "link.circle.fill"
        case .remote: return "network.badge.shield.half.filled"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.12, green: 0.42, blue: 0.95)
        case .shortcuts: return Color(red: 0.25, green: 0.82, blue: 0.46)
        case .display: return Color(red: 0.46, green: 0.40, blue: 0.96)
        case .mascot: return Color(red: 0.91, green: 0.27, blue: 0.81)  // Pink
        case .sound: return Color(red: 0.22, green: 0.83, blue: 0.42)
        case .integration: return Color(red: 0.16, green: 0.76, blue: 0.72)
        case .remote: return Color(red: 0.95, green: 0.54, blue: 0.20)
        case .about: return Color(red: 0.17, green: 0.60, blue: 0.96)
        }
    }
}

struct NativeRuntimePreviewUnlockState: Equatable {
    private(set) var tapCount: Int = 0
    private(set) var isUnlocked: Bool = false
    let requiredTapCount: Int

    init(tapCount: Int = 0, isUnlocked: Bool = false, requiredTapCount: Int = 6) {
        self.tapCount = tapCount
        self.isUnlocked = isUnlocked
        self.requiredTapCount = requiredTapCount
    }

    mutating func registerTap(on category: SettingsCategory) {
        guard !isUnlocked else { return }

        if category == .general {
            tapCount += 1
            if tapCount >= requiredTapCount {
                isUnlocked = true
            }
        } else {
            tapCount = 0
        }
    }
}

@MainActor
final class SettingsPanelViewModel: ObservableObject {
    struct HookReinstallFeedback: Equatable {
        let message: String
        let isError: Bool
    }

    @Published var launchAtLogin = false
    @Published private(set) var hookInstallationStates: [String: Bool] = [:]
    @Published private(set) var ideExtensionInstallationStates: [String: Bool] = [:]
    @Published var accessibilityEnabled = false
    @Published var isExportingLogs = false
    @Published var logExportStatus = AppLocalization.string("导出最近 10 分钟的 Island 诊断日志与配置")
    @Published private(set) var reinstallingHookProfileID: String?
    @Published private(set) var hookReinstallFeedbacks: [String: HookReinstallFeedback] = [:]
    @Published private(set) var customHookInstallations: [HookInstaller.CustomHookInstallation] = []
    @Published var nativeClaudeRuntimeEnabled = FeatureFlags.nativeClaudeRuntime
    @Published var nativeCodexRuntimeEnabled = FeatureFlags.nativeCodexRuntime
    @Published var nativeRuntimeWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var nativeRuntimeStatusMessage: String?
    @Published var nativeRuntimeRemoteControlURL: String?
    @Published private(set) var nativeRuntimeLaunchingProvider: SessionProvider?
    @Published private(set) var nativeRuntimeActiveSessionIDs: [String: String] = [:]

    private var hookFeedbackClearTasks: [String: Task<Void, Never>] = [:]
    private let runtimeLauncher: any NativeRuntimeLaunching
    private let fileExists: @Sendable (String) -> Bool
    private let setFeatureFlagEnabled: @Sendable (Bool, SessionProvider) -> Void

    init(
        runtimeLauncher: (any NativeRuntimeLaunching)? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        setFeatureFlagEnabled: @escaping @Sendable (Bool, SessionProvider) -> Void = { enabled, provider in
            switch provider {
            case .claude:
                FeatureFlags.setEnabled(enabled, for: .nativeClaudeRuntime)
            case .codex:
                FeatureFlags.setEnabled(enabled, for: .nativeCodexRuntime)
            case .copilot:
                break
            }
        }
    ) {
        self.runtimeLauncher = runtimeLauncher ?? SharedRuntimeLauncher()
        self.fileExists = fileExists
        self.setFeatureFlagEnabled = setFeatureFlagEnabled
    }

    var visibleHookProfiles: [ManagedHookClientProfile] {
        let profiles = ClientProfileRegistry.managedHookProfiles.filter { profile in
            profile.alwaysVisibleInSettings
                || ClientAppLocator.isInstalled(bundleIdentifiers: profile.localAppBundleIdentifiers)
        }

        return profiles.filter { $0.id != "gemini-hooks" }
            + profiles.filter { $0.id == "gemini-hooks" }
    }

    var visibleIDEExtensionProfiles: [ManagedIDEExtensionProfile] {
        ClientProfileRegistry.ideExtensionProfiles.filter { profile in
            profile.showsInSettings
                && (
                    profile.alwaysVisibleInSettings
                || ClientAppLocator.isInstalled(bundleIdentifiers: profile.localAppBundleIdentifiers)
                )
        }
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshHookInstallationStates()
        refreshIDEExtensionInstallationStates()
        refreshCustomHookInstallations()
        accessibilityEnabled = AXIsProcessTrusted()
        ScreenSelector.shared.refreshScreens()
        SoundPackCatalog.shared.refresh()
        refreshLocalizedState()
        nativeClaudeRuntimeEnabled = FeatureFlags.nativeClaudeRuntime
        nativeCodexRuntimeEnabled = FeatureFlags.nativeCodexRuntime
    }

    func refreshLocalizedState() {
        guard !isExportingLogs else { return }
        logExportStatus = AppLocalization.string("导出最近 10 分钟的 Island 诊断日志与配置")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func isHookInstalled(_ profile: ManagedHookClientProfile) -> Bool {
        hookInstallationStates[profile.id] ?? false
    }

    func isIDEExtensionInstalled(_ profile: ManagedIDEExtensionProfile) -> Bool {
        ideExtensionInstallationStates[profile.id] ?? false
    }

    func installHooks(for profile: ManagedHookClientProfile) {
        HookInstaller.install(profile)
        refreshHookInstallationStates()
    }

    func reinstallHooks(for profile: ManagedHookClientProfile) {
        guard reinstallingHookProfileID == nil else { return }

        hookFeedbackClearTasks[profile.id]?.cancel()
        hookFeedbackClearTasks[profile.id] = nil
        hookReinstallFeedbacks[profile.id] = nil
        reinstallingHookProfileID = profile.id

        Task {
            await Task.yield()

            HookInstaller.reinstall(profile)
            let didInstall = HookInstaller.isInstalled(profile)

            try? await Task.sleep(nanoseconds: 450_000_000)

            refreshHookInstallationStates()
            reinstallingHookProfileID = nil
            hookReinstallFeedbacks[profile.id] = HookReinstallFeedback(
                message: didInstall
                    ? AppLocalization.string("重新安装成功")
                    : AppLocalization.string("重新安装失败，请稍后重试"),
                isError: !didInstall
            )

            hookFeedbackClearTasks[profile.id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                hookReinstallFeedbacks[profile.id] = nil
                hookFeedbackClearTasks[profile.id] = nil
            }
        }
    }

    func uninstallHooks(for profile: ManagedHookClientProfile) {
        HookInstaller.uninstall(profile)
        refreshHookInstallationStates()
    }

    func installCustomHook(profileID: String, directoryPath: String) {
        HookInstaller.installCustom(profileID: profileID, directoryPath: directoryPath)
        refreshCustomHookInstallations()
    }

    func uninstallCustomHook(id: String) {
        HookInstaller.uninstallCustom(id: id)
        refreshCustomHookInstallations()
    }

    func refreshCustomHookInstallations() {
        customHookInstallations = HookInstaller.customInstallations()
    }

    func openHookConfigurationDirectory(for profile: ManagedHookClientProfile) {
        guard let directoryURL = hookConfigurationDirectoryURL(for: profile) else {
            return
        }

        NSWorkspace.shared.open(directoryURL)
    }

    func installIDEExtension(for profile: ManagedIDEExtensionProfile) {
        IDEExtensionInstaller.install(profile)
        refreshIDEExtensionInstallationStates()
    }

    func reinstallIDEExtension(for profile: ManagedIDEExtensionProfile) {
        IDEExtensionInstaller.reinstall(profile)
        refreshIDEExtensionInstallationStates()
    }

    func uninstallIDEExtension(for profile: ManagedIDEExtensionProfile) {
        IDEExtensionInstaller.uninstall(profile)
        refreshIDEExtensionInstallationStates()
    }

    func isReinstallingHooks(for profile: ManagedHookClientProfile) -> Bool {
        reinstallingHookProfileID == profile.id
    }

    func hookReinstallFeedback(for profile: ManagedHookClientProfile) -> HookReinstallFeedback? {
        hookReinstallFeedbacks[profile.id]
    }

    func authorizeIDEExtension(for profile: ManagedIDEExtensionProfile) {
        _ = IDEExtensionInstaller.authorize(profile)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func setNativeRuntimeEnabled(_ enabled: Bool, for provider: SessionProvider) {
        setFeatureFlagEnabled(enabled, provider)
        switch provider {
        case .claude:
            nativeClaudeRuntimeEnabled = enabled
        case .codex:
            nativeCodexRuntimeEnabled = enabled
        case .copilot:
            break
        }
    }

    func selectNativeRuntimeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: nativeRuntimeWorkingDirectory)
        panel.message = "选择 Native Runtime 工作目录"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            nativeRuntimeWorkingDirectory = url.path
        }
    }

    func startNativeRuntimeSession(provider: SessionProvider) {
        guard nativeRuntimeLaunchingProvider == nil else { return }
        guard activeNativeRuntimeSessionID(for: provider) == nil else { return }

        let cwd = nativeRuntimeWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else {
            nativeRuntimeStatusMessage = "请先选择工作目录"
            nativeRuntimeRemoteControlURL = nil
            return
        }

        guard fileExists(cwd) else {
            nativeRuntimeStatusMessage = "目录不存在：\(cwd)"
            nativeRuntimeRemoteControlURL = nil
            return
        }

        nativeRuntimeRemoteControlURL = nil
        nativeRuntimeLaunchingProvider = provider

        Task {
            do {
                let launchResult = try await runtimeLauncher.startSession(provider: provider, cwd: cwd)
                await MainActor.run {
                    nativeRuntimeLaunchingProvider = nil
                    if let sessionID = launchResult.sessionID, !sessionID.isEmpty {
                        nativeRuntimeActiveSessionIDs[provider.rawValue] = sessionID
                    }
                    nativeRuntimeRemoteControlURL = launchResult.remoteControlURL
                    nativeRuntimeStatusMessage = launchResult.statusMessage ?? "\(provider.displayName) Native Runtime 已启动"
                }
            } catch {
                await MainActor.run {
                    nativeRuntimeLaunchingProvider = nil
                    nativeRuntimeRemoteControlURL = nil
                    nativeRuntimeStatusMessage = error.localizedDescription
                }
            }
        }
    }

    func terminateNativeRuntimeSession(provider: SessionProvider) {
        guard nativeRuntimeLaunchingProvider == nil,
              let sessionID = activeNativeRuntimeSessionID(for: provider),
              !sessionID.isEmpty else {
            return
        }

        nativeRuntimeLaunchingProvider = provider

        Task {
            do {
                try await runtimeLauncher.terminateSession(provider: provider, sessionID: sessionID)
                await MainActor.run {
                    nativeRuntimeLaunchingProvider = nil
                    nativeRuntimeActiveSessionIDs[provider.rawValue] = nil
                    if provider == .claude {
                        nativeRuntimeRemoteControlURL = nil
                    }
                    nativeRuntimeStatusMessage = "\(provider.displayName) Native Runtime 已终止"
                }
            } catch {
                await MainActor.run {
                    nativeRuntimeLaunchingProvider = nil
                    nativeRuntimeStatusMessage = error.localizedDescription
                }
            }
        }
    }

    func isLaunchingNativeRuntime(for provider: SessionProvider) -> Bool {
        nativeRuntimeLaunchingProvider == provider
    }

    func activeNativeRuntimeSessionID(for provider: SessionProvider) -> String? {
        nativeRuntimeActiveSessionIDs[provider.rawValue]
    }

    func exportLogs() {
        guard !isExportingLogs else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "PingIsland-Diagnostics-\(Self.archiveTimestamp()).zip"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExportingLogs = true
        logExportStatus = AppLocalization.string("正在导出日志…")

        Task {
            do {
                let result = try await DiagnosticsExporter.shared.exportArchive(to: destinationURL)
                await MainActor.run {
                    if result.warnings.isEmpty {
                        logExportStatus = AppLocalization.format(
                            "已导出到 %@",
                            result.archiveURL.lastPathComponent
                        )
                    } else {
                        logExportStatus = AppLocalization.format(
                            "已导出，附带 %lld 条警告",
                            result.warnings.count
                        )
                    }
                    isExportingLogs = false
                }
            } catch {
                await MainActor.run {
                    logExportStatus = AppLocalization.format(
                        "导出失败：%@",
                        error.localizedDescription
                    )
                    isExportingLogs = false
                }
            }
        }
    }

    private static func archiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func refreshHookInstallationStates() {
        hookInstallationStates = ClientProfileRegistry.managedHookProfiles.reduce(into: [:]) { result, profile in
            result[profile.id] = HookInstaller.isInstalled(profile)
        }
    }

    private func refreshIDEExtensionInstallationStates() {
        ideExtensionInstallationStates = ClientProfileRegistry.ideExtensionProfiles.reduce(into: [:]) { result, profile in
            result[profile.id] = IDEExtensionInstaller.isInstalled(profile)
        }
    }

    private func hookConfigurationDirectoryURL(for profile: ManagedHookClientProfile) -> URL? {
        let fileManager = FileManager.default

        if let existingConfiguration = profile.configurationURLs.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existingConfiguration.deletingLastPathComponent()
        }

        if let existingDirectory = profile.configurationURLs
            .map({ $0.deletingLastPathComponent() })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existingDirectory
        }

        return profile.primaryConfigurationURL.deletingLastPathComponent()
    }
}

private enum SettingsPanelPresentation {
    case window
    case popover
}

private struct SettingsSidebarSection: Identifiable {
    let title: String?
    let categories: [SettingsCategory]

    var id: String { title ?? categories.map(\.rawValue).joined(separator: "-") }
}

private struct SettingsGlassSurface: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private enum SettingsPanelMetrics {
    static let windowSize = AppSettings.defaultSettingsWindowSize
    static let windowMinSize = AppSettings.minimumSettingsWindowSize
    static let windowMaxSize = AppSettings.maximumSettingsWindowSize
    static let popoverSize = CGSize(width: 760, height: 620)
    static let windowSidebarWidth: CGFloat = 236
    static let popoverSidebarWidth: CGFloat = 212
    static let windowContentTopInset: CGFloat = 0
    static let popoverContentTopInset: CGFloat = 0
    static let outerPadding: CGFloat = 0
}

private struct SettingsPanelContentView: View {
    let presentation: SettingsPanelPresentation
    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    @AppStorage("settings.nativeRuntimePreviewUnlocked") private var nativeRuntimePreviewUnlocked = false

    @StateObject private var viewModel = SettingsPanelViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundPacks = SoundPackCatalog.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var remoteManager = RemoteConnectorManager.shared
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var nativeRuntimePreviewUnlockState = NativeRuntimePreviewUnlockState()
    @State private var pendingHookReinstallProfile: ManagedHookClientProfile?
    @State private var showingCustomHookInstallSheet = false
    @State private var showingRemoteHostSheet = false
    @State private var remotePasswordPromptRequest: RemotePasswordPromptRequest?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, contentTopInset)
            .padding(.horizontal, SettingsPanelMetrics.outerPadding)
            .padding(.bottom, SettingsPanelMetrics.outerPadding)
            .frame(
                minWidth: minimumWidth,
                idealWidth: idealWidth,
                maxWidth: maximumWidth,
                minHeight: minimumHeight,
                idealHeight: idealHeight,
                maxHeight: maximumHeight,
                alignment: .topLeading
            )
        }
        .background(panelBackgroundColor)
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 30, y: 18)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.refresh()
            ensureValidSelectedSoundPack()
            nativeRuntimePreviewUnlockState = NativeRuntimePreviewUnlockState(
                tapCount: nativeRuntimePreviewUnlockState.tapCount,
                isUnlocked: nativeRuntimePreviewUnlocked
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh()
            ensureValidSelectedSoundPack()
        }
        .onChange(of: soundPacks.availablePacks) { _, _ in
            ensureValidSelectedSoundPack()
        }
        .onChange(of: settings.appLanguage) { _, _ in
            viewModel.refreshLocalizedState()
        }
        .alert(
            "重新安装 Hooks？",
            isPresented: Binding(
                get: { pendingHookReinstallProfile != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingHookReinstallProfile = nil
                    }
                }
            ),
            presenting: pendingHookReinstallProfile
        ) { profile in
            Button("取消", role: .cancel) {}
            Button("重新安装") {
                viewModel.reinstallHooks(for: profile)
                pendingHookReinstallProfile = nil
            }
        } message: { profile in
            Text(verbatim: AppLocalization.format(profile.reinstallDescriptionFormat, profile.title))
        }
        .sheet(isPresented: $showingCustomHookInstallSheet) {
            CustomHookInstallSheet(viewModel: viewModel) {
                showingCustomHookInstallSheet = false
            }
        }
        .sheet(isPresented: $showingRemoteHostSheet) {
            AddRemoteHostSheet(remoteManager: remoteManager) {
                showingRemoteHostSheet = false
            }
        }
        .sheet(item: $remotePasswordPromptRequest) { request in
            RemotePasswordPromptSheet(request: request) { password in
                remotePasswordPromptRequest = nil
                switch request.action {
                case .connect:
                    remoteManager.connect(endpointID: request.endpoint.id, password: password)
                case .uninstallBridge:
                    remoteManager.uninstallBridge(endpointID: request.endpoint.id, password: password)
                }
            } onDismiss: {
                remotePasswordPromptRequest = nil
            }
        }
    }

    private var minimumWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMinSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var maximumWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMaxSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var idealWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var minimumHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMinSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var maximumHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMaxSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var idealHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var sidebarWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSidebarWidth
        case .popover:
            return SettingsPanelMetrics.popoverSidebarWidth
        }
    }

    private var panelBackgroundColor: Color {
        .clear
    }

    private var contentTopInset: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowContentTopInset
        case .popover:
            return SettingsPanelMetrics.popoverContentTopInset
        }
    }

    private var sidebarSections: [SettingsSidebarSection] {
        [
            SettingsSidebarSection(
                title: nil,
                categories: [.general, .shortcuts, .display, .mascot, .sound, .integration, .remote, .about]
            )
        ]
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if presentation == .window {
                    sidebarWindowControls
                }

                ForEach(sidebarSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = section.title {
                            Text(appLocalized: title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.32))
                                .padding(.horizontal, 12)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(section.categories) { category in
                                Button {
                                    nativeRuntimePreviewUnlockState.registerTap(on: category)
                                    if nativeRuntimePreviewUnlockState.isUnlocked {
                                        nativeRuntimePreviewUnlocked = true
                                    }
                                    selectedCategory = category
                                } label: {
                                    SidebarItemView(
                                        category: category,
                                        isSelected: selectedCategory == category
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("settings.sidebar.\(category.rawValue)")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .padding(8)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
                .fill(Color.white.opacity(0.055))
                .overlay {
                    SettingsGlassSurface(material: .sidebar, blendingMode: .withinWindow)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 24,
                                bottomLeadingRadius: 24,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0,
                                style: .continuous
                            )
                        )
                        .opacity(0.94)
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.04),
                            Color.black.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 24,
                            bottomLeadingRadius: 24,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    )
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 120, height: 120)
                        .blur(radius: 36)
                        .offset(x: 28, y: -26)
                }
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 24, y: 14)
    }

    private var sidebarWindowControls: some View {
        HStack(spacing: 10) {
            WindowControlButton(color: Color(red: 1.0, green: 0.37, blue: 0.36)) {
                if let onClose {
                    onClose()
                } else {
                    currentWindow?.performClose(nil)
                }
            }

            WindowControlButton(color: Color(red: 1.0, green: 0.74, blue: 0.18)) {
                if let onMinimize {
                    onMinimize()
                } else {
                    currentWindow?.miniaturize(nil)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                switch currentCategory {
                case .general:
                    generalContent
                case .shortcuts:
                    shortcutsContent
                case .display:
                    displayContent
                case .mascot:
                    mascotContent
                case .sound:
                    soundContent
                case .integration:
                    integrationContent
                case .remote:
                    remoteContent
                case .about:
                    aboutContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(currentCategory)
        .accessibilityIdentifier("settings.detail.\(currentCategory.rawValue)")
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 26,
                topTrailingRadius: 26,
                style: .continuous
            )
                .fill(Color.white.opacity(0.035))
                .overlay {
                    SettingsGlassSurface(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 26,
                                topTrailingRadius: 26,
                                style: .continuous
                            )
                        )
                        .opacity(0.96)
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.11),
                            Color.white.opacity(0.03),
                            Color.black.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 26,
                            topTrailingRadius: 26,
                            style: .continuous
                        )
                    )
                }
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 26,
                topTrailingRadius: 26,
                style: .continuous
            )
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 24, y: 14)
    }

    private var currentCategory: SettingsCategory {
        selectedCategory ?? .general
    }

    private var currentWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "系统") {
                SettingsInfoLine(
                    title: "语言",
                    subtitle: "默认跟随系统语言，也可以单独固定为简体中文或 English。"
                ) {
                    appLanguagePicker
                }
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "登录时打开",
                    subtitle: "启动 macOS 后自动显示 Island",
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
                SettingsLineDivider()

                SettingsInfoLine(title: "显示器", subtitle: "选择 Island 所在显示器") {
                    screenPicker
                }
            }

            SettingsSectionCard(title: "行为") {
                SettingsToggleLine(
                    title: "全屏时隐藏",
                    subtitle: "无刘海屏会在全屏时收起到顶部中央触发区；刘海屏会收缩为空白系统刘海，hover 后再展示 Island 内容",
                    isOn: $settings.hideInFullscreen
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "无活跃会话时自动隐藏",
                    subtitle: "当前没有正在运行或需要处理的会话时，自动隐藏 Island",
                    isOn: $settings.autoHideWhenIdle
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "智能抑制",
                    subtitle: "当前正在看终端时，不自动弹出通知面板",
                    isOn: $settings.smartSuppression
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "完成时自动展开会话",
                    subtitle: "消息完成后自动弹出结果面板；关闭后只保留刘海状态提示和提示音",
                    isOn: $settings.autoOpenCompletionPanel
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "上下文压缩时自动展开提醒",
                    subtitle: "上下文压缩后自动弹出提示；关闭后只保留刘海状态提示和提示音",
                    isOn: $settings.autoOpenCompactedNotificationPanel
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "鼠标离开时自动收起",
                    subtitle: "hover 展开的预览面板会在鼠标离开后自动关闭",
                    isOn: $settings.autoCollapseOnLeave
                )
            }

            SettingsSectionCard(title: "应用") {
                SettingsActionLine(
                    title: "退出应用",
                    subtitle: "立即关闭 Island"
                ) {
                    NSApplication.shared.terminate(nil)
                } accessory: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
            }
        }
    }

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "显示器") {
                SettingsInfoLine(
                    title: "当前显示器",
                    subtitle: "切换后会重新挂载 Island 窗口位置"
                ) {
                    screenPicker
                }
                SettingsLineDivider()

                if let selectedScreen = screenSelector.selectedScreen {
                    SettingsValueLine(
                        title: "当前输出",
                        value: selectedScreen.localizedName
                    )
                    SettingsLineDivider()
                }

                SettingsValueLine(
                    title: "选择策略",
                    value: screenSelector.selectionMode == .automatic
                        ? AppLocalization.string("自动")
                        : AppLocalization.string("手动指定")
                )
            }

            SettingsSectionCard(title: "面板") {
                SettingsToggleLine(
                    title: "显示代理活动详情",
                    subtitle: "在会话列表和 hover 预览里展示工具调用、思考与更细的状态描述",
                    isOn: $settings.showAgentDetail
                )
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "子 Agent 显示",
                    subtitle: "控制主列表里是否展示子 Agent 消息项；当前会影响 Codex、Qoder 等带子会话的客户端"
                ) {
                    SubagentVisibilityPicker(
                        mode: Binding(
                            get: { settings.subagentVisibilityMode },
                            set: { settings.subagentVisibilityMode = $0 }
                        )
                    )
                }
                SettingsLineDivider()

                SettingsSliderLine(
                    title: "内容字号",
                    subtitle: "调整会话列表、hover 预览和结果视图的文字大小",
                    value: $settings.contentFontSize,
                    range: 11...17,
                    step: 1,
                    format: { "\($0.formatted(.number.precision(.fractionLength(0)))) pt" }
                )
                SettingsLineDivider()

                SettingsSliderLine(
                    title: "最大面板高度",
                    subtitle: "控制聊天面板和 hover 预览的最大展开高度",
                    value: $settings.maxPanelHeight,
                    range: 480...700,
                    step: 10,
                    format: { "\($0.formatted(.number.precision(.fractionLength(0)))) pt" }
                )
                SettingsLineDivider()

                NotchDisplayModeSelector(mode: $settings.notchDisplayMode)
            }

            SettingsSectionCard(title: "客户端形象") {
                SettingsValueLine(
                    title: "切换方式",
                    value: settings.customizedMascotClientCount == 0
                        ? AppLocalization.string("按客户端自动切换")
                        : AppLocalization.string("按客户端切换 + 自定义覆盖")
                )

                SettingsLineDivider()

                SettingsInfoLine(
                    title: "当前策略",
                    subtitle: "Claude Code、Codex、Gemini CLI、OpenCode、Cursor、Qoder、CodeBuddy、WorkBuddy、Trae 等客户端会显示各自独立的宠物形象与动作，并支持逐客户端改成别的宠物。"
                ) {
                    Text(
                        settings.customizedMascotClientCount == 0
                            ? AppLocalization.string("自动")
                            : AppLocalization.format("已自定义 %lld", settings.customizedMascotClientCount)
                    )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
            }
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "全局快捷键") {
                ShortcutSettingsLine(
                    action: .openActiveSession,
                    shortcut: shortcutBinding(for: .openActiveSession)
                )
                SettingsLineDivider()
                ShortcutSettingsLine(
                    action: .openSessionList,
                    shortcut: shortcutBinding(for: .openSessionList)
                )
            }

            SettingsSectionCard(title: "说明") {
                SettingsInfoLine(
                    title: "默认键位",
                    subtitle: "默认使用 Option + J 打开活跃会话，Option + L 展开会话列表。"
                ) {
                    EmptyView()
                }
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "录制规则",
                    subtitle: "在录制状态下直接按新组合键即可。建议优先使用包含 Option 的组合，尽量避开常见系统快捷键。"
                ) {
                    EmptyView()
                }
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "列表键盘操作",
                    subtitle: "呼出会话列表后，可用 ↑ / ↓ 选中会话，按 Enter 打开对应窗口。"
                ) {
                    EmptyView()
                }
            }
        }
    }

    private var mascotContent: some View {
        MascotSettingsView()
    }

    private var soundContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "通知") {
                SettingsToggleLine(
                    title: "启用提示音",
                    subtitle: "不同阶段可分别播放不同音效，适用于 Claude、Codex 等会话。",
                    isOn: $settings.soundEnabled
                )
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "声音模式",
                    subtitle: "系统音适合快速配置；主题包兼容 OpenPeon / CESP 格式。"
                ) {
                    soundThemeModePicker
                }
                SettingsLineDivider()

                SettingsSliderLine(
                    title: "音量",
                    subtitle: "控制 Island 播放提示音时的音量大小",
                    value: $settings.soundVolume,
                    range: 0...1,
                    step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
            }

            if settings.soundThemeMode == .builtIn {
                SettingsSectionCard(title: "阶段音效") {
                    ForEach(NotificationEvent.allCases) { event in
                        SoundEventSettingsLine(
                            event: event,
                            isEnabled: soundEnabledBinding(for: event),
                            selectedSound: soundBinding(for: event)
                        ) {
                            AppSettings.playSound(for: event)
                        }
                    }
                }
            } else if settings.soundThemeMode == .island8Bit {
                SettingsSectionCard(title: "客户端启动音") {
                    SettingsActionLine(
                        title: "固定启动音",
                        subtitle: "使用内置 8-bit 启动旋律。应用启动时会自动播放，也可以在这里试听。"
                    ) {
                        AppSettings.playClientStartupSound()
                    } accessory: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))
                    }
                }

                SettingsSectionCard(title: "固定映射") {
                    ForEach(NotificationEvent.allCases) { event in
                        BundledThemeEventLine(
                            event: event,
                            soundLabel: event.island8BitSound.label,
                            isEnabled: Binding(
                                get: { AppSettings.isSoundEnabled(for: event) },
                                set: { AppSettings.setSoundEnabled($0, for: event) }
                            )
                        ) {
                            AppSettings.playSound(for: event)
                        }
                    }
                }
            } else {
                SettingsSectionCard(title: "主题音效包") {
                    SoundPackSourceInfoLine {
                        soundPackPicker
                    }

                    SoundPackImportActionLine {
                        if soundPacks.importPack(), soundPacks.pack(for: settings.selectedSoundPackPath) == nil {
                            settings.selectedSoundPackPath = soundPacks.availablePacks.first?.rootURL.path ?? ""
                        }
                    } accessory: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))
                    }

                    if soundPacks.availablePacks.isEmpty {
                        SettingsValueLine(title: "可用主题包", value: "未发现")
                    } else {
                        SettingsValueLine(title: "可用主题包", value: "\(soundPacks.availablePacks.count)")
                    }
                }

                SettingsSectionCard(title: "阶段映射") {
                    ForEach(NotificationEvent.allCases) { event in
                        SoundPackEventLine(
                            event: event,
                            isEnabled: Binding(
                                get: { AppSettings.isSoundEnabled(for: event) },
                                set: { AppSettings.setSoundEnabled($0, for: event) }
                            )
                        ) {
                            AppSettings.playSound(for: event)
                        }
                    }
                }
            }
        }
    }

    private var integrationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            let hookProfiles = viewModel.visibleHookProfiles
            if !hookProfiles.isEmpty {
                SettingsSectionCard(title: "Hooks 管理") {
                    let profiles = hookProfiles
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        HookManagementLine(
                            profile: profile,
                            isInstalled: viewModel.isHookInstalled(profile),
                            isReinstalling: viewModel.isReinstallingHooks(for: profile),
                            reinstallFeedback: viewModel.hookReinstallFeedback(for: profile),
                            installAction: { viewModel.installHooks(for: profile) },
                            openConfigurationDirectoryAction: {
                                viewModel.openHookConfigurationDirectory(for: profile)
                            },
                            reinstallAction: { pendingHookReinstallProfile = profile },
                            uninstallAction: { viewModel.uninstallHooks(for: profile) }
                        )

                        if index < profiles.count - 1
                            || !viewModel.customHookInstallations.isEmpty {
                            SettingsLineDivider()
                        }
                    }

                    let customInstallations = viewModel.customHookInstallations
                    ForEach(Array(customInstallations.enumerated()), id: \.element.id) { index, installation in
                        CustomHookInstallationLine(
                            installation: installation,
                            uninstallAction: { viewModel.uninstallCustomHook(id: installation.id) }
                        )

                        if index < customInstallations.count - 1 {
                            SettingsLineDivider()
                        }
                    }

                    SettingsLineDivider()

                    HStack {
                        Spacer()
                        Button(action: { showingCustomHookInstallSheet = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(appLocalized: "添加自定义配置")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }

            let ideProfiles = viewModel.visibleIDEExtensionProfiles
            if !ideProfiles.isEmpty {
                SettingsSectionCard(title: "IDE 扩展") {
                    let profiles = ideProfiles
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        IDEExtensionManagementLine(
                            profile: profile,
                            isInstalled: viewModel.isIDEExtensionInstalled(profile),
                            installAction: { viewModel.installIDEExtension(for: profile) },
                            reinstallAction: { viewModel.reinstallIDEExtension(for: profile) },
                            authorizeAction: { viewModel.authorizeIDEExtension(for: profile) },
                            uninstallAction: { viewModel.uninstallIDEExtension(for: profile) }
                        )

                        if index < profiles.count - 1 {
                            SettingsLineDivider()
                        }
                    }
                }
            }

            SettingsSectionCard(title: "系统权限") {
                SettingsStatusLine(
                    title: "辅助功能",
                    subtitle: viewModel.accessibilityEnabled ? "已授权，可进行窗口聚焦与前台检测" : "未授权，部分自动聚焦能力不可用",
                    status: viewModel.accessibilityEnabled ? "已开启" : "待开启",
                    statusColor: viewModel.accessibilityEnabled ? TerminalColors.green : TerminalColors.amber
                ) {
                    if !viewModel.accessibilityEnabled {
                        viewModel.openAccessibilitySettings()
                    }
                }
            }

            if nativeRuntimePreviewUnlocked {
                SettingsSectionCard(title: "Native Runtime Preview") {
                    NativeRuntimePreviewSection(viewModel: viewModel)
                }
            }
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "应用信息") {
                SettingsValueLine(title: "版本", value: appVersion)
                SettingsLineDivider()
                SettingsValueLine(title: "构建", value: appBuild)
                SettingsLineDivider()
                SettingsValueLine(title: "安装时间", value: versionMetadata)
                SettingsLineDivider()
                SettingsValueLine(title: "之前版本", value: previousVersion)
            }

            SettingsSectionCard(title: "更新") {
                SettingsActionLine(
                    title: updateTitle,
                    subtitle: updateSubtitle
                ) {
                    handleUpdateAction()
                } accessory: {
                    updateAccessory
                }

                if updateManager.canShowReleaseNotes {
                    SettingsLineDivider()

                    SettingsActionLine(
                        title: updateManager.releaseNotesActionTitle,
                        subtitle: updateManager.releaseNotesActionSubtitle
                    ) {
                        updateManager.showReleaseNotes()
                    } accessory: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }

            SettingsSectionCard(title: "链接") {
                SettingsActionLine(title: "GitHub", subtitle: "打开 Issues 页面反馈问题") {
                    if let url = URL(string: "https://github.com/erha19/ping-island/issues") {
                        NSWorkspace.shared.open(url)
                    }
                } accessory: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }

                SettingsLineDivider()

                SettingsActionLine(
                    title: "导出诊断日志",
                    subtitle: viewModel.logExportStatus
                ) {
                    viewModel.exportLogs()
                } accessory: {
                    if viewModel.isExportingLogs {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.8))
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private var remoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "远程主机") {
                if remoteManager.endpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(appLocalized: "还没有添加任何远程主机")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(appLocalized: "添加后，Island 会通过 SSH 安装远程 bridge、改写远程 hooks，并建立一个双向转发通道。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                } else {
                    let endpoints = remoteManager.endpoints
                    ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        RemoteHostManagementLine(
                            endpoint: endpoint,
                            runtimeState: remoteManager.runtimeStates[endpoint.id] ?? RemoteEndpointRuntimeState(),
                            hasReusablePassword: remoteManager.hasReusablePassword(for: endpoint.id),
                            connectAction: { password in
                                remoteManager.connect(endpointID: endpoint.id, password: password)
                            },
                            requestConnectPasswordAction: {
                                remotePasswordPromptRequest = RemotePasswordPromptRequest(
                                    endpoint: endpoint,
                                    action: .connect
                                )
                            },
                            disconnectAction: { remoteManager.disconnect(endpointID: endpoint.id) },
                            uninstallAction: { password in
                                remoteManager.uninstallBridge(endpointID: endpoint.id, password: password)
                            },
                            requestUninstallPasswordAction: {
                                remotePasswordPromptRequest = RemotePasswordPromptRequest(
                                    endpoint: endpoint,
                                    action: .uninstallBridge
                                )
                            },
                            removeAction: { remoteManager.removeEndpoint(id: endpoint.id) }
                        )

                        if index < endpoints.count - 1 {
                            SettingsLineDivider()
                        }
                    }
                }

                SettingsLineDivider()

                HStack {
                    Spacer()
                    Button(action: { showingRemoteHostSheet = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(appLocalized: "添加远程主机")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(appLocalized: "说明")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 10) {
                    Text(appLocalized: "添加远程主机后，Island 会通过 SSH 检查环境、安装远程 bridge，并配置 Hooks。")
                    Text(appLocalized: "连接成功后，远程会话会回传到本机显示；如果密码连接失败，需要重新输入密码。")
                    Text(appLocalized: "如果不再需要远端集成，可在这里直接卸载 bridge；这会删除远端 `~/.ping-island` 并撤回 Island 托管的 hooks。")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var screenPicker: some View {
        Picker("显示器", selection: screenSelectionBinding) {
            Text(appLocalized: "自动").tag("automatic")
            ForEach(screenSelector.availableScreens, id: \.self) { screen in
                Text(screen.localizedName).tag(screenToken(for: screen))
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
    }

    private var soundThemeModePicker: some View {
        Picker("声音模式", selection: $settings.soundThemeMode) {
            ForEach(SoundThemeMode.allCases) { mode in
                Text(appLocalized: mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
    }

    private var appLanguagePicker: some View {
        Picker("语言", selection: $settings.appLanguage) {
            ForEach(AppLanguage.allCases) { language in
                Text(appLocalized: language.title).tag(language)
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
    }

    private var soundPackPicker: some View {
        Picker("主题包", selection: $settings.selectedSoundPackPath) {
            if soundPacks.availablePacks.isEmpty {
                Text(appLocalized: "未发现").tag("")
            } else {
                ForEach(soundPacks.availablePacks) { pack in
                    Text(pack.displayName).tag(pack.rootURL.path)
                }
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 204)
    }

    private var screenSelectionBinding: Binding<String> {
        Binding(
            get: {
                if screenSelector.selectionMode == .automatic {
                    return "automatic"
                }
                if let selected = screenSelector.selectedScreen {
                    return screenToken(for: selected)
                }
                return "automatic"
            },
            set: { token in
                if token == "automatic" {
                    screenSelector.selectAutomatic()
                } else if let screen = screenSelector.availableScreens.first(where: { screenToken(for: $0) == token }) {
                    screenSelector.selectScreen(screen)
                }
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            }
        )
    }

    private func soundEnabledBinding(for event: NotificationEvent) -> Binding<Bool> {
        switch event {
        case .processingStarted:
            return $settings.processingStartSoundEnabled
        case .attentionRequired:
            return $settings.attentionRequiredSoundEnabled
        case .taskCompleted:
            return $settings.taskCompletedSoundEnabled
        case .taskError:
            return $settings.taskErrorSoundEnabled
        case .resourceLimit:
            return $settings.resourceLimitSoundEnabled
        }
    }

    private func shortcutBinding(for action: GlobalShortcutAction) -> Binding<GlobalShortcut?> {
        Binding(
            get: { settings.shortcut(for: action) },
            set: { settings.setShortcut($0, for: action) }
        )
    }

    private func soundBinding(for event: NotificationEvent) -> Binding<NotificationSound> {
        switch event {
        case .processingStarted:
            return $settings.processingStartSound
        case .attentionRequired:
            return $settings.attentionRequiredSound
        case .taskCompleted:
            return $settings.taskCompletedSound
        case .taskError:
            return $settings.taskErrorSound
        case .resourceLimit:
            return $settings.resourceLimitSound
        }
    }

    private func screenToken(for screen: NSScreen) -> String {
        let identifier = ScreenIdentifier(screen: screen)
        return "\(identifier.displayID ?? 0)-\(identifier.localizedName)"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var versionMetadata: String {
        guard let metadata = HookInstaller.getVersionMetadata(),
              let installedAt = metadata["installedAt"] as? String else {
            return AppLocalization.string("首次安装")
        }

        // Format the date
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: installedAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return installedAt
    }

    private var previousVersion: String {
        guard let metadata = HookInstaller.getVersionMetadata(),
              let previous = metadata["previousVersion"] as? String,
              !previous.isEmpty else {
            return AppLocalization.string("无")
        }
        return previous
    }

    private var updateTitle: String {
        switch updateManager.state {
        case .idle, .upToDate:
            return AppLocalization.string("检查更新")
        case .checking:
            return AppLocalization.string("检查中...")
        case .found, .downloading, .extracting, .readyToInstall, .installing:
            return AppLocalization.string("静默更新中")
        case .error:
            return AppLocalization.string("重试更新")
        }
    }

    private var updateSubtitle: String {
        switch updateManager.state {
        case .idle:
            return updateManager.isConfigured
                ? AppLocalization.string("启动时和空闲时自动静默更新")
                : updateManager.configurationStatus.message
        case .upToDate:
            return AppLocalization.string("当前已经是最新版本")
        case .checking:
            return AppLocalization.string("正在后台检查更新")
        case .found(let version, _):
            return AppLocalization.format("发现新版本 v%@，将静默下载并安装", version)
        case .downloading:
            return AppLocalization.string("正在后台下载更新")
        case .extracting:
            return AppLocalization.string("正在准备安装更新")
        case .readyToInstall(let version):
            return AppLocalization.format("v%@ 已就绪，空闲时自动重启安装", version)
        case .installing:
            return AppLocalization.string("正在静默安装并重启")
        case .error:
            return AppLocalization.string("后台更新失败，点击后重新检查")
        }
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updateManager.state {
        case .checking, .downloading, .extracting, .installing:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Text(appLocalized: "最新")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .found(let version, _), .readyToInstall(let version):
            Text("v\(version)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .idle, .error:
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func handleUpdateAction() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .checking, .found, .downloading, .extracting, .readyToInstall, .installing:
            break
        }
    }

    private func ensureValidSelectedSoundPack() {
        guard settings.soundThemeMode == .soundPack else { return }
        if soundPacks.availablePacks.isEmpty {
            settings.selectedSoundPackPath = ""
        } else if soundPacks.pack(for: settings.selectedSoundPackPath) == nil {
            settings.selectedSoundPackPath = soundPacks.availablePacks.first?.rootURL.path ?? ""
        }
    }
}

struct SettingsWindowView: View {
    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil

    var body: some View {
        AppLocalizedRootView {
            SettingsPanelContentView(
                presentation: .window,
                onClose: onClose,
                onMinimize: onMinimize
            )
            .accessibilityIdentifier("settings.root")
        }
    }
}

struct NotchSettingsPopoverView: View {
    var body: some View {
        AppLocalizedRootView {
            SettingsPanelContentView(presentation: .popover)
                .frame(width: SettingsPanelMetrics.popoverSize.width, height: SettingsPanelMetrics.popoverSize.height)
        }
    }
}

private struct SidebarItemView: View {
    let category: SettingsCategory
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(isSelected ? 0.95 : 1))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isSelected
                            ? LinearGradient(
                                colors: [
                                    category.tint.opacity(0.95),
                                    category.tint.opacity(0.60)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    category.tint.opacity(0.92),
                                    category.tint.opacity(0.74)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalized: category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(isSelected ? 0.94 : 0.80))
                    .lineLimit(1)

                Text(appLocalized: category.subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(isSelected ? 0.60 : 0.42))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.10 : 0.04), lineWidth: 1)
        )
        .shadow(color: isSelected ? category.tint.opacity(0.18) : .clear, radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WindowControlButton: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized: title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        SettingsGlassSurface(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .opacity(0.96)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.025),
                                        Color.black.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 18, y: 10)
        }
    }
}

private struct SettingsLineDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.10))
            .padding(.horizontal, 18)
    }
}

private struct HookManagementLine: View {
    let profile: ManagedHookClientProfile
    let isInstalled: Bool
    let isReinstalling: Bool
    let reinstallFeedback: SettingsPanelViewModel.HookReinstallFeedback?
    let installAction: () -> Void
    let openConfigurationDirectoryAction: () -> Void
    let reinstallAction: () -> Void
    let uninstallAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                HookManagementIcon(profile: profile)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized: title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text(appLocalized: subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(appLocalized: isInstalled ? "已安装" : "未安装")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isInstalled ? tint : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill((isInstalled ? tint : .white).opacity(isInstalled ? 0.18 : 0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder((isInstalled ? tint : .white).opacity(isInstalled ? 0.28 : 0.12), lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                if isInstalled {
                    HookManagementButton(
                        title: "打开配置目录",
                        tint: TerminalColors.blue,
                        isDisabled: isReinstalling,
                        action: openConfigurationDirectoryAction
                    )
                    HookManagementButton(
                        title: isReinstalling ? "重新安装中..." : "重新安装",
                        tint: tint,
                        isLoading: isReinstalling,
                        isDisabled: isReinstalling,
                        action: reinstallAction
                    )
                    HookManagementButton(
                        title: "卸载",
                        tint: TerminalColors.amber,
                        isDisabled: isReinstalling,
                        action: uninstallAction
                    )
                } else {
                    HookManagementButton(
                        title: "安装",
                        tint: tint,
                        isDisabled: isReinstalling,
                        action: installAction
                    )
                }
            }

            if let reinstallFeedback {
                HStack(spacing: 8) {
                    Image(systemName: reinstallFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(reinstallFeedback.isError ? TerminalColors.amber : TerminalColors.green)

                    Text(reinstallFeedback.message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.76))
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        profile.title
    }

    private var subtitle: String {
        profile.subtitle
    }

    private var tint: Color {
        brandTint(profile.brand)
    }
}

private struct CustomHookInstallationLine: View {
    let installation: HookInstaller.CustomHookInstallation
    let uninstallAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                if let profile = ClientProfileRegistry.managedHookProfile(id: installation.profileID) {
                    HookManagementIcon(profile: profile)
                } else {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(appLocalized: installation.profileTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)

                        Text(appLocalized: "自定义")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(TerminalColors.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(TerminalColors.blue.opacity(0.18))
                            )
                    }

                    Text(installation.customPath)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Text(appLocalized: "已安装")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TerminalColors.green.opacity(0.18))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(TerminalColors.green.opacity(0.28), lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                HookManagementButton(
                    title: "卸载",
                    tint: TerminalColors.amber,
                    action: uninstallAction
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CustomHookInstallSheet: View {
    @ObservedObject var viewModel: SettingsPanelViewModel
    let onDismiss: () -> Void

    @State private var selectedProfileID: String = ""
    @State private var customPath: String = ""

    private var availableProfiles: [ManagedHookClientProfile] {
        ClientProfileRegistry.managedHookProfiles
    }

    private var canInstall: Bool {
        !selectedProfileID.isEmpty && !customPath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(appLocalized: "添加自定义 Hook 配置")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "选择应用")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    Picker("", selection: $selectedProfileID) {
                        Text(appLocalized: "请选择...").tag("")
                        ForEach(availableProfiles) { profile in
                            Text(profile.title).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "安装目录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    HStack(spacing: 8) {
                        TextField("", text: $customPath, prompt: Text(verbatim: installPathPlaceholder))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            )

                        Button(action: selectDirectory) {
                            Text(appLocalized: "选择目录")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if let resolvedFileName {
                        Text(resolvedInstallTargetDescription(resolvedFileName: resolvedFileName))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let installHint {
                        Text(verbatim: installHint)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button(action: onDismiss) {
                    Text(appLocalized: "取消")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: install) {
                    Text(appLocalized: "安装")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(canInstall ? .white : .white.opacity(0.4))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(canInstall ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(canInstall ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var resolvedFileName: String? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID),
              !customPath.isEmpty else {
            return nil
        }
        return profile.primaryConfigurationURL.lastPathComponent
    }

    private var installPathPlaceholder: String {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return "例如 /path/to/.claude"
        }

        switch profile.installationKind {
        case .jsonHooks:
            return "例如 /path/to/.claude"
        case .pluginFile:
            return "例如 /path/to/plugins"
        case .pluginDirectory:
            return "例如 /path/to/.hermes 或 /path/to/plugins"
        case .hookDirectory:
            return "例如 /path/to/.openclaw 或 /path/to/hooks"
        }
    }

    private var installHint: String? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return nil
        }
        switch profile.installationKind {
        case .hookDirectory:
            return AppLocalization.string("OpenClaw 可选择 ~/.openclaw 根目录，或已配置到 extraDirs 的 hooks 目录。")
        case .pluginDirectory:
            return AppLocalization.string("Hermes 可选择 ~/.hermes 根目录，或 plugins 目录。")
        case .jsonHooks, .pluginFile:
            return nil
        }
    }

    private func resolvedInstallTargetDescription(resolvedFileName: String) -> String {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return AppLocalization.format("安装后将写入: %@/%@", customPath, resolvedFileName)
        }

        let baseURL = URL(fileURLWithPath: customPath)
        let targetURL: URL
        switch profile.installationKind {
        case .jsonHooks, .pluginFile:
            targetURL = baseURL.appendingPathComponent(resolvedFileName)
        case .pluginDirectory:
            if baseURL.lastPathComponent == ".hermes" {
                targetURL = baseURL
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent(resolvedFileName, isDirectory: true)
            } else if baseURL.lastPathComponent == "plugins" {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            } else {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            }
        case .hookDirectory:
            if baseURL.lastPathComponent == ".openclaw" {
                targetURL = baseURL
                    .appendingPathComponent("hooks", isDirectory: true)
                    .appendingPathComponent(resolvedFileName, isDirectory: true)
            } else if baseURL.lastPathComponent == "hooks" {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            } else {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            }
        }

        return AppLocalization.format("安装后将写入: %@", targetURL.path)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = AppLocalization.string("选择 Hook 配置目录")
        panel.prompt = AppLocalization.string("选择")

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }

    private func install() {
        guard canInstall else { return }
        viewModel.installCustomHook(profileID: selectedProfileID, directoryPath: customPath)
        onDismiss()
    }
}

private struct HookManagementIcon: View {
    let profile: ManagedHookClientProfile

    var body: some View {
        SettingsClientIcon(
            logoAssetName: profile.logoAssetName,
            prefersBundledLogoOverAppIcon: profile.prefersBundledLogoOverAppIcon,
            localAppBundleIdentifiers: profile.localAppBundleIdentifiers,
            iconSymbolName: profile.iconSymbolName
        )
    }
}

private struct RemoteHostManagementLine: View {
    let endpoint: RemoteEndpoint
    let runtimeState: RemoteEndpointRuntimeState
    let hasReusablePassword: Bool
    let connectAction: (String?) -> Void
    let requestConnectPasswordAction: () -> Void
    let disconnectAction: () -> Void
    let uninstallAction: (String?) -> Void
    let requestUninstallPasswordAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "network")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.24))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(endpoint.resolvedTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)

                        Text(appLocalized: runtimeState.phase.titleKey)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(statusTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(statusTint.opacity(0.18))
                            )
                    }

                    if let sshURL = endpoint.sshURL {
                        Link(destination: sshURL) {
                            HStack(spacing: 4) {
                                Text(endpoint.sshURL?.absoluteString ?? endpoint.sshTarget)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.52))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(endpoint.sshTarget)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.52))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(detailText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
            }

            HStack(spacing: 10) {
                if runtimeState.phase == .connected {
                    HookManagementButton(
                        title: "断开",
                        tint: TerminalColors.amber,
                        isDisabled: isBusy
                    ) {
                        disconnectAction()
                    }
                } else {
                    HookManagementButton(
                        title: connectButtonTitle,
                        tint: TerminalColors.blue,
                        isLoading: isConnecting,
                        isDisabled: isBusy
                    ) {
                        if shouldPromptForPassword {
                            requestConnectPasswordAction()
                        } else {
                            connectAction(nil)
                        }
                    }
                }

                HookManagementButton(
                    title: "卸载 bridge",
                    tint: TerminalColors.amber,
                    isLoading: isUninstalling,
                    isDisabled: isBusy
                ) {
                    if shouldPromptForUninstallPassword {
                        requestUninstallPasswordAction()
                    } else {
                        uninstallAction(nil)
                    }
                }

                HookManagementButton(
                    title: "删除",
                    tint: TerminalColors.amber,
                    isDisabled: isBusy
                ) {
                    removeAction()
                }
            }

            if let lastError = runtimeState.lastError, !lastError.isEmpty {
                Text(verbatim: AppLocalization.string(lastError))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailText: String {
        var parts: [String] = [runtimeState.detail]
        if let detectedHostname = endpoint.detectedHostname, !detectedHostname.isEmpty {
            parts.append(detectedHostname)
        }
        parts.append(AppLocalization.string(authenticationDetail))
        if let agentVersion = runtimeState.agentVersion ?? endpoint.agentVersion {
            parts.append("Agent \(agentVersion)")
        }
        return parts.map { AppLocalization.string($0) }.joined(separator: " · ")
    }

    private var shouldPromptForPassword: Bool {
        runtimeState.requiresPassword || (endpoint.authMode == .passwordSession && !hasReusablePassword)
    }

    private var shouldPromptForUninstallPassword: Bool {
        runtimeState.requiresPassword || (endpoint.authMode == .passwordSession && !hasReusablePassword)
    }

    private var isConnecting: Bool {
        switch runtimeState.phase {
        case .probing, .bootstrapping, .connecting:
            return true
        case .disconnected, .uninstalling, .connected, .degraded, .failed:
            return false
        }
    }

    private var isUninstalling: Bool {
        runtimeState.phase == .uninstalling
    }

    private var isBusy: Bool {
        isConnecting || isUninstalling
    }

    private var connectButtonTitle: String {
        if isConnecting {
            return "连接中"
        }

        return shouldPromptForPassword ? "输入密码并连接" : "连接"
    }

    private var authenticationDetail: String {
        switch endpoint.authMode {
        case .passwordSession:
            return hasReusablePassword ? "密码已保存" : "需要重新输入密码"
        default:
            return endpoint.authMode.titleKey
        }
    }

    private var statusTint: Color {
        switch runtimeState.phase {
        case .connected:
            return TerminalColors.green
        case .failed, .degraded:
            return TerminalColors.amber
        case .connecting, .probing, .bootstrapping:
            return TerminalColors.blue
        case .uninstalling:
            return TerminalColors.amber
        case .disconnected:
            return .white.opacity(0.68)
        }
    }
}

private struct AddRemoteHostSheet: View {
    @ObservedObject var remoteManager: RemoteConnectorManager
    let onDismiss: () -> Void

    @State private var displayName = ""
    @State private var sshTarget = ""
    @State private var sshPort = "\(RemoteSSHLink.defaultPort)"
    @State private var password = ""

    private var parsedPort: Int? {
        guard let port = Int(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private var canAdd: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedPort != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(appLocalized: "添加远程主机")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 14) {
                remoteField(title: "显示名称（可选）", placeholder: "例如 GPU Box", text: $displayName)
                remoteField(title: "SSH 目标", placeholder: "例如 dev@10.0.0.8 或 my-server", text: $sshTarget)
                remoteField(title: "端口", placeholder: "22", text: $sshPort)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "密码（可选）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    SecureField("", text: $password, prompt: Text(appLocalized: "连接成功后后续可直接重连"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .submitLabel(.go)
                        .onSubmit {
                            addAndConnect()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                }

                if sshPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                   parsedPort == nil {
                    Text(appLocalized: "端口需为 1 到 65535")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TerminalColors.amber)
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button(action: onDismiss) {
                    Text(appLocalized: "取消")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: addAndConnect) {
                    Text(appLocalized: "保存并连接")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(canAdd ? .white : .white.opacity(0.4))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(canAdd ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(canAdd ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func remoteField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appLocalized: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            TextField("", text: text, prompt: Text(appLocalized: placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        }
    }

    private func addAndConnect() {
        guard let port = parsedPort, canAdd else { return }
        let endpoint = remoteManager.addEndpoint(displayName: displayName, sshTarget: sshTarget, sshPort: port)
        remoteManager.connect(
            endpointID: endpoint.id,
            password: password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : password
        )
        onDismiss()
    }
}

private enum RemotePasswordPromptAction: String {
    case connect
    case uninstallBridge

    var titleFormat: String {
        switch self {
        case .connect:
            return "连接 %@"
        case .uninstallBridge:
            return "卸载 %@ 的 bridge"
        }
    }

    var submitTitle: String {
        switch self {
        case .connect:
            return "连接"
        case .uninstallBridge:
            return "卸载"
        }
    }
}

private struct RemotePasswordPromptRequest: Identifiable {
    let endpoint: RemoteEndpoint
    let action: RemotePasswordPromptAction

    var id: String {
        "\(endpoint.id.uuidString)-\(action.rawValue)"
    }
}

private struct RemotePasswordPromptSheet: View {
    let request: RemotePasswordPromptRequest
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: AppLocalization.format(request.action.titleFormat, request.endpoint.resolvedTitle))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            if let sshURL = request.endpoint.sshURL {
                Link(destination: sshURL) {
                    HStack(spacing: 4) {
                        Text(request.endpoint.sshURL?.absoluteString ?? request.endpoint.sshTarget)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.56))
                }
                .buttonStyle(.plain)
            } else {
                Text(request.endpoint.sshTarget)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.56))
            }

            SecureField("", text: $password, prompt: Text(appLocalized: "输入 SSH 密码"))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .submitLabel(.go)
                .onSubmit {
                    submitPassword()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Spacer()

                Button(action: onDismiss) {
                    Text(appLocalized: "取消")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: submitPassword) {
                    Text(appLocalized: request.action.submitTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(password.isEmpty ? .white.opacity(0.4) : .white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(password.isEmpty ? .white.opacity(0.04) : buttonTint.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(password.isEmpty ? .white.opacity(0.08) : buttonTint.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        onSubmit(password)
    }

    private var buttonTint: Color {
        switch request.action {
        case .connect:
            return TerminalColors.blue
        case .uninstallBridge:
            return TerminalColors.amber
        }
    }
}

private struct IDEExtensionManagementLine: View {
    let profile: ManagedIDEExtensionProfile
    let isInstalled: Bool
    let installAction: () -> Void
    let reinstallAction: () -> Void
    let authorizeAction: () -> Void
    let uninstallAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                IDEExtensionManagementIcon(profile: profile)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized: profile.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text(appLocalized: profile.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(appLocalized: isInstalled ? "已安装" : "未安装")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isInstalled ? tint : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill((isInstalled ? tint : .white).opacity(isInstalled ? 0.18 : 0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder((isInstalled ? tint : .white).opacity(isInstalled ? 0.28 : 0.12), lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                if isInstalled {
                    HookManagementButton(title: "重新安装", tint: tint, action: reinstallAction)
                    HookManagementButton(title: "授权", tint: TerminalColors.blue, action: authorizeAction)
                    HookManagementButton(title: "卸载", tint: TerminalColors.amber, action: uninstallAction)
                } else {
                    HookManagementButton(title: "安装", tint: tint, action: installAction)
                }
            }

            if !isInstalled {
                Text(appLocalized: "安装完成后，如编辑器尚未识别扩展，请重启对应 IDE 再点击“授权”。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.44))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        ideTint(profile.id)
    }
}

private struct IDEExtensionManagementIcon: View {
    let profile: ManagedIDEExtensionProfile

    var body: some View {
        SettingsClientIcon(
            logoAssetName: profile.logoAssetName,
            prefersBundledLogoOverAppIcon: profile.prefersBundledLogoOverAppIcon,
            localAppBundleIdentifiers: profile.localAppBundleIdentifiers,
            iconSymbolName: profile.iconSymbolName
        )
    }
}

private struct SettingsClientIcon: View {
    let logoAssetName: String?
    let prefersBundledLogoOverAppIcon: Bool
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String

    var body: some View {
        if let preferredLogoAssetName {
            Image(preferredLogoAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else if let resolvedAppIcon {
            Image(nsImage: resolvedAppIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else {
            Image(systemName: iconSymbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }

    private var resolvedAppIcon: NSImage? {
        ClientAppLocator.icon(bundleIdentifiers: localAppBundleIdentifiers)
    }

    private var preferredLogoAssetName: String? {
        guard let logoAssetName else {
            return nil
        }

        return prefersBundledLogoOverAppIcon || resolvedAppIcon == nil
            ? logoAssetName
            : nil
    }
}

private struct NativeRuntimePreviewSection: View {
    @ObservedObject var viewModel: SettingsPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("独立于当前默认实现，仅用于手动体验新的原生 Claude/Codex runtime。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { viewModel.nativeClaudeRuntimeEnabled },
                        set: { viewModel.setNativeRuntimeEnabled($0, for: .claude) }
                    )) {
                        Text("Claude Native Runtime")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .scaleEffect(0.88, anchor: .leading)

                    Toggle(isOn: Binding(
                        get: { viewModel.nativeCodexRuntimeEnabled },
                        set: { viewModel.setNativeRuntimeEnabled($0, for: .codex) }
                    )) {
                        Text("Codex Native Runtime")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .scaleEffect(0.88, anchor: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("工作目录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 8) {
                    TextField("", text: $viewModel.nativeRuntimeWorkingDirectory)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )

                    HookManagementButton(
                        title: "选择目录",
                        tint: TerminalColors.blue,
                        action: viewModel.selectNativeRuntimeDirectory
                    )
                }
            }

            HStack(spacing: 10) {
                HookManagementButton(
                    title: "启动 Claude",
                    tint: brandTint(.claude),
                    isLoading: viewModel.isLaunchingNativeRuntime(for: .claude),
                    isDisabled: !viewModel.nativeClaudeRuntimeEnabled
                        || viewModel.activeNativeRuntimeSessionID(for: .claude) != nil,
                    action: { viewModel.startNativeRuntimeSession(provider: .claude) }
                )

                HookManagementButton(
                    title: "启动 Codex",
                    tint: brandTint(.codex),
                    isLoading: viewModel.isLaunchingNativeRuntime(for: .codex),
                    isDisabled: !viewModel.nativeCodexRuntimeEnabled
                        || viewModel.activeNativeRuntimeSessionID(for: .codex) != nil,
                    action: { viewModel.startNativeRuntimeSession(provider: .codex) }
                )
            }

            if viewModel.activeNativeRuntimeSessionID(for: .claude) != nil
                || viewModel.activeNativeRuntimeSessionID(for: .codex) != nil {
                HStack(spacing: 10) {
                    HookManagementButton(
                        title: "终止 Claude",
                        tint: TerminalColors.amber,
                        isDisabled: viewModel.activeNativeRuntimeSessionID(for: .claude) == nil
                            || viewModel.isLaunchingNativeRuntime(for: .claude),
                        action: { viewModel.terminateNativeRuntimeSession(provider: .claude) }
                    )

                    HookManagementButton(
                        title: "终止 Codex",
                        tint: TerminalColors.amber,
                        isDisabled: viewModel.activeNativeRuntimeSessionID(for: .codex) == nil
                            || viewModel.isLaunchingNativeRuntime(for: .codex),
                        action: { viewModel.terminateNativeRuntimeSession(provider: .codex) }
                    )
                }
            }

            if let nativeRuntimeStatusMessage = viewModel.nativeRuntimeStatusMessage,
               !nativeRuntimeStatusMessage.isEmpty {
                Text(nativeRuntimeStatusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let remoteControlURL = viewModel.nativeRuntimeRemoteControlURL,
               !remoteControlURL.isEmpty {
                NativeRuntimeQRCodeCard(
                    title: "Happy Remote Link",
                    subtitle: "扫码可在 Happy Web 中打开当前 Claude 会话。若设备已登录 Happy，同步后即可直接进入会话。",
                    url: remoteControlURL
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeRuntimeQRCodeCard: View {
    let title: String
    let subtitle: String
    let url: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            QRCodeImageView(payload: url)
                .frame(width: 116, height: 116)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                Text(url)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
                    .textSelection(.enabled)
                    .lineLimit(3)

                Button("在浏览器打开") {
                    guard let remoteURL = URL(string: url) else { return }
                    NSWorkspace.shared.open(remoteURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(TerminalColors.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct QRCodeImageView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = makeImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            }
        }
    }

    private func makeImage(from payload: String) -> NSImage? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }

        let representation = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private func brandTint(_ brand: SessionClientBrand) -> Color {
    brand.tintColor
}

private func ideTint(_ profileID: String) -> Color {
    switch profileID {
    case "vscode-extension":
        return Color(red: 0.15, green: 0.55, blue: 0.96)
    case "cursor-extension":
        return Color(red: 0.30, green: 0.72, blue: 0.98)
    case "codebuddy-extension":
        return Color(red: 0.98, green: 0.61, blue: 0.28)
    case "qoder-extension":
        return Color(red: 0.12, green: 0.88, blue: 0.56)
    default:
        return Color.white.opacity(0.72)
    }
}

private struct HookManagementButton: View {
    let title: String
    let tint: Color
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.86))
                }

                Text(appLocalized: title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.34), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
    }
}

private struct SettingsToggleLine: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .settingsCompactSwitch()
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
    }
}

private extension View {
    func settingsCompactSwitch(scale: CGFloat = 0.84) -> some View {
        self
            .toggleStyle(.switch)
            .controlSize(.small)
            .scaleEffect(scale)
            .frame(width: 32, height: 18)
    }

    func settingsMenuPicker(width: CGFloat) -> some View {
        self
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: width, alignment: .trailing)
    }
}

private struct SettingsInfoLine<Accessory: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                accessory
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SoundPackSourceInfoLine<Accessory: View>: View {
    @ViewBuilder let accessory: Accessory

    private let sourcePaths = [
        "~/.openpeon/packs",
        ".claude/hooks/peon-ping/packs"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: "当前主题包")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                accessory
            }

            Text(appLocalized: "自动扫描以下目录，也支持手动导入本地目录。")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(sourcePaths, id: \.self) { path in
                    SettingsCodeCapsule(text: path, systemImage: "folder")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsActionLine<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let action: () -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Button(action: action) {
            SettingsInfoLine(title: title, subtitle: subtitle) {
                accessory
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SoundPackImportActionLine<Accessory: View>: View {
    let action: () -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    Text(appLocalized: "导入本地主题包")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer(minLength: 12)

                    accessory
                }

                Text(appLocalized: "选择一个本地目录，导入后会加入可选列表。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(appLocalized: "目录内需要包含以下清单文件")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.42))

                    SettingsCodeCapsule(text: "openpeon.json", systemImage: "doc.text")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCodeCapsule: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsValueLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Text(appLocalized: title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSliderLine: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                Text(format(value))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Slider(value: $value, in: range, step: step)
                .tint(TerminalColors.blue)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct ShortcutSettingsLine: View {
    let action: GlobalShortcutAction
    @Binding var shortcut: GlobalShortcut?

    var body: some View {
        ShortcutRecorderControl(
            action: action,
            shortcut: $shortcut,
            defaultShortcut: action.defaultShortcut
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutRecorderControl: View {
    let action: GlobalShortcutAction
    @Binding var shortcut: GlobalShortcut?
    let defaultShortcut: GlobalShortcut?

    @State private var isRecording = false
    @State private var helperTextKey: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: action.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text(appLocalized: action.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                recordButton
            }

            HStack(alignment: .center, spacing: 8) {
                Text(appLocalized: "当前键位")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.40))

                if let shortcut {
                    ShortcutVisualLabel(
                        shortcut: shortcut,
                        fontSize: 11,
                        foregroundColor: .white.opacity(0.92),
                        keyBackground: Color.black.opacity(0.28),
                        keyBorder: Color.white.opacity(0.08),
                        keyMinWidth: 24,
                        keyHorizontalPadding: 7,
                        keyVerticalPadding: 5,
                        keyCornerRadius: 10
                    )
                } else {
                    Text(appLocalized: "未设置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.42))
                }

                Spacer(minLength: 12)

                if shortcut != nil {
                    Button {
                        shortcut = nil
                        helperTextKey = nil
                        stopRecording()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(ShortcutIconButtonStyle())
                    .help(AppLocalization.string("清空快捷键"))
                    .accessibilityLabel(Text(appLocalized: "清空快捷键"))
                }

                if defaultShortcut != nil {
                    Button {
                        shortcut = defaultShortcut
                        helperTextKey = nil
                        stopRecording()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(ShortcutIconButtonStyle())
                    .help(AppLocalization.string("恢复默认快捷键"))
                    .accessibilityLabel(Text(appLocalized: "恢复默认快捷键"))
                }
            }

            Text(appLocalized: helperTextKey ?? (isRecording ? "录制中，按 Esc 取消，Delete 清空" : "需要同时按下至少一个修饰键"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isRecording ? TerminalColors.green.opacity(0.90) : .white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                    .font(.system(size: 11, weight: .bold))

                Text(appLocalized: isRecording ? "按下新快捷键" : "点击录制")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isRecording ? .black : .white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isRecording ? TerminalColors.green.opacity(0.96) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isRecording ? TerminalColors.green.opacity(0.9) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(AppLocalization.string(isRecording ? "停止录制快捷键" : "开始录制快捷键"))
        .accessibilityLabel(Text(appLocalized: isRecording ? "停止录制快捷键" : "开始录制快捷键"))
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        helperTextKey = nil
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleRecording(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleRecording(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            helperTextKey = nil
            stopRecording()
            return
        }

        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            shortcut = nil
            helperTextKey = nil
            stopRecording()
            return
        }

        guard let recordedShortcut = GlobalShortcut(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            helperTextKey = "需要同时按下至少一个修饰键"
            return
        }

        shortcut = recordedShortcut
        helperTextKey = nil
        stopRecording()
    }
}

private struct ShortcutIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.76 : 0.88))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

private struct SubagentVisibilityPicker: View {
    @Binding var mode: SubagentVisibilityMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(SubagentVisibilityMode.allCases) { candidate in
                Text(candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel("子 Agent 显示")
        .settingsMenuPicker(width: 168)
    }
}

private struct NotchDisplayModeSelector: View {
    @Binding var mode: NotchDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appLocalized: "刘海显示模式")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Text(appLocalized: "直接预览刘海闭合态效果。简约模式只显示宠物和数量，详细模式会额外显示中间过程信息。")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(NotchDisplayMode.allCases) { candidate in
                    NotchDisplayModeCard(
                        mode: candidate,
                        isSelected: mode == candidate
                    ) {
                        mode = candidate
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct NotchDisplayModeCard: View {
    let mode: NotchDisplayMode
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(previewBackground)
                        .aspectRatio(7.0 / 3.0, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(previewBorder, lineWidth: 1)
                        )
                        .overlay {
                            previewScene
                                .padding(12)
                        }
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLocalized: mode.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)

                        Text(appLocalized: mode.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isSelected ? accentColor : .white.opacity(0.26))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.09 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? accentColor.opacity(0.56) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: isSelected ? accentColor.opacity(0.18) : .clear, radius: 16, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var accentColor: Color {
        switch mode {
        case .compact:
            return Color(red: 0.24, green: 0.72, blue: 0.98)
        case .detailed:
            return Color(red: 0.98, green: 0.68, blue: 0.25)
        }
    }

    private var previewBackground: LinearGradient {
        switch mode {
        case .compact:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.18, blue: 0.30),
                    Color(red: 0.05, green: 0.09, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .detailed:
            return LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.17, blue: 0.09),
                    Color(red: 0.11, green: 0.07, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var previewBorder: Color {
        isSelected ? accentColor.opacity(0.42) : Color.white.opacity(0.10)
    }

    @ViewBuilder
    private var previewScene: some View {
        GeometryReader { proxy in
            let notchWidth = min(max(proxy.size.width * 0.9, 112), 168)
            let notchHeight = min(max(proxy.size.height * 0.28, 22), 28)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(spacing: 0) {
                    notchMock(width: notchWidth, height: notchHeight)
                        .padding(.top, 10)

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()
                        Text(appLocalized: mode == .compact ? "简约示意" : "详细示意")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.42))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func notchMock(width: CGFloat, height: CGFloat) -> some View {
        let actualClosedWidth: CGFloat = 274
        let actualSideWidth: CGFloat = 30
        let actualCenterWidth: CGFloat = 186
        let sideSlotWidth = width * (actualSideWidth / actualClosedWidth)
        let centerSlotWidth = width * (actualCenterWidth / actualClosedWidth)

        return HStack(spacing: 0) {
            HStack {
                petMock
            }
            .frame(width: sideSlotWidth, alignment: .center)

            HStack {
                if mode == .detailed {
                    processMock
                        .frame(width: centerSlotWidth * 0.92, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: centerSlotWidth * 0.92)
                }
            }
            .frame(width: centerSlotWidth, alignment: .center)

            HStack {
                countMock
            }
            .frame(width: sideSlotWidth, alignment: .center)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 5)
    }

    private var petMock: some View {
        MascotView(kind: settings.mascotKind(for: .claude), status: .idle, size: 14)
    }

    private var processMock: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.12))
            .frame(height: 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.76))
                    .frame(width: 42, height: 3)
                    .padding(.leading, 8)
            }
    }

    private var countMock: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.12))
            .frame(width: 18, height: 14)
            .overlay(
                Text("3")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            )
    }
}

private struct SettingsStatusLine: View {
    let title: String
    let subtitle: String?
    let status: String
    let statusColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 16) {
                    Text(appLocalized: title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer(minLength: 12)

                    HStack(spacing: 10) {
                        Text(appLocalized: status)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(statusColor)

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                if let subtitle {
                    Text(appLocalized: subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SoundEventSettingsLine: View {
    let event: NotificationEvent
    @Binding var isEnabled: Bool
    @Binding var selectedSound: NotificationSound
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(alignment: .center, spacing: 8) {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .settingsCompactSwitch()

                    Picker(event.title, selection: $selectedSound) {
                        ForEach(NotificationSound.allCases, id: \.self) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                    .id(selectedSound)
                    .labelsHidden()
                    .settingsMenuPicker(width: 148)
                    .disabled(!isEnabled)

                    Button(action: preview) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(isEnabled ? 0.82 : 0.4))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(isEnabled ? 0.08 : 0.03))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }

            Text(appLocalized: event.subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct SoundPackEventLine: View {
    let event: NotificationEvent
    @Binding var isEnabled: Bool
    let preview: () -> Void

    private var categorySummary: String {
        event.cespCategories.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .settingsCompactSwitch()

                    Button(action: preview) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(isEnabled ? 0.82 : 0.4))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(isEnabled ? 0.08 : 0.03))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }

            Text(appLocalized: event.subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Text(categorySummary)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.42))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct BundledThemeEventLine: View {
    let event: NotificationEvent
    let soundLabel: String
    @Binding var isEnabled: Bool
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .settingsCompactSwitch()

                    Button(action: preview) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(isEnabled ? 0.82 : 0.4))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(isEnabled ? 0.08 : 0.03))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }

            Text(appLocalized: event.subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Text(AppLocalization.format("固定音效：%@", soundLabel))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.42))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
