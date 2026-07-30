//
//  LocalSkillManagerPanelView.swift
//  PingIsland
//
//  Browse local skills, copy a paste prompt, open the routed agent, and manage symlinks.
//

import AppKit
import SwiftUI

struct LocalSkillManagerPanelView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    var onClose: (() -> Void)? = nil

    @State private var skills: [LocalSkill] = []
    @State private var selectedSkillID: String = ""
    @State private var registry = SkillRouteRegistrySnapshot.empty
    @State private var statusMessage: String?
    @State private var isLaunching = false
    @State private var showLinkPicker = false

    private var languageCode: String {
        settings.appLanguage.resolvedLanguageCode()
    }

    private var installedLaunchProfiles: [ManagedHookClientProfile] {
        AICOSLaunchTargetResolver.installedProfiles { HookInstaller.isInstalled($0) }
    }

    private var selectedSkill: LocalSkill? {
        skills.first(where: { $0.id == selectedSkillID }) ?? skills.first
    }

    private var skillSelection: Binding<String> {
        Binding(
            get: {
                if skills.contains(where: { $0.id == selectedSkillID }) {
                    return selectedSkillID
                }
                return skills.first?.id ?? ""
            },
            set: { newValue in
                selectedSkillID = newValue
                showLinkPicker = false
                statusMessage = nil
            }
        )
    }

    private var launchTarget: ManagedHookClientProfile? {
        guard let skill = selectedSkill else {
            return AICOSLaunchTargetResolver.resolve(
                storedProfileID: registry.global_launch_profile_id,
                installed: installedLaunchProfiles
            )
        }
        return SkillRouteRegistry.resolveLaunchProfile(
            for: skill.id,
            snapshot: registry,
            installed: installedLaunchProfiles
        )
    }

    private var launchTargetTitle: String {
        launchTarget?.title ?? AppLocalization.string("未选择可启动的 Agent")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(appLocalized: "本地技能")
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

            if skills.isEmpty {
                Text(appLocalized: "未发现本地技能。可在 设置 → 集成 → 本地技能 中添加根目录。")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                labeledField(AppLocalization.string("技能")) {
                    Picker(AppLocalization.string("技能"), selection: skillSelection) {
                        ForEach(skills) { skill in
                            Text(verbatim: "\(skill.name) · \(skill.sourceLabel)").tag(skill.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if let skill = selectedSkill {
                VStack(alignment: .leading, spacing: 4) {
                    if let description = skill.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(AppLocalization.format("来源：%@ · 启动：%@", skill.sourceLabel, launchTargetTitle))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }

                if installedLaunchProfiles.isEmpty {
                    Text(appLocalized: "请先在 设置 → 集成 中安装至少一个 Agent")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.9))
                } else {
                    labeledField(AppLocalization.string("本技能启动覆盖")) {
                        Picker(
                            AppLocalization.string("本技能启动覆盖"),
                            selection: launchOverrideBinding(for: skill)
                        ) {
                            Text(appLocalized: "使用全局默认").tag("")
                            ForEach(installedLaunchProfiles) { profile in
                                Text(verbatim: profile.title).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                Button(action: { copyAndOpen(skill) }) {
                    HStack {
                        if isLaunching {
                            ProgressView().controlSize(.small)
                        }
                        Text(primaryButtonTitle)
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

                Button(action: { showLinkPicker.toggle() }) {
                    Text(appLocalized: "链接到 Agent…")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(.white.opacity(0.85))
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(installedLaunchProfiles.isEmpty)

                if showLinkPicker {
                    linkPicker(for: skill)
                }
            }

            Text(appLocalized: "复制技能提示并打开 Agent；可在中央路由中管理 symlink。")
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
        .onAppear(perform: reload)
    }

    private var canLaunch: Bool {
        selectedSkill != nil && !isLaunching
    }

    private var primaryButtonTitle: String {
        AppLocalization.format("复制并打开 %@", launchTargetTitle)
    }

    private func linkPicker(for skill: LocalSkill) -> some View {
        let linked = Set(registry.routes[skill.id]?.linked_profile_ids ?? [])
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(installedLaunchProfiles) { profile in
                let isOn = linked.contains(profile.id)
                Button {
                    toggleLink(skill: skill, profile: profile, currentlyLinked: isOn)
                } label: {
                    HStack {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isOn ? TerminalColors.green : .white.opacity(0.35))
                        Text(verbatim: profile.title)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Text(linkStatusLabel(skill: skill, profile: profile))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func linkStatusLabel(skill: LocalSkill, profile: ManagedHookClientProfile) -> String {
        switch SkillSymlinkLinker.linkStatus(skill: skill, profile: profile) {
        case .linked:
            return AppLocalization.string("已链接")
        case .missing, .skillsDirectoryMissing:
            return AppLocalization.string("未链接")
        case .conflict:
            return AppLocalization.string("冲突")
        }
    }

    private func launchOverrideBinding(for skill: LocalSkill) -> Binding<String> {
        Binding(
            get: { registry.routes[skill.id]?.launch_profile_id ?? "" },
            set: { newValue in
                SkillRouteRegistry.setLaunchOverride(
                    skillID: skill.id,
                    profileID: newValue.isEmpty ? nil : newValue
                )
                registry = SkillRouteRegistry.load()
            }
        )
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            content()
        }
    }

    private func reload() {
        registry = SkillRouteRegistry.load()
        skills = LocalSkillCatalog.discover(manualRoots: registry.manual_roots)
        if selectedSkillID.isEmpty || !skills.contains(where: { $0.id == selectedSkillID }) {
            selectedSkillID = skills.first?.id ?? ""
        }
    }

    private func toggleLink(skill: LocalSkill, profile: ManagedHookClientProfile, currentlyLinked: Bool) {
        var linked = registry.routes[skill.id]?.linked_profile_ids ?? []
        if currentlyLinked {
            linked.removeAll { $0 == profile.id }
        } else if !linked.contains(profile.id) {
            linked.append(profile.id)
        }
        SkillRouteRegistry.setLinkedProfileIDs(skillID: skill.id, profileIDs: linked)
        registry = SkillRouteRegistry.load()
        let results = SkillSymlinkLinker.applyLinks(skill: skill, desiredProfileIDs: linked)
        if case .conflict = results[profile.id] {
            statusMessage = AppLocalization.format(
                "无法链接到 %@：目标位置已存在非符号链接文件。",
                profile.title
            )
        } else if currentlyLinked {
            statusMessage = AppLocalization.format("已取消 %@ 的链接。", profile.title)
        } else {
            statusMessage = AppLocalization.format("已链接到 %@。", profile.title)
        }
    }

    private func copyAndOpen(_ skill: LocalSkill) {
        guard !isLaunching else { return }
        isLaunching = true
        statusMessage = nil
        let profile = launchTarget
        let prompt = SkillPasteBuilder.buildPrompt(for: skill, languageCode: languageCode)

        Task { @MainActor in
            defer { isLaunching = false }
            SkillPasteBuilder.copyPromptToClipboard(prompt)
            SkillUsageStore.recordUse(folderName: skill.folderName)
            let activated = await AICOSCodexActivator.activate(
                profile: profile,
                workspacePath: "",
                matchingSessions: sessionMonitor.instances
            )
            if activated {
                statusMessage = AppLocalization.format(
                    "已复制技能提示。%@ 已前置 — 粘贴即可开始。",
                    launchTargetTitle
                )
            } else {
                statusMessage = AppLocalization.format(
                    "技能提示已复制，但未能打开 %@。请手动启动后粘贴。",
                    launchTargetTitle
                )
            }
        }
    }
}
