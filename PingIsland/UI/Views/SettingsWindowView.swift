import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case display
    case mascot
    case sound
    case analytics
    case integration
    case remote
    case labs
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcuts: return "快捷键"
        case .display: return "显示"
        case .mascot: return "宠物"
        case .sound: return "声音"
        case .analytics: return "统计"
        case .integration: return "集成"
        case .remote: return "远程"
        case .labs: return "实验室"
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
        case .analytics: return "Agent、Token 与工具"
        case .integration: return "Hooks 与 IDE 扩展"
        case .remote: return "SSH 主机与远程转发"
        case .labs: return "试验性特性"
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
        case .analytics: return "chart.bar.xaxis"
        case .integration: return "link.circle.fill"
        case .remote: return "network.badge.shield.half.filled"
        case .labs: return "flask.fill"
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
        case .analytics: return Color(red: 0.97, green: 0.70, blue: 0.22)
        case .integration: return Color(red: 0.16, green: 0.76, blue: 0.72)
        case .remote: return Color(red: 0.95, green: 0.54, blue: 0.20)
        case .labs: return Color(red: 0.82, green: 0.48, blue: 0.97)
        case .about: return Color(red: 0.17, green: 0.60, blue: 0.96)
        }
    }

    static func visibleCategories(labsUnlocked: Bool) -> [SettingsCategory] {
        allCases.filter { category in
            category != .labs || labsUnlocked
        }
    }
}

struct QoderCLIHookRefreshNoticeGate {
    private static let defaultsKey = "SettingsPanel.qoderCLIHookRefreshNoticeShown.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func consumeShouldShowNotice() -> Bool {
        guard !defaults.bool(forKey: Self.defaultsKey) else {
            return false
        }

        defaults.set(true, forKey: Self.defaultsKey)
        return true
    }
}

struct ClosedNotchUsageAvailability: Equatable {
    var hasClaudeSevenDay = false
    var hasCodexSevenDay = false

    static func current() -> ClosedNotchUsageAvailability {
        let cachedClaudeSnapshot = UsageSnapshotCacheStore.loadClaude()
        let cachedCodexSnapshot = UsageSnapshotCacheStore.loadCodex()
        let claudeSnapshot = if cachedClaudeSnapshot?.sevenDay == nil {
            (try? ClaudeUsageLoader.load()) ?? cachedClaudeSnapshot
        } else {
            cachedClaudeSnapshot
        }
        let codexSnapshot = if cachedCodexSnapshot?.windows.contains(where: {
            UsageSummaryPresenter.isSevenDayWindowLabel($0.label)
        }) != true {
            (try? CodexUsageLoader.load()) ?? cachedCodexSnapshot
        } else {
            cachedCodexSnapshot
        }

        return ClosedNotchUsageAvailability(
            hasClaudeSevenDay: claudeSnapshot?.sevenDay != nil,
            hasCodexSevenDay: codexSnapshot?.windows.contains {
                UsageSummaryPresenter.isSevenDayWindowLabel($0.label)
            } == true
        )
    }

    func supports(_ mode: ClosedNotchTrailingContentMode) -> Bool {
        switch mode {
        case .sessionCount:
            return true
        case .claudeSevenDayRemaining:
            return hasClaudeSevenDay
        case .codexSevenDayRemaining:
            return hasCodexSevenDay
        }
    }
}

enum AccessibilityPermissionStatus {
#if APP_STORE
    static let isAvailable = false

    static func isTrusted(prompt: Bool = false) -> Bool {
        false
    }
#else
    static let isAvailable = true

    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }
