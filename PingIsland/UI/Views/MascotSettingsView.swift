import SwiftUI

/// Client mascot settings and preview page.
struct MascotSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var previewStatus: MascotStatus = .working

    private let automaticSelection = "__auto__"
    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                controlsSection
                clientGridSection
                statusHelpSection
            }
            .padding(24)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLocalized: "客户端宠物")
                .font(.title2.bold())

            Text(appLocalized: "每个客户端都有默认专属形象，你也可以在这里单独改成别的宠物。刘海、会话列表和 hover 预览都会同步使用这里的配置。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                StatChip(
                    title: "客户端",
                    value: "\(MascotClient.allCases.count)"
                )
                StatChip(
                    title: "已自定义",
                    value: "\(settings.customizedMascotClientCount)"
                )

                Spacer()

                Button("恢复全部默认") {
                    settings.resetMascotOverrides()
                }
                .disabled(settings.customizedMascotClientCount == 0)
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(appLocalized: "状态预览")
                    .font(.headline)

                Picker("状态", selection: $previewStatus) {
                    ForEach(MascotStatus.allCases, id: \.self) { status in
                        Text(appLocalized: status.displayName).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var clientGridSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appLocalized: "客户端对应关系")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(MascotClient.allCases) { client in
                    clientCard(for: client)
                }
            }
        }
    }

    private var statusHelpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text(appLocalized: "状态说明")
                .font(.headline)

            StatusRow(
                status: .idle,
                icon: "moon.fill",
                description: "长时间无新消息或会话暂停时，宠物会切到空闲中动作。"
            )

            StatusRow(
                status: .working,
                icon: "bolt.fill",
                description: "会话正在处理、调用工具或压缩上下文时，宠物会切到运行中动作。"
            )

            StatusRow(
                status: .warning,
                icon: "exclamationmark.triangle.fill",
                description: "审批、提问或等待人工介入时，宠物会切到警告状态动作。"
            )
        }
    }

    @ViewBuilder
    private func clientCard(for client: MascotClient) -> some View {
        let selectedMascot = settings.mascotKind(for: client)
        let isCustomized = settings.hasCustomMascot(for: client)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized: client.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(appLocalized: client.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(appLocalized: isCustomized ? "自定义" : "默认")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCustomized ? Color.orange : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isCustomized ? 0.10 : 0.06))
                    )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

                MascotView(kind: selectedMascot, status: previewStatus, size: 52)
                    .padding(14)
            }
            .frame(height: 122)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: AppLocalization.format("所属客户端：%@", AppLocalization.string(client.title)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("宠物形象", selection: selectionBinding(for: client)) {
                Text(
                    verbatim: AppLocalization.format(
                        "跟随 %@ 默认 · %@",
                        AppLocalization.string(client.title),
                        AppLocalization.string(client.defaultMascotKind.subtitle)
                    )
                )
                .tag(automaticSelection)
                ForEach(MascotKind.allCases) { kind in
                    Text(
                        verbatim: AppLocalization.format(
                            "%@ · %@",
                            AppLocalization.string(kind.subtitle),
                            AppLocalization.string(kind.title)
                        )
                    )
                    .tag(kind.rawValue)
                }
            }
            .pickerStyle(.menu)

            if isCustomized {
                Button("恢复这个客户端的默认宠物") {
                    settings.setMascotOverride(nil, for: client)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func selectionBinding(for client: MascotClient) -> Binding<String> {
        Binding(
            get: {
                settings.mascotOverride(for: client)?.rawValue ?? automaticSelection
            },
            set: { newValue in
                let mascot = MascotKind(rawValue: newValue)
                settings.setMascotOverride(mascot, for: client)
            }
        )
    }
}

private struct StatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appLocalized: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

private struct StatusRow: View {
    let status: MascotStatus
    let icon: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(colorForStatus)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalized: status.displayName)
                    .font(.subheadline.bold())
                Text(appLocalized: description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var colorForStatus: Color {
        switch status {
        case .idle:
            return .blue
        case .working:
            return .green
        case .warning:
            return .orange
        case .dragging:
            return .purple
        }
    }
}

#Preview {
    MascotSettingsView()
        .frame(width: 880, height: 760)
}
