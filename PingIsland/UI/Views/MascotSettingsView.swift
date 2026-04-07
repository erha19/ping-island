import SwiftUI

/// Mascot character settings view
struct MascotSettingsView: View {
    @State private var selectedProvider: SessionProvider = .claude
    @State private var previewStatus: MascotStatus = .working
    @State private var showMascot = true
    @State private var mascotSize: Double = 40
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("角色形象")
                        .font(.title2.bold())
                    Text("为每个 AI 工具显示独特的像素风格角色")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // Toggle settings
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("显示角色形象", isOn: $showMascot)
                        .font(.headline)
                    
                    HStack {
                        Text("角色大小")
                        Slider(value: $mascotSize, in: 24...64, step: 8)
                        Text("\(Int(mascotSize))px")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    .disabled(!showMascot)
                }
                
                Divider()
                
                // Preview section
                VStack(alignment: .leading, spacing: 16) {
                    Text("预览")
                        .font(.headline)
                    
                    // Provider selector
                    Picker("工具", selection: $selectedProvider) {
                        Text("Claude").tag(SessionProvider.claude)
                        Text("Codex").tag(SessionProvider.codex)
                    }
                    .pickerStyle(.segmented)
                    
                    // Status selector
                    Picker("状态", selection: $previewStatus) {
                        ForEach(MascotStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    // Mascot preview
                    HStack {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(width: 120, height: 120)
                            
                            if showMascot {
                                MascotView(provider: selectedProvider, status: previewStatus, size: mascotSize)
                            } else {
                                Image(systemName: "face.dashed")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                
                Divider()
                
                // Status explanations
                VStack(alignment: .leading, spacing: 12) {
                    Text("状态说明")
                        .font(.headline)
                    
                    StatusRow(
                        status: .idle,
                        icon: "moon.fill",
                        description: "会话空闲，AI 正在等待用户输入"
                    )
                    
                    StatusRow(
                        status: .working,
                        icon: "bolt.fill",
                        description: "AI 正在处理任务，调用工具或生成回复"
                    )
                    
                    StatusRow(
                        status: .warning,
                        icon: "exclamationmark.triangle.fill",
                        description: "需要用户审批或输入"
                    )
                }
            }
            .padding(24)
        }
    }
}

struct StatusRow: View {
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
                Text(status.displayName)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var colorForStatus: Color {
        switch status {
        case .idle: return .blue
        case .working: return .green
        case .warning: return .orange
        }
    }
}

#Preview {
    MascotSettingsView()
        .frame(width: 500, height: 600)
}