#endif
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
    @Published private(set) var qoderCLIHookRefreshStatus: HookInstaller.QoderCLIHookRefreshStatus?
    @Published private(set) var qoderCLIHookRefreshNoticeStatus: HookInstaller.QoderCLIHookRefreshStatus?
    @Published private(set) var closedNotchUsageAvailability = ClosedNotchUsageAvailability()
    @Published private(set) var bridgeHealthStatus = HookInstaller.BridgeHealthStatus(
        isHealthy: false,
        message: AppLocalization.string("Bridge 链路尚未检测")
    )

    private var hookFeedbackClearTasks: [String: Task<Void, Never>] = [:]
    private let qoderCLIHookRefreshStatusProvider: @MainActor () -> HookInstaller.QoderCLIHookRefreshStatus?
    private let qoderCLIHookRefreshNoticeGate: QoderCLIHookRefreshNoticeGate
    private let accessibilityStatusProvider: @MainActor (_ prompt: Bool) -> Bool
    private let accessibilitySettingsOpener: @MainActor () -> Void

    init(
        qoderCLIHookRefreshStatusProvider: @escaping @MainActor () -> HookInstaller.QoderCLIHookRefreshStatus? = {
            HookInstaller.qoderCLIHookRefreshStatus()
        },
        qoderCLIHookRefreshNoticeDefaults: UserDefaults = .standard,
        accessibilityStatusProvider: @escaping @MainActor (_ prompt: Bool) -> Bool = { prompt in
            AccessibilityPermissionStatus.isTrusted(prompt: prompt)
        },
        accessibilitySettingsOpener: @escaping @MainActor () -> Void = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    ) {
        self.qoderCLIHookRefreshStatusProvider = qoderCLIHookRefreshStatusProvider
        qoderCLIHookRefreshNoticeGate = QoderCLIHookRefreshNoticeGate(
            defaults: qoderCLIHookRefreshNoticeDefaults
        )
        self.accessibilityStatusProvider = accessibilityStatusProvider
        self.accessibilitySettingsOpener = accessibilitySettingsOpener
    }

    var visibleHookProfiles: [ManagedHookClientProfile] {
        let profiles = ClientProfileRegistry.managedHookProfiles.filter { profile in
            profile.alwaysVisibleInSettings
                || (profile.id == "qoder-cli-hooks" && qoderCLIHookRefreshStatus != nil)
                || ClientAppLocator.isInstalled(bundleIdentifiers: profile.localAppBundleIdentifiers)
        }

        return profiles.filter { $0.id != "gemini-hooks" }
            + profiles.filter { $0.id == "gemini-hooks" }
    }

    var hasIntegrationNotice: Bool {
        qoderCLIHookRefreshNoticeStatus != nil
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

    func refreshInitialState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshAccessibilityStatus()
        refreshLocalizedState()
    }

    func refresh(for category: SettingsCategory) {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshAccessibilityStatus()
        refreshLocalizedState()

        switch category {
        case .display:
            ScreenSelector.shared.refreshScreens()
            refreshClosedNotchUsageAvailability()
        case .sound:
            SoundPackCatalog.shared.refresh()
        case .integration:
            refreshHookInstallationStates()
            refreshIDEExtensionInstallationStates()
            refreshCustomHookInstallations()
            refreshQoderCLIHookRefreshStatus()
            refreshBridgeHealthStatus()
        case .general, .shortcuts, .mascot, .analytics, .remote, .labs, .about:
            break
        }
    }

    func refreshAccessibilityStatus() {
        guard AccessibilityPermissionStatus.isAvailable else {
            accessibilityEnabled = false
            return
        }

        accessibilityEnabled = accessibilityStatusProvider(false)
    }

    func refreshLocalizedState() {
        guard !isExportingLogs else { return }
        logExportStatus = AppLocalization.string("导出最近 10 分钟的 Island 诊断日志与配置")
    }

    func refreshQoderCLIHookRefreshStatus() {
        let status = qoderCLIHookRefreshStatusProvider()
        qoderCLIHookRefreshStatus = status

        guard let status else {
            qoderCLIHookRefreshNoticeStatus = nil
            return
        }

        if qoderCLIHookRefreshNoticeStatus != nil {
            return
        }

        guard qoderCLIHookRefreshNoticeGate.consumeShouldShowNotice() else {
            qoderCLIHookRefreshNoticeStatus = nil
            return
        }

        qoderCLIHookRefreshNoticeStatus = status
    }

    func refreshClosedNotchUsageAvailability() {
        closedNotchUsageAvailability = ClosedNotchUsageAvailability.current()
    }

    func refreshBridgeHealthStatus() {
        bridgeHealthStatus = HookInstaller.bridgeHealthStatus()
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
#if APP_STORE
        let didInstall = HookInstaller.installWithUserAuthorization(profile)
        if didInstall {
            AppSettings.hookInstallOnboardingPending = false
        }
#else
        HookInstaller.install(profile)
        let didInstall = HookInstaller.isInstalled(profile)
#endif
        Task {
            await TelemetryService.shared.recordHookInstall(
                profileID: profile.id,
                result: didInstall,
                source: AppSettings.hookInstallOnboardingPending ? "first_run" : "settings"
            )
        }
        refreshHookInstallationStates()
        refreshBridgeHealthStatus()
    }

    func installHooks(for profile: ManagedHookClientProfile, selection: HookInstallSelection) {
#if APP_STORE
        let didInstall = HookInstaller.installWithUserAuthorization(profile, selection: selection)
        if didInstall {
            AppSettings.hookInstallOnboardingPending = false
        }
#else
        HookInstaller.install(profile, selection: selection)
        let didInstall = HookInstaller.isInstalled(profile)
#endif
        Task {
            await TelemetryService.shared.recordHookInstall(
                profileID: profile.id,
                result: didInstall,
                source: AppSettings.hookInstallOnboardingPending ? "first_run" : "settings"
            )
        }
        refreshHookInstallationStates()
        refreshBridgeHealthStatus()
    }

    func reinstallHooks(for profile: ManagedHookClientProfile, selection: HookInstallSelection) {
        guard reinstallingHookProfileID == nil else { return }

        HookInstaller.saveSelection(selection, for: profile)

        hookFeedbackClearTasks[profile.id]?.cancel()
        hookFeedbackClearTasks[profile.id] = nil
        hookReinstallFeedbacks[profile.id] = nil
        reinstallingHookProfileID = profile.id

        Task {
            await Task.yield()

#if APP_STORE
            let didInstall = HookInstaller.reinstallWithUserAuthorization(profile, selection: selection)
#else
            HookInstaller.reinstall(profile)
            let didInstall = HookInstaller.isInstalled(profile)
#endif

            try? await Task.sleep(nanoseconds: 450_000_000)

            refreshHookInstallationStates()
            refreshBridgeHealthStatus()
            reinstallingHookProfileID = nil
            Task {
                await TelemetryService.shared.recordHookReinstall(profileID: profile.id, result: didInstall)
            }
            hookReinstallFeedbacks[profile.id] = HookReinstallFeedback(
                message: didInstall
                    ? AppLocalization.string("已更新 Hook 配置")
                    : AppLocalization.string("更新失败，请稍后重试"),
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

    func currentHookSelection(for profile: ManagedHookClientProfile) -> HookInstallSelection {
        HookInstaller.loadSelection(for: profile)
    }

    func reinstallHooks(for profile: ManagedHookClientProfile) {
        guard reinstallingHookProfileID == nil else { return }

        hookFeedbackClearTasks[profile.id]?.cancel()
        hookFeedbackClearTasks[profile.id] = nil
        hookReinstallFeedbacks[profile.id] = nil
        reinstallingHookProfileID = profile.id

        Task {
            await Task.yield()

#if APP_STORE
            let didInstall = HookInstaller.reinstallWithUserAuthorization(profile)
#else
            HookInstaller.reinstall(profile)
            let didInstall = HookInstaller.isInstalled(profile)
#endif

            try? await Task.sleep(nanoseconds: 450_000_000)

            refreshHookInstallationStates()
            refreshBridgeHealthStatus()
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
#if APP_STORE
        guard HookInstaller.uninstallWithUserAuthorization(profile) else {
            return
        }
#else
        HookInstaller.uninstall(profile)
#endif
        refreshHookInstallationStates()
        refreshBridgeHealthStatus()
    }

    func installCustomHook(profileID: String, directoryPath: String) {
        HookInstaller.installCustom(profileID: profileID, directoryPath: directoryPath)
        refreshCustomHookInstallations()
    }

    func uninstallCustomHook(id: String) {
        HookInstaller.uninstallCustom(id: id)
        refreshCustomHookInstallations()
    }

    func uninstallAllHooks() {
#if APP_STORE
        guard HookInstaller.uninstallAllWithUserAuthorization() else {
            return
        }
#else
        HookInstaller.uninstall()
#endif
        for installation in HookInstaller.customInstallations() {
            HookInstaller.uninstallCustom(id: installation.id)
        }
        refreshHookInstallationStates()
        refreshCustomHookInstallations()
        refreshBridgeHealthStatus()
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

    func hookNotice(for profile: ManagedHookClientProfile) -> String? {
        guard profile.id == "qoder-cli-hooks",
              let status = qoderCLIHookRefreshNoticeStatus else {
            return nil
        }

        return AppLocalization.format(
            "检测到 Qoder CLI %@；启动时会刷新 Island 托管的 Qoder CLI hooks，并保留同一 ~/.qoder/settings.json 内的 Qoder IDE hooks 与其他 JSON 配置。",
            status.version
        )
    }

    func authorizeIDEExtension(for profile: ManagedIDEExtensionProfile) {
        _ = IDEExtensionInstaller.authorize(profile)
    }

    func openAccessibilitySettings() {
        guard AccessibilityPermissionStatus.isAvailable else {
            accessibilityEnabled = false
            return
        }

        accessibilityEnabled = accessibilityStatusProvider(true)
        if !accessibilityEnabled {
            accessibilitySettingsOpener()
        }
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

        for configurationURL in profile.configurationURLs {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: configurationURL.path, isDirectory: &isDirectory) else {
                continue
            }

            return isDirectory.boolValue ? configurationURL : configurationURL.deletingLastPathComponent()
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

private struct SoundSettingsContent: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var soundPacks = SoundPackCatalog.shared

    var body: some View {
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

                SettingsSectionCard(title: "阶段音效") {
                    ForEach(NotificationEvent.allCases) { event in
                        BundledSoundEventLine(
                            event: event,
                            isEnabled: soundEnabledBinding(for: event),
                            selectedSound: bundledSoundBinding(for: event)
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
        .onAppear {
            ensureValidSelectedSoundPack()
        }
        .onChange(of: soundPacks.availablePacks) { _, _ in
            ensureValidSelectedSoundPack()
        }
        .onChange(of: settings.soundThemeMode) { _, _ in
            ensureValidSelectedSoundPack()
        }
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

    private func bundledSoundBinding(for event: NotificationEvent) -> Binding<Island8BitSound> {
        switch event {
        case .processingStarted:
            return $settings.island8BitProcessingStartSound
        case .attentionRequired:
            return $settings.island8BitAttentionRequiredSound
        case .taskCompleted:
            return $settings.island8BitTaskCompletedSound
        case .taskError:
            return $settings.island8BitTaskErrorSound
        case .resourceLimit:
            return $settings.island8BitResourceLimitSound
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

@MainActor
private final class AgentUsageAnalyticsViewModel: ObservableObject {
    @Published var selectedRange: AgentUsageRange = .sevenDays
    @Published private(set) var snapshot = AgentUsageDashboardSnapshot.empty(range: .sevenDays)
    @Published private(set) var isRefreshing = false

    private var refreshTask: Task<Void, Never>?

    func refresh() {
        refreshTask?.cancel()
        let range = selectedRange
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let nextSnapshot = await AgentUsageStore.shared.snapshot(range: range)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.snapshot = nextSnapshot
                self?.isRefreshing = false
            }
        }
    }

    func selectRange(_ range: AgentUsageRange) {
        guard selectedRange != range else { return }
        selectedRange = range
        refresh()
    }

    deinit {
        refreshTask?.cancel()
    }
}

private struct AgentUsageAnalyticsContent: View {
    @StateObject private var viewModel = AgentUsageAnalyticsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "本地统计") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(appLocalized: "Agent 使用趋势")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.90))
                            Text(appLocalized: "统计仅保存在本机，来自 Hook、转录文件和 Codex token_count 快照。")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.52))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Button(action: viewModel.refresh) {
                            Image(systemName: viewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.72))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("刷新本地统计")
                    }

                    Picker("统计范围", selection: Binding(
                        get: { viewModel.selectedRange },
                        set: { viewModel.selectRange($0) }
                    )) {
                        ForEach(AgentUsageRange.allCases) { range in
                            Text(appLocalized: range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 256)
                }
            }

            SettingsSectionCard(title: "概览") {
                VStack(spacing: 0) {
                    AgentUsageMetricLine(
                        title: "Agent 类型",
                        value: "\(viewModel.snapshot.topAgents.count)",
                        subtitle: "本周期出现的客户端类型"
                    )
                    SettingsLineDivider()
                    AgentUsageMetricLine(
                        title: "会话数",
                        value: AgentUsageFormat.integer(viewModel.snapshot.sessionCount),
                        subtitle: "按 agent 类型去重后的会话"
                    )
                    SettingsLineDivider()
                    AgentUsageMetricLine(
                        title: "工具使用",
                        value: AgentUsageFormat.integer(viewModel.snapshot.toolUseCount),
                        subtitle: "去重后的工具调用次数"
                    )
                    SettingsLineDivider()
                    AgentUsageMetricLine(
                        title: "Token 消耗",
                        value: AgentUsageFormat.compactTokenCount(viewModel.snapshot.tokenTotals.resolvedTotal),
                        subtitle: "Codex 累计快照的本地增量"
                    )
                    SettingsLineDivider()
                    AgentUsageTokenSplitLine(totals: viewModel.snapshot.tokenTotals)
                }
            }

            SettingsSectionCard(title: "Agent 类型排行") {
                AgentUsageRankingList(
                    items: viewModel.snapshot.topAgents,
                    emptyTitle: "还没有可展示的 Agent 数据",
                    tint: SettingsCategory.analytics.tint
                )
            }

            SettingsSectionCard(title: "高频工具") {
                AgentUsageRankingList(
                    items: viewModel.snapshot.topTools,
                    emptyTitle: "还没有可展示的工具调用",
                    tint: TerminalColors.green
                )
            }

            SettingsSectionCard(title: "活跃热力图") {
                AgentUsageHeatmapView(days: viewModel.snapshot.heatmapDays)
            }
        }
        .onAppear {
            viewModel.refresh()
        }
    }
}

private struct AgentUsageMetricLine: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                Text(appLocalized: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(verbatim: value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .monospacedDigit()
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
    }
}

private struct AgentUsageTokenSplitLine: View {
    let totals: AgentUsageTokenTotals

    var body: some View {
        HStack(spacing: 16) {
            AgentUsageTokenPill(
                title: "输入 Token",
                value: AgentUsageFormat.compactTokenCount(totals.input),
                tint: TerminalColors.blue
            )
            AgentUsageTokenPill(
                title: "输出 Token",
                value: AgentUsageFormat.compactTokenCount(totals.output),
                tint: TerminalColors.amber
            )
        }
        .padding(.vertical, 12)
    }
}

private struct AgentUsageTokenPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLocalized: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.50))
            Text(verbatim: value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(tint.opacity(0.95))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentUsageRankingList: View {
    let items: [AgentUsageRankItem]
    let emptyTitle: String
    let tint: Color

    var body: some View {
        if items.isEmpty {
            AgentUsageEmptyLine(title: emptyTitle)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    AgentUsageRankingRow(index: index, item: item, tint: tint)
                    if index < items.count - 1 {
                        SettingsLineDivider()
                    }
                }
            }
        }
    }
}

