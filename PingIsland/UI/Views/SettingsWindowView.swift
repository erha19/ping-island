import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case display
    case mascot
    case sound
    case integration
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .display: return "显示"
        case .mascot: return "宠物"
        case .sound: return "声音"
        case .integration: return "集成"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "系统与基础行为"
        case .display: return "显示器与位置"
        case .mascot: return "客户端宠物与动作"
        case .sound: return "通知与提示音"
        case .integration: return "Hooks 与 IDE 扩展"
        case .about: return "版本与更新"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .display: return "rectangle.on.rectangle"
        case .mascot: return "face.smiling.fill"
        case .sound: return "speaker.wave.2.fill"
        case .integration: return "link.circle.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.12, green: 0.42, blue: 0.95)
        case .display: return Color(red: 0.46, green: 0.40, blue: 0.96)
        case .mascot: return Color(red: 0.91, green: 0.27, blue: 0.81)  // Pink
        case .sound: return Color(red: 0.22, green: 0.83, blue: 0.42)
        case .integration: return Color(red: 0.16, green: 0.76, blue: 0.72)
        case .about: return Color(red: 0.17, green: 0.60, blue: 0.96)
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
    @Published var logExportStatus = AppLocalization.string("导出最近 6 小时的 Island 诊断日志与配置")
    @Published private(set) var reinstallingHookProfileID: String?
    @Published private(set) var hookReinstallFeedbacks: [String: HookReinstallFeedback] = [:]
    @Published private(set) var customHookInstallations: [HookInstaller.CustomHookInstallation] = []

    private var hookFeedbackClearTasks: [String: Task<Void, Never>] = [:]

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
    }

    func refreshLocalizedState() {
        guard !isExportingLogs else { return }
        logExportStatus = AppLocalization.string("导出最近 6 小时的 Island 诊断日志与配置")
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
    static let windowSize = CGSize(width: 648, height: 522)
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
    @ObservedObject private var soundPacks = SoundPackCatalog.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var pendingHookReinstallProfile: ManagedHookClientProfile?
    @State private var showingCustomHookInstallSheet = false

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
                minHeight: minimumHeight,
                idealHeight: idealHeight,
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
    }

    private var minimumWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSize.width
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
            return SettingsPanelMetrics.windowSize.height
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
                categories: [.general, .display, .mascot, .sound, .integration, .about]
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
                case .display:
                    displayContent
                case .mascot:
                    mascotContent
                case .sound:
                    soundContent
                case .integration:
                    integrationContent
                case .about:
                    aboutContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    subtitle: "Claude Code、Codex、Gemini CLI、OpenCode、Cursor、Qoder、CodeBuddy、Trae 等客户端会显示各自独立的宠物形象与动作，并支持逐客户端改成别的宠物。"
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.white.opacity(0.06))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.vertical, 8)
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
        case .found:
            return AppLocalization.string("下载更新")
        case .downloading:
            return AppLocalization.string("下载中...")
        case .extracting:
            return AppLocalization.string("解压中...")
        case .readyToInstall:
            return AppLocalization.string("安装并重启")
        case .installing:
            return AppLocalization.string("安装中...")
        case .error:
            return AppLocalization.string("重试更新")
        }
    }

    private var updateSubtitle: String {
        switch updateManager.state {
        case .idle:
            return updateManager.isConfigured
                ? AppLocalization.string("检查 Island 是否有新版本")
                : updateManager.configurationStatus.message
        case .upToDate:
            return AppLocalization.string("当前已经是最新版本")
        case .checking:
            return AppLocalization.string("正在连接更新源")
        case .found(let version, _):
            return AppLocalization.format("发现新版本 v%@", version)
        case .downloading(let progress):
            return AppLocalization.format("下载进度 %lld%%", Int(progress * 100))
        case .extracting(let progress):
            return AppLocalization.format("解压进度 %lld%%", Int(progress * 100))
        case .readyToInstall(let version):
            return AppLocalization.format("已准备安装 v%@", version)
        case .installing:
            return AppLocalization.string("正在替换应用并准备重启")
        case .error:
            return AppLocalization.string("更新失败，点击后重新尝试")
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
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        case .checking, .downloading, .extracting, .installing:
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
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "配置目录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    HStack(spacing: 8) {
                        TextField("", text: $customPath, prompt: Text(verbatim: "例如 /path/to/.claude"))
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
                        Text(AppLocalization.format("安装后将写入: %@/%@", customPath, resolvedFileName))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        if let logoAssetName = preferredLogoAssetName {
            Image(logoAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else if let appIcon = resolvedAppIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else {
            Image(systemName: profile.iconSymbolName)
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
        ClientAppLocator.icon(bundleIdentifiers: profile.localAppBundleIdentifiers)
    }

    private var preferredLogoAssetName: String? {
        guard let logoAssetName = profile.logoAssetName else {
            return nil
        }

        return profile.prefersBundledLogoOverAppIcon || resolvedAppIcon == nil
            ? logoAssetName
            : nil
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
        if let appIcon = ClientAppLocator.icon(bundleIdentifiers: profile.localAppBundleIdentifiers) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else {
            Image(systemName: profile.iconSymbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
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
    case "qoderwork-extension":
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
