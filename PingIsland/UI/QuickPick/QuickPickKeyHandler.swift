import SwiftUI
import AppKit
import Combine

/// 键盘事件处理器
struct KeyboardEventHandler: NSViewRepresentable {
    @ObservedObject var service: QuickPickService
    
    func makeNSView(context: Context) -> KeyboardEventNSView {
        let view = KeyboardEventNSView()
        view.service = service
        return view
    }
    
    func updateNSView(_ nsView: KeyboardEventNSView, context: Context) {
        nsView.service = service
    }
}

class KeyboardEventNSView: NSView {
    weak var service: QuickPickService?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        guard let service = service else {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 126: // Up
            service.selectPrevious()
        case 125: // Down
            service.selectNext()
        case 36: // Return
            service.executeSelected()
        case 53: // Escape
            service.hide()
        default:
            // 检测 ⌘+K 切换目录
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
                service.refreshDirectory()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

#Preview {
    QuickPickView(service: QuickPickService.shared)
        .frame(width: 600, height: 60)
}