private struct AgentUsageRankingRow: View {
    let index: Int
    let item: AgentUsageRankItem
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(verbatim: "#\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(tint.opacity(0.86))
                    .frame(width: 30, alignment: .leading)

                Text(verbatim: item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(verbatim: AgentUsageFormat.integer(item.count))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tint.opacity(0.72))
                            .frame(width: max(6, proxy.size.width * max(0.04, item.share)))
                    }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 10)
    }
}

private struct AgentUsageHeatmapView: View {
    let days: [AgentUsageHeatmapDay]

    private let columns = Array(repeating: GridItem(.fixed(11), spacing: 4), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if days.allSatisfy({ $0.activityCount == 0 }) {
                AgentUsageEmptyLine(title: "还没有活跃记录")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: day.activityCount))
                        .frame(width: 11, height: 11)
                        .help("\(AgentUsageFormat.shortDate(day.date)) · \(day.activityCount)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Text(appLocalized: "少")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(forLevel: level))
                        .frame(width: 10, height: 10)
                }
                Text(appLocalized: "多")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
            }
        }
        .padding(.vertical, 12)
    }

    private func color(for count: Int) -> Color {
        if count <= 0 { return color(forLevel: 0) }
        if count < 3 { return color(forLevel: 1) }
        if count < 8 { return color(forLevel: 2) }
        if count < 16 { return color(forLevel: 3) }
        return color(forLevel: 4)
    }

    private func color(forLevel level: Int) -> Color {
        switch level {
        case 0: return Color.white.opacity(0.08)
        case 1: return TerminalColors.green.opacity(0.28)
        case 2: return TerminalColors.green.opacity(0.46)
        case 3: return TerminalColors.green.opacity(0.66)
        default: return TerminalColors.green.opacity(0.92)
        }
    }
}

