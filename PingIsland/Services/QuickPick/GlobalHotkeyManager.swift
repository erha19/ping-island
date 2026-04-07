import Foundation
import AppKit
import Carbon.HIToolbox

/// 全局快捷键管理器
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()
    
    private var eventMonitor: Any?
    private var flagsMonitor: Any?
    private var lastModifierCheck: Date = Date()
    private var doubleTapTimer: Timer?
    private var lastTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.3
    
    var onHotkeyPressed: (() -> Void)?
    var onDoubleModifierPressed: (() -> Void)?
    
    private init() {}
    
    /// 启动全局快捷键监听
    func start() {
        // 监听 ⌘+空格
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // 监听修饰键双击 (双击 Command 呼出)
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }
    
    /// 停止监听
    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        // 检测 ⌘+空格
        let commandPressed = event.modifierFlags.contains(.command)
        let spacePressed = event.keyCode == 49 // 空格键
        
        if commandPressed && spacePressed {
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyPressed?()
            }
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let currentTime = Date()
        
        // 检测双击修饰键 (Command)
        if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control) {
            if let lastTime = lastTapTime {
                let interval = currentTime.timeIntervalSince(lastTime)
                if interval < doubleTapInterval && interval > 0 {
                    // 双击检测到
                    DispatchQueue.main.async { [weak self] in
                        self?.onDoubleModifierPressed?()
                    }
                    lastTapTime = nil
                    return
                }
            }
            lastTapTime = currentTime
        }
    }
    
    deinit {
        stop()
    }
}