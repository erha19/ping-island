import AppKit
import SwiftUI

final class SettingsPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let defaultContentSize = NSSize(
        width: SettingsWindowDefaults.defaultContentSize.width,
        height: SettingsWindowDefaults.defaultContentSize.height
    )
    private let minimumContentSize = NSSize(
        width: AppSettings.minimumSettingsWindowSize.width,
        height: AppSettings.minimumSettingsWindowSize.height
    )
    private let maximumContentSize = NSSize(
        width: AppSettings.maximumSettingsWindowSize.width,
        height: AppSettings.maximumSettingsWindowSize.height
    )

    private init() {
        let hostingController = NSHostingController(
            rootView: SettingsWindowView()
        )
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.minSize = minimumContentSize
        window.maxSize = maximumContentSize
        window.setContentSize(defaultContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.center()
        window.toolbar = nil
        window.showsToolbarButton = false
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)

        self.window?.delegate = self
        hostingController.rootView = SettingsWindowView(
            onClose: { [weak self] in
                self?.dismiss()
            },
            onMinimize: { [weak self] in
                self?.window?.miniaturize(nil)
            }
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }

        window.minSize = minimumContentSize
        window.maxSize = maximumContentSize
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}

@MainActor
final class PresentationModeWelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PresentationModeWelcomeWindowController()

    private let fixedContentSize = NSSize(width: 760, height: 520)
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var completion: ((IslandSurfaceMode) -> Void)?

    private init() {
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: fixedContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = fixedContentSize
        window.maxSize = fixedContentSize
        window.setContentSize(fixedContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("presentation-mode-welcome.window")
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(onComplete: @escaping (IslandSurfaceMode) -> Void) {
        completion = onComplete
        hostingController.rootView = AnyView(
            AppLocalizedRootView {
                PresentationModeWelcomeView(initialMode: AppSettings.surfaceMode) { [weak self] mode in
                    self?.finish(with: mode)
                }
            }
        )

        guard let window else { return }
        window.setContentSize(fixedContentSize)
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    private func finish(with mode: IslandSurfaceMode) {
        let completion = completion
        self.completion = nil
        dismiss()
        completion?(mode)
    }
}

enum HookInstallOnboardingDecision {
    case installDefaults
    case customize
    case skip
}

@MainActor
final class HookInstallWelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HookInstallWelcomeWindowController()

    private let fixedContentSize = NSSize(width: 540, height: 480)
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var completion: ((HookInstallOnboardingDecision) -> Void)?

    private init() {
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: fixedContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = fixedContentSize
        window.maxSize = fixedContentSize
        window.setContentSize(fixedContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("hook-install-welcome.window")
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(onComplete: @escaping (HookInstallOnboardingDecision) -> Void) {
        completion = onComplete
        let profiles = HookInstaller.defaultEnabledManageableProfiles()
        hostingController.rootView = AnyView(
            AppLocalizedRootView {
                HookInstallWelcomeView(profiles: profiles) { [weak self] decision in
                    self?.finish(with: decision)
                }
            }
        )

        guard let window else { return }
        window.setContentSize(fixedContentSize)
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    private func finish(with decision: HookInstallOnboardingDecision) {
        let completion = completion
        self.completion = nil
        dismiss()
        completion?(decision)
    }
}

private struct HookInstallWelcomeView: View {
    let profiles: [ManagedHookClientProfile]
    let onComplete: (HookInstallOnboardingDecision) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.15),
                    Color(red: 0.08, green: 0.11, blue: 0.20),
                    Color(red: 0.10, green: 0.16, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(14)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(appLocalized: "为以下客户端安装 Hooks")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text(appLocalized: "Ping Island 通过 Hooks 监听会话事件、显示通知与审批。可以一键安装默认配置，或选择仅启用部分事件。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }

                profileList

                Spacer(minLength: 0)

                actionButtons
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .frame(width: 540, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 24, y: 14)
        .preferredColorScheme(.dark)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profiles) { profile in
                HStack(spacing: 12) {
                    Image(systemName: profile.iconSymbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: profile.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(appLocalized: profile.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.50))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if profile.id != profiles.last?.id {
                    Divider().overlay(Color.white.opacity(0.08))
                        .padding(.horizontal, 14)
                }
            }

            if profiles.isEmpty {
                Text(appLocalized: "未检测到可自动安装的客户端，可在设置中手动添加。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(14)
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

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                onComplete(.installDefaults)
            } label: {
                Text(appLocalized: "使用默认配置安装（推荐）")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black.opacity(0.86))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    )
            }
            .buttonStyle(.plain)
            .disabled(profiles.isEmpty)

            HStack(spacing: 8) {
                Button {
                    onComplete(.customize)
                } label: {
                    Text(appLocalized: "自定义事件…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(profiles.isEmpty)

                Button {
                    onComplete(.skip)
                } label: {
                    Text(appLocalized: "暂不安装")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PresentationModeWelcomeView: View {
    let onComplete: (IslandSurfaceMode) -> Void

    @State private var selectedMode: IslandSurfaceMode

    init(
        initialMode: IslandSurfaceMode,
        onComplete: @escaping (IslandSurfaceMode) -> Void
    ) {
        self.onComplete = onComplete
        _selectedMode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.15),
                    Color(red: 0.08, green: 0.11, blue: 0.20),
                    Color(red: 0.16, green: 0.10, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(16)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(appLocalized: "首次使用，选择展示方式")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)

                    Text(appLocalized: "你可以把 Ping Island 放在屏幕顶部，也可以让宠物默认贴近当前激活窗口右下角显示。之后都能在设置里随时切换。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(appLocalized: "进入独立悬浮宠物模式后，右键宠物形象可重新打开设置面板。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }

                IslandSurfaceModeSelector(
                    mode: $selectedMode,
                    title: nil,
                    subtitle: nil
                )

                HStack {
                    Text(appLocalized: "稍后可在 设置 -> 显示 中重新切换")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.56))

                    Spacer(minLength: 16)

                    Button(action: {
                        onComplete(selectedMode)
                    }) {
                        Text(appLocalized: "开始使用")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black.opacity(0.86))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
        .frame(width: 760, height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 28, y: 16)
        .preferredColorScheme(.dark)
    }
}