private struct AgentUsageEmptyLine: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.34))
            Text(appLocalized: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.46))
            Spacer(minLength: 0)
        }
    }
}

private enum AgentUsageFormat {
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func integer(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return integer(value)
    }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }
}

private struct SettingsCategoryLoadingView: View {
    let category: SettingsCategory

    var body: some View {
        SettingsSectionCard(title: category.title) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white.opacity(0.82))

                Text(verbatim: loadingTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))

                Text(verbatim: loadingSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.54))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    private var loadingTitle: String {
        AppLocalization.format("正在加载%@设置…", AppLocalization.string(category.title))
    }

    private var loadingSubtitle: String {
        switch category {
        case .display:
            return AppLocalization.string("正在刷新显示器与用量展示状态")
        case .sound:
            return AppLocalization.string("正在扫描可用声音主题包")
        case .integration:
            return AppLocalization.string("正在检查 Hooks、IDE 扩展与客户端安装状态")
        case .general, .shortcuts, .mascot, .analytics, .remote, .labs, .about:
            return AppLocalization.string("马上就好")
        }
    }
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

    @StateObject private var viewModel = SettingsPanelViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var remoteManager = RemoteConnectorManager.shared
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var pendingHookReinstallProfile: ManagedHookClientProfile?
    @State private var pendingHookOptionsRequest: HookInstallOptionsRequest?
    @State private var showingUninstallAllHooksConfirmation = false
    @State private var showingCustomHookInstallSheet = false
    @State private var showingRemoteHostSheet = false
    @State private var remotePasswordPromptRequest: RemotePasswordPromptRequest?
    @State private var showingAnalyticsConsentPrompt = false
    @State private var consecutiveGeneralTapCount = 0
    @State private var isAccessibilityPollingActive = false
    @State private var arePreviewAnimationsActive = false
    @State private var loadingCategory: SettingsCategory?
    @State private var categoryRefreshTask: Task<Void, Never>?

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
        .environment(\.mascotAnimationsEnabled, arePreviewAnimationsActive)
        .onAppear {
            viewModel.refreshInitialState()
            let isVisible = presentation == .popover || currentWindow?.isVisible == true
            isAccessibilityPollingActive = isVisible
            arePreviewAnimationsActive = isVisible

            scheduleCategoryRefresh(for: currentCategory, showLoading: false)
            showAnalyticsConsentPromptIfNeeded()
        }
        .onDisappear {
            isAccessibilityPollingActive = false
            arePreviewAnimationsActive = false
            categoryRefreshTask?.cancel()
            categoryRefreshTask = nil
            loadingCategory = nil
        }
        .task(id: isAccessibilityPollingActive) {
            guard isAccessibilityPollingActive else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.refreshAccessibilityStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowVisibilityDidChange)) { notification in
            guard presentation == .window,
                  let isVisible = notification.userInfo?[SettingsWindowVisibilityNotification.isVisibleKey] as? Bool else {
                return
            }

            isAccessibilityPollingActive = isVisible
            arePreviewAnimationsActive = isVisible
            if isVisible {
                scheduleCategoryRefresh(for: currentCategory, showLoading: false)
                showAnalyticsConsentPromptIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowCategorySelectionRequested)) { notification in
            guard presentation == .window,
                  let rawCategory = notification.userInfo?[SettingsWindowCategorySelectionRequest.categoryKey] as? String,
                  let category = SettingsCategory(rawValue: rawCategory) else {
                return
            }

            selectSidebarCategory(category)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scheduleCategoryRefresh(for: currentCategory, showLoading: false)
        }
        .onChange(of: settings.appLanguage) { _, _ in
            viewModel.refreshLocalizedState()
        }
        .alert(
            AppLocalization.string("帮助提升 Ping Island 体验？"),
            isPresented: $showingAnalyticsConsentPrompt
        ) {
            Button(AppLocalization.string("暂不开启"), role: .cancel) {
                settings.analyticsConsentPromptCompleted = true
            }
            Button(AppLocalization.string("同意开启")) {
                settings.analyticsEnabled = true
                settings.analyticsConsentPromptCompleted = true
            }
        } message: {
            Text(appLocalized: "仅发送匿名统计，用于了解启动、功能使用和 Hook 安装成功率。不会包含会话内容、代码、路径或主机信息。")
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
        .alert(
            AppLocalization.string("一键卸载所有 Hooks 配置文件？"),
            isPresented: $showingUninstallAllHooksConfirmation
        ) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("一键卸载所有 Hooks 配置文件"), role: .destructive) {
                viewModel.uninstallAllHooks()
            }
        } message: {
            Text(appLocalized: "这会移除 Island 为所有本机集成写入的托管 Hooks 配置文件，包括自定义配置记录。")
        }
        .sheet(isPresented: $showingCustomHookInstallSheet) {
            CustomHookInstallSheet(viewModel: viewModel) {
                showingCustomHookInstallSheet = false
            }
        }
        .sheet(item: $pendingHookOptionsRequest) { request in
            HookInstallOptionsSheet(
                profile: request.profile,
                mode: request.mode,
                initialSelection: viewModel.currentHookSelection(for: request.profile),
                onConfirm: { selection in
                    switch request.mode {
                    case .install:
                        viewModel.installHooks(for: request.profile, selection: selection)
                    case .edit:
                        viewModel.reinstallHooks(for: request.profile, selection: selection)
                    }
                    pendingHookOptionsRequest = nil
                },
                onDismiss: {
                    pendingHookOptionsRequest = nil
                }
            )
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
                categories: SettingsCategory.visibleCategories(labsUnlocked: settings.labsSettingsUnlocked)
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
                                    selectSidebarCategory(category)
                                } label: {
                                    SidebarItemView(
                                        category: category,
                                        isSelected: selectedCategory == category,
                                        showsNoticeDot: category == .integration && viewModel.hasIntegrationNotice
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
                if loadingCategory == currentCategory {
                    SettingsCategoryLoadingView(category: currentCategory)
                } else {
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
                    case .analytics:
                        analyticsContent
                    case .integration:
                        integrationContent
                    case .remote:
                        remoteContent
                    case .labs:
                        labsContent
                    case .about:
                        aboutContent
                    }
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
        let category = selectedCategory ?? .general
        guard category != .labs || settings.labsSettingsUnlocked else {
            return .general
        }
        return category
    }

    private var currentWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func selectSidebarCategory(_ category: SettingsCategory) {
        selectedCategory = category

        if !settings.labsSettingsUnlocked, category != .general {
            consecutiveGeneralTapCount = 0
        } else if !settings.labsSettingsUnlocked, category == .general {
            consecutiveGeneralTapCount += 1
        }

        if !settings.labsSettingsUnlocked, consecutiveGeneralTapCount >= 6 {
            settings.labsSettingsUnlocked = true
            selectedCategory = .labs
        }

        let categoryToRefresh = currentCategory
        scheduleCategoryRefresh(
            for: categoryToRefresh,
            showLoading: shouldShowLoading(for: categoryToRefresh)
        )
    }

    private func showAnalyticsConsentPromptIfNeeded() {
        guard !settings.analyticsConsentPromptCompleted,
              !settings.analyticsEnabled,
              !showingAnalyticsConsentPrompt else {
            return
        }
        showingAnalyticsConsentPrompt = true
    }

    private func shouldShowLoading(for category: SettingsCategory) -> Bool {
        switch category {
        case .display, .sound, .integration:
            return true
        case .general, .shortcuts, .mascot, .analytics, .remote, .labs, .about:
            return false
        }
    }

    private func scheduleCategoryRefresh(for category: SettingsCategory, showLoading: Bool) {
        categoryRefreshTask?.cancel()
        categoryRefreshTask = nil

        if showLoading {
            loadingCategory = category
        } else if loadingCategory == category {
            loadingCategory = nil
        }

        categoryRefreshTask = Task { @MainActor in
            if showLoading {
                try? await Task.sleep(nanoseconds: 80_000_000)
            } else {
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            viewModel.refresh(for: category)

            guard !Task.isCancelled else { return }
            if loadingCategory == category {
                loadingCategory = nil
            }
        }
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
                }
            }

            SettingsSectionCard(title: "面板") {
                IslandSurfaceModeSelector(mode: $settings.surfaceMode)
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "默认宠物形象",
                    subtitle: "设置展示模式示意图，以及没有活跃或待处理会话时刘海/悬浮宠物使用的默认形象。"
                ) {
                    DisplayPreviewMascotPicker(kind: $settings.previewMascotKind)
                }

                if settings.surfaceMode == .notch {
                    SettingsLineDivider()
                    SettingsInfoLine(
                        title: "刘海拖拽引导",
                        subtitle: "重新演示老用户首次打开新版本时看到的刘海拖拽提示。"
                    ) {
                        HookManagementButton(
                            title: "重新演示",
                            tint: SettingsCategory.display.tint,
                            action: replayNotchDetachmentHint
                        )
                    }
                    SettingsLineDivider()
                    NotchDisplayModeSelector(mode: $settings.notchDisplayMode)
                    SettingsLineDivider()
                    SettingsInfoLine(
                        title: "右侧展示内容",
                        subtitle: "默认显示会话数量；检测到 Claude Code 或 Codex 的 7d 用量后，可改为展示其中一个客户端的 Token 剩余额度。"
                    ) {
                        ClosedNotchTrailingContentPicker(
                            mode: Binding(
                                get: { settings.closedNotchTrailingContentMode },
                                set: { settings.closedNotchTrailingContentMode = $0 }
                            ),
                            availability: viewModel.closedNotchUsageAvailability
                        )
                    }
                } else {
                    SettingsLineDivider()
                    FloatingPetPlacementInfoCard()
                    SettingsLineDivider()
                    SettingsInfoLine(
                        title: "宠物大小",
                        subtitle: "自动模式会根据当前显示器分辨率调整；也可以固定为标准尺寸或始终放大。"
                    ) {
                        FloatingPetSizeModePicker(mode: $settings.floatingPetSizeMode)
                    }
                }
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "显示代理活动详情",
                    subtitle: "在会话列表和 hover 预览里展示工具调用、思考与更细的状态描述",
                    isOn: $settings.showAgentDetail
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "显示用量",
                    subtitle: "在展开面板顶部显示 Claude 与 Codex 的限额占用率和重置时间",
                    isOn: $settings.showUsage
                )
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "用量显示方式",
                    subtitle: "切换显示已用量或剩余量；Claude 与 Codex 共用这组设置"
                ) {
                    UsageValueModePicker(
                        mode: Binding(
                            get: { settings.usageValueMode },
                            set: { settings.usageValueMode = $0 }
                        )
                    )
                    .disabled(!settings.showUsage)
                }
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "子 Agent 显示",
                    subtitle: "控制主列表里是否在主 Agent 下展示明确的子 Agent；当前会影响 Codex、Qoder 等带子会话的客户端"
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
            }
        }
    }

    private func replayNotchDetachmentHint() {
        AppSettings.notchDetachmentHintPending = true
        AppSettings.floatingPetSettingsHintPending = true
        onClose?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .pingIslandPresentNotchDetachmentHint, object: nil)
        }
    }

    private func replayFirstRunOnboardingDemo() {
        SettingsWindowController.shared.dismiss()
        AppSettings.notchDetachmentHintPending = false
        AppSettings.floatingPetSettingsHintPending = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PresentationModeWelcomeWindowController.shared.present { selectedMode in
                AppSettings.surfaceMode = selectedMode
                AppSettings.presentationModeOnboardingPending = false
                AppSettings.notchDetachmentHintPending = false
                AppSettings.floatingPetSettingsHintPending = false

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    HookWalkthroughDemoRunner.shared.start()
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
                    subtitle: "录制状态下直接按新组合键即可；清空会关闭对应全局快捷键，重置按钮才会恢复默认。"
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
        SoundSettingsContent()
    }

    private var analyticsContent: some View {
        AgentUsageAnalyticsContent()
    }

    private var integrationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "审批与提问") {
                SettingsToggleLine(
                    title: "保留终端中的提问与审批",
                    subtitle: "开启后 Ping Island 不再代答 Claude / Codex 等的工具审批和 AskUserQuestion，所有提问保留在终端中处理；状态指示仍会显示。",
                    isOn: $settings.routePromptsToTerminal
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "空闲时自动保留到终端",
                    subtitle: "键盘和鼠标静默达到设定时长后临时开启上方策略；恢复活跃后回到手动设置。",
                    isOn: $settings.autoRoutePromptsToTerminalWhenIdleEnabled
                )
                SettingsLineDivider()

                SettingsInfoLine(
                    title: "静默时长",
                    subtitle: settings.idleAutoRoutePromptsToTerminalActive
                        ? "当前已进入空闲保护，后续新审批和提问会保留在终端。"
                        : "达到该时长后自动进入空闲保护。"
                ) {
                    AutoRoutePromptsIdleDelayPicker(delay: $settings.autoRoutePromptsIdleDelay)
                        .disabled(!settings.autoRoutePromptsToTerminalWhenIdleEnabled)
                        .opacity(settings.autoRoutePromptsToTerminalWhenIdleEnabled ? 1 : 0.45)
                }
            }

