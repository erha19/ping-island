import SwiftUI

struct QuickPickView: View {
    @ObservedObject var service: QuickPickService
    @FocusState private var isSearchFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 主搜索框
            HStack(spacing: 12) {
                // 目录选择按钮
                Menu {
                    ForEach(service.availableDirectories) { dir in
                        Button(action: {
                            service.selectDirectory(dir)
                        }) {
                            HStack {
                                Text(dir.displayName)
                                if dir.path == service.currentDirectory {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button(action: {
                        service.refreshDirectory()
                    }) {
                        Label("刷新目录", systemImage: "arrow.clockwise")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text((service.currentDirectory as NSString).lastPathComponent)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                
                // 分隔线
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 1, height: 24)
                
                // 搜索输入框
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("输入命令或搜索...", text: $service.searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        service.executeSelected()
                    }
                
                // 快捷键提示
                Text("⌘␣ 关闭")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: service.searchText) { _ in
            service.selectedIndex = 0
        }
    }
}

struct QuickPickResultRow: View {
    let command: QuickPickCommand
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .frame(width: 24)
                .foregroundColor(isSelected ? .white : .secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text(command.description)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            
            Spacer()
            
            Text(command.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.white.opacity(0.2) : Color.gray.opacity(0.1))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }
}

#Preview {
    QuickPickView(service: QuickPickService.shared)
        .frame(width: 600, height: 60)
}