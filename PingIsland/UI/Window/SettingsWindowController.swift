import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let settingsWindowVisibilityDidChange = Notification.Name("settingsWindowVisibilityDidChange")
    static let settingsWindowCategorySelectionRequested = Notification.Name("settingsWindowCategorySelectionRequested")
}

enum SettingsWindowVisibilityNotification {
    static let isVisibleKey = "isVisible"
}

enum SettingsWindowCategorySelectionRequest {
    static let categoryKey = "category"
}

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
        publishVisibilityDidChange(isVisible: true)
    }

    func present(category: SettingsCategory) {
        present()
        NotificationCenter.default.post(
            name: .settingsWindowCategorySelectionRequested,
            object: self,
            userInfo: [SettingsWindowCategorySelectionRequest.categoryKey: category.rawValue]
        )
    }

    func dismiss() {
        window?.orderOut(nil)
        publishVisibilityDidChange(isVisible: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        publishVisibilityDidChange(isVisible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        publishVisibilityDidChange(isVisible: window?.isVisible == true)
    }

    private func publishVisibilityDidChange(isVisible: Bool) {
        NotificationCenter.default.post(
            name: .settingsWindowVisibilityDidChange,
            object: self,
            userInfo: [SettingsWindowVisibilityNotification.isVisibleKey: isVisible]
        )
    }
}

@MainActor
final class PresentationModeWelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PresentationModeWelcomeWindowController()

    private let fixedContentSize = NSSize(width: 760, height: 520)
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let presentationAnimationDuration: TimeInterval = 0.22
    private let dismissalAnimationDuration: TimeInterval = 0.16
    private var completion: ((IslandSurfaceMode) -> Void)?
    private var isDismissing = false

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
        hostingController.view.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(onComplete: @escaping (IslandSurfaceMode) -> Void) {
        isDismissing = false
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
        window.alphaValue = 0
        setContentScale(0.965)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        animateContentScale(from: 0.965, to: 1, duration: presentationAnimationDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = presentationAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        dismissAnimated()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    private func finish(with mode: IslandSurfaceMode) {
        let completion = completion
        self.completion = nil
        dismissAnimated {
            completion?(mode)
        }
    }

    private func dismissAnimated(completion: (() -> Void)? = nil) {
        guard let window else {
            completion?()
            return
        }
        guard window.isVisible else {
            completion?()
            return
        }
        guard !isDismissing else { return }

        isDismissing = true
        animateContentScale(from: 1, to: 0.985, duration: dismissalAnimationDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = dismissalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                self.setContentScale(1)
                self.isDismissing = false
                completion?()
            }
        }
    }

    private func setContentScale(_ scale: CGFloat) {
        guard let layer = hostingController.view.layer else { return }
        layer.removeAnimation(forKey: "presentationModeWelcomeScale")
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func animateContentScale(from startScale: CGFloat, to endScale: CGFloat, duration: TimeInterval) {
        guard let layer = hostingController.view.layer else { return }
        layer.removeAnimation(forKey: "presentationModeWelcomeScale")
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = startScale
        animation.toValue = endScale
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: endScale >= startScale ? .easeOut : .easeIn)
        layer.transform = CATransform3DMakeScale(endScale, endScale, 1)
        layer.add(animation, forKey: "presentationModeWelcomeScale")
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

#if APP_STORE
    private let fixedContentSize = NSSize(width: 560, height: 548)
#else
    private let fixedContentSize = NSSize(width: 540, height: 480)
#endif
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
                    Text(appLocalized: title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text(appLocalized: subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }

#if APP_STORE
                appStoreAuthorizationNotice
#endif

                profileList

                Spacer(minLength: 0)

                actionButtons
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 24, y: 14)
        .preferredColorScheme(.dark)
    }

    private var title: String {
#if APP_STORE
        "授权后安装 Hooks"
#else
        "为以下客户端安装 Hooks"
#endif
    }

    private var subtitle: String {
#if APP_STORE
        "Mac App Store 版本不会自动写入 ~/.claude、~/.codex 等目录。选择安装时，Ping Island 会请求你授权用户主目录后再写入配置。"
#else
        "Ping Island 通过 Hooks 监听会话事件、显示通知与审批。可以一键安装默认配置，或选择仅启用部分事件。"
#endif
    }

    private var contentSize: CGSize {
#if APP_STORE
        CGSize(width: 560, height: 548)
#else
        CGSize(width: 540, height: 480)
#endif
    }

#if APP_STORE
    private var appStoreAuthorizationNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.open.display")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TerminalColors.amber)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized: "前往设置的 Hooks 管理")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.88))
                Text(appLocalized: "你也可以稍后到“设置 > 集成 > Hooks 管理”点击安装；系统会请求授权用户主目录后再写入配置。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TerminalColors.amber.opacity(0.22), lineWidth: 1)
        )
    }
#endif

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
                Text(appLocalized: primaryButtonTitle)
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
                    Text(appLocalized: secondaryButtonTitle)
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

    private var primaryButtonTitle: String {
#if APP_STORE
        "授权主目录并安装"
#else
        "使用默认配置安装（推荐）"
#endif
    }

    private var secondaryButtonTitle: String {
#if APP_STORE
        "打开设置并授权 Hooks…"
#else
        "自定义事件…"
#endif
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