#if APP_STORE
            SettingsSectionCard(title: "App Store 沙箱") {
                SettingsInfoLine(
                    title: "需要手动授权目录",
                    subtitle: "App Store 版本不会默认写入 ~/.claude、~/.codex 等配置。安装或重装 Hooks 时，请在系统弹窗中授权用户主目录。"
                ) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(TerminalColors.amber)
                }

                SettingsLineDivider()

                SettingsInfoLine(
                    title: "Bridge 链路自检",
                    subtitle: viewModel.bridgeHealthStatus.message
                ) {
                    HStack(spacing: 10) {
                        Text(appLocalized: viewModel.bridgeHealthStatus.isHealthy ? "正常" : "异常")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill((viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber).opacity(0.16))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder((viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber).opacity(0.28), lineWidth: 1)
                            )

                        HookManagementButton(
                            title: "重新检测",
                            tint: TerminalColors.blue,
                            action: {
                                viewModel.refreshBridgeHealthStatus()
                            }
                        )
                    }
                }
            }
#endif

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
                            noticeMessage: viewModel.hookNotice(for: profile),
                            supportsEventSelection: profile.supportsEventSelection,
                            installAction: {
                                if profile.supportsEventSelection {
                                    pendingHookOptionsRequest = HookInstallOptionsRequest(
                                        profile: profile,
                                        mode: .install
                                    )
                                } else {
                                    viewModel.installHooks(for: profile)
                                }
                            },
                            configureAction: {
                                pendingHookOptionsRequest = HookInstallOptionsRequest(
                                    profile: profile,
                                    mode: .edit
                                )
                            },
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

            SettingsSectionCard(title: "演示") {
                SettingsActionLine(
                    title: "重新体验首次引导",
                    subtitle: "手动打开形态选择引导；选择刘海屏或独立悬浮宠物后，会继续进入 Hooks 演示。"
                ) {
                    replayFirstRunOnboardingDemo()
                } accessory: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SettingsCategory.integration.tint.opacity(0.95))
                }
                SettingsLineDivider()

                SettingsActionLine(
                    title: "体验 Hooks 演示",
                    subtitle: "启动一轮可交互案例：干净桌面背景、审批提交、处理完成、完成提醒。顶部 Island 与独立悬浮宠物都支持。"
                ) {
                    SettingsWindowController.shared.dismiss()
                    HookWalkthroughDemoRunner.shared.start()
                } accessory: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(TerminalColors.blue.opacity(0.95))
                }
            }

