import Foundation
import AppKit
import SwiftUI
import Combine

/// QuickPick 主服务
final class QuickPickService: NSObject, ObservableObject {
    static let shared = QuickPickService()
    
    @Published var isVisible = false
    @Published var searchText = ""
    @Published var selectedIndex = 0
    @Published var currentDirectory: String
    @Published var availableDirectories: [QuickPickDirectory] = []
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<QuickPickView>?
    private let hotkeyManager = GlobalHotkeyManager.shared
    private let directoryDetector = DirectoryDetector.shared
    
    private var filteredCommands: [QuickPickCommand] = QuickPickCommand.defaultCommands
    
    var onCommandSelected: ((QuickPickCommand) -> Void)?
    
    private override init() {
        currentDirectory = DirectoryDetector.shared.detectCurrentDirectory()
        super.init()
        loadDirectories()
        setupPanel()
        setupHotkey()
    }
    
    /// 加载可用目录
    private func loadDirectories() {
        let projectDirs = directoryDetector.scanProjectDirectories()
        availableDirectories = projectDirs.map { QuickPickDirectory(path: $0, name: ($0 as NSString).lastPathComponent) }
        
        // 添加当前目录到列表开头（如果不在列表中）
        let currentDirName = (currentDirectory as NSString).lastPathComponent
        if !availableDirectories.contains(where: { $0.path == currentDirectory }) {
            availableDirectories.insert(QuickPickDirectory(path: currentDirectory, name: currentDirName), at: 0)
        }
    }
    
    /// 设置浮动面板
    private func setupPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 60)
        
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let panel = panel else { return }
        
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        
        let quickPickView = QuickPickView(service: self)
        hostingView = NSHostingView(rootView: quickPickView)
        hostingView?.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hostingView
        
        panel.delegate = self
    }
    
    /// 设置全局快捷键
    private func setupHotkey() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.toggle()
        }
        
        hotkeyManager.onDoubleModifierPressed = { [weak self] in
            self?.toggle()
        }
        
        hotkeyManager.start()
    }
    
    /// 切换显示状态
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    /// 显示面板
    func show() {
        // 刷新目录
        currentDirectory = directoryDetector.detectCurrentDirectory()
        loadDirectories()
        
        // 重置状态
        searchText = ""
        selectedIndex = 0
        
        // 显示面板在屏幕中央
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = 600
            let panelHeight: CGFloat = 60
            
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - panelHeight - 50 // 顶部间距
            
            panel?.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }
        
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        isVisible = true
    }
    
    /// 隐藏面板
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
    
    /// 刷新当前目录
    func refreshDirectory() {
        currentDirectory = directoryDetector.detectCurrentDirectory()
        loadDirectories()
    }
    
    /// 执行选中命令
    func executeSelected() {
        let commands = getFilteredCommands()
        guard selectedIndex < commands.count else { return }
        
        let command = commands[selectedIndex]
        onCommandSelected?(command)
        
        // 执行命令
        CommandExecutor.shared.executeInTerminal(command.command, in: currentDirectory)
        
        hide()
    }
    
    /// 切换到指定目录
    func selectDirectory(_ directory: QuickPickDirectory) {
        currentDirectory = directory.path
    }
    
    /// 获取过滤后的命令列表
    func getFilteredCommands() -> [QuickPickCommand] {
        guard !searchText.isEmpty else {
            return QuickPickCommand.defaultCommands
        }
        
        let lowercased = searchText.lowercased()
        return QuickPickCommand.defaultCommands.filter { command in
            command.name.lowercased().contains(lowercased) ||
            command.command.lowercased().contains(lowercased)
        }
    }
    
    /// 向上选择
    func selectPrevious() {
        let commands = getFilteredCommands()
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else {
            selectedIndex = commands.count - 1
        }
    }
    
    /// 向下选择
    func selectNext() {
        let commands = getFilteredCommands()
        if selectedIndex < commands.count - 1 {
            selectedIndex += 1
        } else {
            selectedIndex = 0
        }
    }
}

// MARK: - NSWindowDelegate
extension QuickPickService: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // 点击外部时隐藏
        hide()
    }
}