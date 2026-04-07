import SwiftUI
import AppKit

/// 处理键盘事件的 Coordinator
class QuickPickKeyHandler: NSObject {
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCommandK: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow
            onUpArrow?()
        case 125: // Down arrow
            onDownArrow?()
        case 53: // Escape
            onEscape?()
        default:
            // 检测 ⌘+K
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
                onCommandK?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// 带键盘事件处理的 QuickPickView
struct QuickPickContainerView: View {
    @ObservedObject var service: QuickPickService
    @StateObject private var keyHandler = KeyHandler()
    
    var body: some View {
        QuickPickView(service: service)
            .background(KeyboardEventHandler(service: service))
    }
}

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

class KeyHandler: NSObject, ObservableObject {}

#Preview {
    QuickPickContainerView(service: QuickPickService.shared)
        .frame(width: 600, height: 60)
}