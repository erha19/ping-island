import AppKit
import Foundation
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let pingIslandHookWalkthroughDemoShouldCloseNotch = Notification.Name("pingIslandHookWalkthroughDemoShouldCloseNotch")
}

@MainActor
final class HookWalkthroughDemoRunner {
    static let shared = HookWalkthroughDemoRunner()

    static let metadataSource = "ping_island_hook_walkthrough_demo"
    private static let completionDismissDelay: TimeInterval = 7
    private static let demoSessionCleanupDelayNanoseconds: UInt64 = 7_300_000_000

    private init() {}

    func start() {
        let sessionId = "ping-island-demo-\(UUID().uuidString)"
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let toolUseId = Self.questionToolUseId(for: sessionId)
        let clientInfo = Self.demoClientInfo(sessionId: sessionId)

        HookWalkthroughDemoBackdropWindowController.shared.present()

        Task {
            await SessionStore.shared.process(.hookReceived(Self.notificationEvent(
                sessionId: sessionId,
                cwd: cwd,
                clientInfo: clientInfo
            )))

            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }

            await SessionStore.shared.process(.hookReceived(Self.questionEvent(
                sessionId: sessionId,
                cwd: cwd,
                clientInfo: clientInfo,
                toolUseId: toolUseId
            )))
        }
    }

    func completeIfNeeded(sessionId: String, intervention: SessionIntervention) {
        guard Self.isDemoIntervention(intervention) else { return }
        closeDockedNotchAfterAnswerIfNeeded()

        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            let now = Date()
            let toolUseId = Self.questionToolUseId(for: sessionId)
            await SessionStore.shared.process(.toolCompleted(
                sessionId: sessionId,
                toolUseId: toolUseId,
                result: ToolCompletionResult(
                    status: .success,
                    result: AppLocalization.string("Ping Island 已处理这次演示审批。"),
                    structuredResult: nil
                )
            ))

            await SessionStore.shared.process(.historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "\(sessionId)-assistant-complete",
                        role: .assistant,
                        timestamp: now,
                        content: [.text(AppLocalization.string("Hooks 审批演示完成：你刚刚体验了通知、审批提交、处理完成、以及完成提醒。顶部 Island 和独立悬浮宠物会共用这一套流程。"))]
                    )
                ],
                completedTools: [toolUseId],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: AppLocalization.string("Hooks 审批演示案例"),
                    lastMessage: AppLocalization.string("Hooks 审批演示完成：你刚刚体验了通知、审批提交、处理完成、以及完成提醒。顶部 Island 和独立悬浮宠物会共用这一套流程。"),
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: AppLocalization.string("体验一轮 Ping Island Hooks 审批通知流程"),
                    lastUserMessageDate: now
                )
            ))

            await SessionStore.shared.process(.desktopTurnCompleted(sessionId: sessionId))
            HookWalkthroughDemoBackdropWindowController.shared.dismiss(after: Self.completionDismissDelay)

            try? await Task.sleep(nanoseconds: Self.demoSessionCleanupDelayNanoseconds)
            guard !Task.isCancelled else { return }

            await SessionStore.shared.process(.sessionArchived(sessionId: sessionId))
        }
    }

    static func isDemoIntervention(_ intervention: SessionIntervention) -> Bool {
        intervention.metadata["source"] == metadataSource
    }

    private func closeDockedNotchAfterAnswerIfNeeded() {
        guard AppSettings.surfaceMode == .notch else { return }
        NotificationCenter.default.post(
            name: .pingIslandHookWalkthroughDemoShouldCloseNotch,
            object: nil
        )
    }

    private static func notificationEvent(
        sessionId: String,
        cwd: String,
        clientInfo: SessionClientInfo
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: "Notification",
            status: "processing",
            provider: .codex,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "hook_walkthrough",
            message: AppLocalization.string("正在触发一轮 Hooks 审批演示：通知、审批提交、完成提醒。")
        )
    }

    private static func questionEvent(
        sessionId: String,
        cwd: String,
        clientInfo: SessionClientInfo,
        toolUseId: String
    ) -> HookEvent {
        let toolInput: [String: AnyCodable] = [
            "questions": AnyCodable([
                [
                    "id": "demo_next_step",
                    "header": "1.",
                    "question": AppLocalization.string("是否批准 Ping Island 继续完成这轮演示？"),
                    "description": AppLocalization.string("选择“批准并继续”，再点击提交，Ping Island 会模拟处理完成并弹出通知。"),
                    "options": [
                        [
                            "id": "approve",
                            "label": AppLocalization.string("批准并继续"),
                            "description": AppLocalization.string("模拟你批准 agent 继续执行。")
                        ],
                        [
                            "id": "review",
                            "label": AppLocalization.string("检查后继续"),
                            "description": AppLocalization.string("模拟先查看风险，再批准继续。")
                        ]
                    ]
                ]
            ])
        ]

        return HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: "Notification",
            status: "waiting_for_input",
            provider: .codex,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: "hook_walkthrough_question",
            message: AppLocalization.string("Ping Island Demo 正在等待一次演示审批。"),
            bridgeIntervention: SessionIntervention(
                id: toolUseId,
                kind: .question,
                title: AppLocalization.string("Ping Island Demo 的审批"),
                message: AppLocalization.string("请选择“批准并继续”，然后点击提交。提交后会模拟 agent 继续执行并完成。"),
                options: [],
                questions: [
                    SessionInterventionQuestion(
                        id: "demo_next_step",
                        header: "1.",
                        prompt: AppLocalization.string("是否批准 Ping Island 继续完成这轮演示？"),
                        detail: AppLocalization.string("选择“批准并继续”，再点击提交，Ping Island 会模拟处理完成并弹出通知。"),
                        options: [
                            SessionInterventionOption(
                                id: "approve",
                                title: AppLocalization.string("批准并继续"),
                                detail: AppLocalization.string("模拟你批准 agent 继续执行。")
                            ),
                            SessionInterventionOption(
                                id: "review",
                                title: AppLocalization.string("检查后继续"),
                                detail: AppLocalization.string("模拟先查看风险，再批准继续。")
                            )
                        ],
                        allowsMultiple: false,
                        allowsOther: false,
                        isSecret: false
                    )
                ],
                supportsSessionScope: false,
                metadata: [
                    "source": metadataSource,
                    "originalToolUseId": toolUseId,
                    "toolUseId": toolUseId,
                    "toolName": "AskUserQuestion",
                    "toolInputJSON": Self.toolInputJSONString(from: toolInput) ?? ""
                ]
            )
        )
    }

    private static func demoClientInfo(sessionId: String) -> SessionClientInfo {
        SessionClientInfo(
            kind: .custom,
            profileID: "ping-island-demo",
            name: "Ping Island Demo",
            launchURL: "pingisland://demo/\(sessionId)",
            origin: "demo"
        )
    }

    private static func questionToolUseId(for sessionId: String) -> String {
        "\(sessionId)-ask-user-question"
    }

    private static func toolInputJSONString(from input: [String: AnyCodable]) -> String? {
        let object = input.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
private final class HookWalkthroughDemoBackdropWindowController: NSWindowController {
    static let shared = HookWalkthroughDemoBackdropWindowController()

    private let hostingController = NSHostingController(
        rootView: AppLocalizedRootView {
            HookWalkthroughDemoBackdropView()
        }
    )
    private var dismissWorkItem: DispatchWorkItem?

    private init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        dismissWorkItem?.cancel()
        guard let window else { return }
        let wasVisible = window.isVisible
        let targetScreen = ScreenSelector.shared.selectedScreen ?? NSScreen.main
        if let frame = targetScreen?.frame {
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            window.alphaValue = 0
        }
        showWindow(nil)
        window.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
        }
        dismiss(after: 75)
    }

    func dismiss(after delay: TimeInterval = 0) {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOutAndOrderOut()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func fadeOutAndOrderOut() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 0
        }
    }
}

private struct HookWalkthroughDemoBackdropView: View {
    var body: some View {
        ZStack {
            GlassEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color.black.opacity(0.24)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color(red: 0.04, green: 0.07, blue: 0.09).opacity(0.30),
                    Color.black.opacity(0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                Text(appLocalized: "Ping Island 演示模式")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))

                Text(appLocalized: "请在 Island 弹出的审批卡片中选择并提交。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 58)
        }
    }
}

private struct GlassEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
    }
}
