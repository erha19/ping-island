//
//  AICOSMissionPanelView.swift
//  PingIsland
//
//  Pick an AI-COS protocol level, copy a paste prompt, and open the selected agent.
//

import AppKit
import SwiftUI

struct AICOSMissionPanelView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    var onClose: (() -> Void)? = nil

    @State private var level: AICOSExecutionLevel = .l2
    @State private var statusMessage: String?
    @State private var isLaunching = false
    @State private var showProtocolRootMissing = false

    private var languageCode: String {
        settings.appLanguage.resolvedLanguageCode()
    }

    private var launchTarget: ManagedHookClientProfile? {
        AICOSLaunchTargetResolver.resolvedProfile()
    }

    private var launchTargetTitle: String {
        launchTarget?.title
            ?? AppLocalization.string("未选择可启动的 Agent")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(appLocalized: "AI-COS Mission")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                if let onClose {
                    Button(AppLocalization.string("关闭")) { onClose() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            labeledField(AppLocalization.string("协议")) {
                Picker(AppLocalization.string("协议"), selection: $level) {
                    ForEach(AICOSExecutionLevel.allCases) { value in
                        Text(value.title(languageCode: languageCode)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text(level.protocolSummary(languageCode: languageCode).trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .id("\(languageCode)-\(level.rawValue)-summary")

            if showProtocolRootMissing {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appLocalized: "未找到 PROTOCOL.md。请先在 设置 → 集成 中配置 AI-COS 技能路径。")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(AppLocalization.string("打开集成设置")) {
                        SettingsWindowController.shared.present(category: .integration)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                }
            }

            Button(action: launchMission) {
                HStack {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isLaunching
                         ? AppLocalization.string("启动中…")
                         : launchButtonTitle)
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundColor(.white.opacity(canLaunch ? 0.95 : 0.4))
                .background(Color.accentColor.opacity(canLaunch ? 0.35 : 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canLaunch || isLaunching)

            Text(launchHint)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .environment(\.locale, settings.locale)
        .onAppear(perform: bootstrapDefaults)
    }

    private var launchHint: String {
        if isProtocolRootReady {
            return AppLocalization.format(
                "将复制 AI-COS %@ 启动词并打开 %@。粘贴一次即可应用协议。",
                level.displayName,
                launchTargetTitle
            )
        }
        return AppLocalization.string("请先在 设置 → 集成 中配置 AI-COS 技能路径。")
    }

    private var isProtocolRootReady: Bool {
        !showProtocolRootMissing
    }

    private var canLaunch: Bool {
        isProtocolRootReady && !isLaunching
    }

    private var launchButtonTitle: String {
        guard let launchTarget else {
            return AppLocalization.string("复制协议并打开 Agent")
        }
        return AppLocalization.format("复制协议并打开 %@", launchTarget.title)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            content()
        }
    }

    private func bootstrapDefaults() {
        if let recent = AICOSMissionHistoryStore.loadRecent() {
            level = recent.level
        }
        refreshProtocolRootAvailability()
    }

    private func refreshProtocolRootAvailability() {
        showProtocolRootMissing = !AICOSProtocolCatalog.protocolRootExists()
    }

    private func launchMission() {
        refreshProtocolRootAvailability()
        guard isProtocolRootReady, !isLaunching else { return }

        isLaunching = true
        statusMessage = nil

        let protocolRootPath = AICOSProtocolCatalog.resolvedProtocolRoot().path
        let draft = AICOSMissionDraft(
            level: level,
            selectedSkillIDs: AICOSProtocolCatalog.defaultSelectedSkillIDs(for: level),
            protocolRootPath: protocolRootPath
        )
        let languageCode = self.languageCode
        let profile = launchTarget

        Task { @MainActor in
            defer { isLaunching = false }

            let pack = AICOSMissionPackBuilder.build(draft: draft, languageCode: languageCode)
            AICOSMissionPackBuilder.copyPromptToClipboard(pack.clipboardPrompt)
            AICOSMissionHistoryStore.saveRecent(draft)

            let activated = await AICOSCodexActivator.activate(
                profile: profile,
                workspacePath: "",
                matchingSessions: sessionMonitor.instances
            )

            if activated {
                statusMessage = AppLocalization.format(
                    "已复制 AI-COS %@ 启动词。%@ 已前置 — 粘贴即可开始。",
                    level.displayName,
                    launchTargetTitle
                )
            } else {
                statusMessage = AppLocalization.format(
                    "启动词已复制，但未能打开 %@。请手动启动后粘贴。",
                    launchTargetTitle
                )
            }
        }
    }
}