#if !APP_STORE
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
#endif

            Button(action: { showingUninstallAllHooksConfirmation = true }) {
                HStack(spacing: 7) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(appLocalized: "一键卸载所有 Hooks 配置文件")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(TerminalColors.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(appLocalized: "一键卸载所有 Hooks 配置文件"))
        }
    }

    private var labsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "实验室") {
                LabsEmptyStateView()
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

            SettingsSectionCard(title: "隐私与分析") {
                SettingsToggleLine(
                    title: "匿名使用统计",
                    subtitle: "匿名统计启动、功能使用、Hook 安装和会话状态；不包含内容、代码、路径或主机信息。",
                    isOn: $settings.analyticsEnabled
                )
                SettingsLineDivider()
                SettingsInfoLine(
                    title: "采集范围",
                    subtitle: "未同意前不上传；开启后有每日上限，可随时关闭。"
                ) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            SettingsSectionCard(title: "更新") {
                SettingsToggleLine(
                    title: "自动检查更新",
                    subtitle: "启动时和空闲时自动检查、下载并安装更新；关闭后仅在手动检查时更新",
                    isOn: $settings.automaticUpdateChecksEnabled
                )
                SettingsLineDivider()

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

    private var appLanguagePicker: some View {
        Picker("语言", selection: $settings.appLanguage) {
            ForEach(AppLanguage.allCases) { language in
                Text(appLocalized: language.title).tag(language)
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
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

    private func shortcutBinding(for action: GlobalShortcutAction) -> Binding<GlobalShortcut?> {
        Binding(
            get: { settings.shortcut(for: action) },
            set: { settings.setShortcut($0, for: action) }
        )
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
                ? AppLocalization.string(
                    settings.automaticUpdateChecksEnabled
                        ? "启动时和空闲时自动检查、下载并安装更新"
                        : "自动更新已关闭，可随时手动检查"
                )
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
    var showsNoticeDot: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
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

                if showsNoticeDot {
                    Circle()
                        .fill(TerminalColors.amber)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.42), lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                        .accessibilityLabel("有需要注意的集成提示")
                }
            }

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
    let noticeMessage: String?
    let supportsEventSelection: Bool
    let installAction: () -> Void
    let configureAction: () -> Void
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

                    if let noticeMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(TerminalColors.amber)
                                .frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { context in
                                    context[VerticalAlignment.center]
                                }

                            Text(verbatim: noticeMessage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(TerminalColors.amber.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
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
                    if supportsEventSelection {
                        HookManagementButton(
                            title: "配置",
                            tint: tint,
                            isDisabled: isReinstalling,
                            action: configureAction
                        )
                    }
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
        case .jsonHooks, .tomlHooks:
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
        case .jsonHooks, .pluginFile, .tomlHooks:
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
        case .jsonHooks, .pluginFile, .tomlHooks:
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

enum HookInstallOptionsMode {
    case install
    case edit
}

struct HookInstallOptionsRequest: Identifiable {
    let id = UUID()
    let profile: ManagedHookClientProfile
    let mode: HookInstallOptionsMode
}

private struct HookInstallOptionsSheet: View {
    let profile: ManagedHookClientProfile
    let mode: HookInstallOptionsMode
    let initialSelection: HookInstallSelection
    let onConfirm: (HookInstallSelection) -> Void
    let onDismiss: () -> Void

    @State private var enabledEventNames: Set<String>
    @State private var advancedExpanded: Bool

    init(
        profile: ManagedHookClientProfile,
        mode: HookInstallOptionsMode,
        initialSelection: HookInstallSelection,
        onConfirm: @escaping (HookInstallSelection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.profile = profile
        self.mode = mode
        self.initialSelection = initialSelection
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _enabledEventNames = State(initialValue: initialSelection.enabledEventNames)
        _advancedExpanded = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categoryToggles
                    advancedSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)

            footer
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HookManagementIcon(profile: profile)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: profile.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private var categoryToggles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profile.availableEventCategories) { category in
                CategoryToggleRow(
                    category: category,
                    state: state(for: category),
                    onToggle: { toggleCategory(category) }
                )

                if category != profile.availableEventCategories.last {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(profile.availableEventCategories) { category in
                    let events = profile.events(in: category)
                    if !events.isEmpty {
                        Text(appLocalized: category.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(events, id: \.name) { event in
                            EventToggleRow(
                                event: event,
                                isOn: enabledEventNames.contains(event.name),
                                onToggle: { toggleEvent(event.name) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        } label: {
            Text(appLocalized: "高级 — 按事件单独配置")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
        }
        .tint(.white.opacity(0.6))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(appLocalized: footerHint)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

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

            Button(action: confirm) {
                Text(appLocalized: confirmTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canConfirm ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(canConfirm ? brandTint(profile.brand).opacity(0.5) : .white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(canConfirm ? brandTint(profile.brand).opacity(0.55) : .white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .install:
            return "选择需要安装的 Hook 事件类别。可在高级中按单个事件微调。"
        case .edit:
            return "调整已安装的 Hook 事件，保存后会刷新该客户端的 hooks 配置。"
        }
    }

    private var footerHint: String {
        AppLocalization.string("默认全部启用；关闭某些事件后，对应通知或审批将不再触发。")
    }

    private var confirmTitle: String {
        switch mode {
        case .install: return "安装"
        case .edit: return "保存"
        }
    }

    private var canConfirm: Bool {
        !enabledEventNames.isEmpty
    }

    private func confirm() {
        guard canConfirm else { return }
        onConfirm(HookInstallSelection(enabledEventNames: enabledEventNames))
    }

    private func state(for category: HookInstallEventCategory) -> CategoryToggleState {
        let names = profile.events(in: category).map(\.name)
        guard !names.isEmpty else { return .off }
        let enabledCount = names.filter { enabledEventNames.contains($0) }.count
        if enabledCount == 0 { return .off }
        if enabledCount == names.count { return .on }
        return .mixed
    }

    private func toggleCategory(_ category: HookInstallEventCategory) {
        let names = profile.events(in: category).map(\.name)
        let currentState = state(for: category)
        switch currentState {
        case .on:
            for name in names { enabledEventNames.remove(name) }
        case .off, .mixed:
            for name in names { enabledEventNames.insert(name) }
        }
    }

    private func toggleEvent(_ name: String) {
        if enabledEventNames.contains(name) {
            enabledEventNames.remove(name)
        } else {
            enabledEventNames.insert(name)
        }
    }
}

private enum CategoryToggleState {
    case on
    case off
    case mixed
}

private struct CategoryToggleRow: View {
    let category: HookInstallEventCategory
    let state: CategoryToggleState
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: category.iconSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized: category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(appLocalized: category.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: onToggle) {
                indicator
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .on:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .mixed:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TerminalColors.amber)
        case .off:
            Image(systemName: "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

private struct EventToggleRow: View {
    let event: HookInstallEventDescriptor
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: event.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.86))

            if let timeout = event.timeout {
                Text(verbatim: "\(timeout)s")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.05))
                    )
            }

            Spacer(minLength: 12)

            Button(action: onToggle) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isOn ? TerminalColors.green : .white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
                    title: "卸载",
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

            if let lastError = localizedLastError {
                Text(verbatim: lastError)
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

    private var localizedLastError: String? {
        guard let lastError = runtimeState.lastError, !lastError.isEmpty else {
            return nil
        }

        let attachDisconnectPrefix = "SSH attach 已断开: "
        if lastError.hasPrefix(attachDisconnectPrefix) {
            let detail = String(lastError.dropFirst(attachDisconnectPrefix.count))
            return AppLocalization.format("SSH attach 已断开: %@", detail)
        }

        return AppLocalization.string(lastError)
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

private struct LabsEmptyStateView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "flask.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(SettingsCategory.labs.tint)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(SettingsCategory.labs.tint.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(SettingsCategory.labs.tint.opacity(0.28), lineWidth: 1)
                )

            VStack(alignment: .center, spacing: 6) {
                Text("暂无可用实验")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

                Text("实验室主要承载一些试验性特性，稳定性不做保障。当前没有开放中的实验项目。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 28)
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
        .accessibilityLabel(Text(appLocalized: "子 Agent 显示"))
        .settingsMenuPicker(width: 168)
    }
}

private struct UsageValueModePicker: View {
    @Binding var mode: UsageValueMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(UsageValueMode.allCases) { candidate in
                Text(appLocalized: candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "用量显示方式"))
        .settingsMenuPicker(width: 168)
    }
}

private struct AutoRoutePromptsIdleDelayPicker: View {
    @Binding var delay: AutoRoutePromptsIdleDelay

    var body: some View {
        Picker("", selection: $delay) {
            ForEach(AutoRoutePromptsIdleDelay.allCases) { candidate in
                Text(appLocalized: candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "静默时长"))
        .settingsMenuPicker(width: 132)
    }
}

private struct ClosedNotchTrailingContentPicker: View {
    @Binding var mode: ClosedNotchTrailingContentMode
    let availability: ClosedNotchUsageAvailability

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(ClosedNotchTrailingContentMode.allCases) { candidate in
                Text(appLocalized: candidate.title)
                    .tag(candidate)
                    .disabled(!availability.supports(candidate))
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "右侧展示内容"))
        .settingsMenuPicker(width: 190)
    }
}

private struct FloatingPetSizeModePicker: View {
    @Binding var mode: FloatingPetSizeMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(FloatingPetSizeMode.allCases) { candidate in
                Text(appLocalized: candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "宠物大小"))
        .settingsMenuPicker(width: 132)
        .help(AppLocalization.string(mode.subtitle))
    }
}

struct IslandSurfaceModeSelector: View {
    @Binding var mode: IslandSurfaceMode
    var title: String? = "展示模式"
    var subtitle: String? = "选择 Ping Island 的主显示方式。你随时可以在设置里切换，并立即看到新的渲染效果。"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                ForEach(IslandSurfaceMode.allCases) { candidate in
                    IslandSurfaceModeCard(
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

struct IslandSurfaceModeCard: View {
    let mode: IslandSurfaceMode
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
                            IslandSurfaceModePreviewScene(
                                surfaceMode: mode,
                                notchDisplayMode: settings.notchDisplayMode,
                                floatingPetSizeMode: settings.floatingPetSizeMode
                            )
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
        case .notch:
            return Color(red: 0.24, green: 0.72, blue: 0.98)
        case .floatingPet:
            return Color(red: 0.98, green: 0.64, blue: 0.26)
        }
    }

    private var previewBackground: LinearGradient {
        switch mode {
        case .notch:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.18, blue: 0.30),
                    Color(red: 0.05, green: 0.09, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .floatingPet:
            return LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.17, blue: 0.08),
                    Color(red: 0.10, green: 0.08, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var previewBorder: Color {
        isSelected ? accentColor.opacity(0.42) : Color.white.opacity(0.10)
    }
}

private struct IslandSurfaceModePreviewScene: View {
    let surfaceMode: IslandSurfaceMode
    let notchDisplayMode: NotchDisplayMode
    let floatingPetSizeMode: FloatingPetSizeMode
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.035))

                switch surfaceMode {
                case .notch:
                    notchPreview(in: proxy.size)
                case .floatingPet:
                    floatingPreview(in: proxy.size)
                }
            }
        }
        .environment(\.mascotAnimationsEnabled, isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func notchPreview(in size: CGSize) -> some View {
        let notchWidth = min(max(size.width * 0.9, 112), 168)
        let notchHeight = min(max(size.height * 0.28, 22), 28)

        return VStack(spacing: 0) {
            NotchDisplayPreviewMock(
                mode: notchDisplayMode,
                mascotKind: settings.previewMascotKind,
                width: notchWidth,
                height: notchHeight
            )
            .padding(.top, 10)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Text(appLocalized: "顶部 Island")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.42))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func floatingPreview(in size: CGSize) -> some View {
        let mascotSize = 34 * previewScale
        let numberSize = 12 * min(previewScale, 1.14)

        return ZStack(alignment: .bottomTrailing) {
            VStack {
                HStack {
                    Text(appLocalized: "右下角悬浮")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.46))
                    Spacer()
                }
                Spacer()
            }
            .padding(10)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: min(24, size.width * 0.10), height: 2)

                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: min(12, size.width * 0.05), height: 2)
                }

                HStack(alignment: .bottom, spacing: 3) {
                    MascotView(
                        kind: settings.previewMascotKind,
                        status: .idle,
                        size: mascotSize
                    )

                    Text("2")
                        .font(.system(size: numberSize, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.26))
                        .offset(y: -1)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
    }

    private var previewScale: CGFloat {
        switch floatingPetSizeMode {
        case .automatic:
            return 1.08
        case .standard:
            return 1
        case .large:
            return 1.16
        }
    }
}

private struct DisplayPreviewMascotPicker: View {
    private let accessibilityTitleKey = "默认宠物形象"
    @Binding var kind: MascotKind

    var body: some View {
        Picker(selection: $kind) {
            ForEach(MascotKind.allCases) { candidate in
                Text(
                    verbatim: AppLocalization.format(
                        "%@ · %@",
                        AppLocalization.string(candidate.subtitle),
                        AppLocalization.string(candidate.title)
                    )
                )
                .tag(candidate)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .accessibilityLabel(Text(verbatim: AppLocalization.string(accessibilityTitleKey)))
        .pickerStyle(.menu)
        .frame(minWidth: 180, alignment: .trailing)
    }
}

private struct FloatingPetPlacementInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLocalized: "独立悬浮宠物")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Text(appLocalized: "独立悬浮宠物默认贴近当前激活窗口右下角显示。拖动后会记住新位置，右键宠物形象可重新打开设置面板。")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct NotchDisplayPreviewMock: View {
    let mode: NotchDisplayMode
    let mascotKind: MascotKind
    let width: CGFloat
    let height: CGFloat

    private let actualClosedWidth: CGFloat = 274
    private let actualSideWidth: CGFloat = 30
    private let actualCenterWidth: CGFloat = 186

    var body: some View {
        let sideSlotWidth = width * (actualSideWidth / actualClosedWidth)
        let centerSlotWidth = width * (actualCenterWidth / actualClosedWidth)

        return HStack(spacing: 0) {
            HStack {
                MascotView(kind: mascotKind, status: .idle, size: 14)
            }
            .frame(width: sideSlotWidth, alignment: .center)

            HStack {
                if mode == .detailed {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.76))
                                .frame(width: 42, height: 3)
                                .padding(.leading, 8)
                        }
                        .frame(width: centerSlotWidth * 0.92, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: centerSlotWidth * 0.92)
                }
            }
            .frame(width: centerSlotWidth, alignment: .center)

            HStack {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 18, height: 14)
                    .overlay(
                        Text("3")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    )
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
                    NotchDisplayPreviewMock(
                        mode: mode,
                        mascotKind: settings.previewMascotKind,
                        width: min(max(proxy.size.width * 0.9, 112), 168),
                        height: min(max(proxy.size.height * 0.28, 22), 28)
                    )
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

private struct BundledSoundEventLine: View {
    let event: NotificationEvent
    @Binding var isEnabled: Bool
    @Binding var selectedSound: Island8BitSound
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
                        ForEach(Island8BitSound.allOrdered) { sound in
                            Text(sound.label).tag(sound)
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
