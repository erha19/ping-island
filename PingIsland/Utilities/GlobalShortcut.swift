import AppKit
import Carbon.HIToolbox

struct GlobalShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt16
    let modifierFlagsRawValue: UInt

    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let sanitized = Self.sanitizedModifierFlags(modifierFlags)
        guard !sanitized.isEmpty else { return nil }

        self.keyCode = keyCode
        self.modifierFlagsRawValue = sanitized.rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var displayParts: [String] {
        modifierSymbols + [keyDisplay]
    }

    var displayString: String {
        displayParts.joined(separator: " ")
    }

    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0

        if modifierFlags.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifierFlags.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifierFlags.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.command) {
            flags |= UInt32(cmdKey)
        }

        return flags
    }

    private var modifierSymbols: [String] {
        var symbols: [String] = []

        if modifierFlags.contains(.control) {
            symbols.append("\u{2303}")
        }
        if modifierFlags.contains(.option) {
            symbols.append("\u{2325}")
        }
        if modifierFlags.contains(.shift) {
            symbols.append("\u{21E7}")
        }
        if modifierFlags.contains(.command) {
            symbols.append("\u{2318}")
        }

        return symbols
    }

    private var keyDisplay: String {
        if let keyDisplay = Self.keyDisplayMap[Int(keyCode)] {
            return keyDisplay
        }

        return "Key \(keyCode)"
    }

    private static func sanitizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command])
    }

    private static let keyDisplayMap: [Int: String] = [
        Int(kVK_ANSI_A): "A",
        Int(kVK_ANSI_B): "B",
        Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_D): "D",
        Int(kVK_ANSI_E): "E",
        Int(kVK_ANSI_F): "F",
        Int(kVK_ANSI_G): "G",
        Int(kVK_ANSI_H): "H",
        Int(kVK_ANSI_I): "I",
        Int(kVK_ANSI_J): "J",
        Int(kVK_ANSI_K): "K",
        Int(kVK_ANSI_L): "L",
        Int(kVK_ANSI_M): "M",
        Int(kVK_ANSI_N): "N",
        Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_P): "P",
        Int(kVK_ANSI_Q): "Q",
        Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_S): "S",
        Int(kVK_ANSI_T): "T",
        Int(kVK_ANSI_U): "U",
        Int(kVK_ANSI_V): "V",
        Int(kVK_ANSI_W): "W",
        Int(kVK_ANSI_X): "X",
        Int(kVK_ANSI_Y): "Y",
        Int(kVK_ANSI_Z): "Z",
        Int(kVK_ANSI_0): "0",
        Int(kVK_ANSI_1): "1",
        Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3",
        Int(kVK_ANSI_4): "4",
        Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6",
        Int(kVK_ANSI_7): "7",
        Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9",
        Int(kVK_ANSI_Minus): "-",
        Int(kVK_ANSI_Equal): "=",
        Int(kVK_ANSI_LeftBracket): "[",
        Int(kVK_ANSI_RightBracket): "]",
        Int(kVK_ANSI_Backslash): "\\",
        Int(kVK_ANSI_Semicolon): ";",
        Int(kVK_ANSI_Quote): "'",
        Int(kVK_ANSI_Comma): ",",
        Int(kVK_ANSI_Period): ".",
        Int(kVK_ANSI_Slash): "/",
        Int(kVK_ANSI_Grave): "`",
        Int(kVK_Space): "Space",
        Int(kVK_Return): "Return",
        Int(kVK_Tab): "Tab",
        Int(kVK_Delete): "Delete",
        Int(kVK_ForwardDelete): "Fn-Delete",
        Int(kVK_Escape): "Esc",
        Int(kVK_LeftArrow): "\u{2190}",
        Int(kVK_RightArrow): "\u{2192}",
        Int(kVK_UpArrow): "\u{2191}",
        Int(kVK_DownArrow): "\u{2193}",
        Int(kVK_Home): "Home",
        Int(kVK_End): "End",
        Int(kVK_PageUp): "Page Up",
        Int(kVK_PageDown): "Page Down",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12"
    ]
}

enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    case openActiveSession
    case openSessionList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openActiveSession:
            return "展开活跃会话"
        case .openSessionList:
            return "展开会话列表"
        }
    }

    var shortTitle: String {
        switch self {
        case .openActiveSession:
            return "活跃会话"
        case .openSessionList:
            return "会话列表"
        }
    }

    var subtitle: String {
        switch self {
        case .openActiveSession:
            return "优先打开最近需要关注或正在运行的会话。"
        case .openSessionList:
            return "直接展开灵动码的会话列表视图。"
        }
    }

    var defaultShortcut: GlobalShortcut? {
        switch self {
        case .openActiveSession:
            return GlobalShortcut(
                keyCode: UInt16(kVK_ANSI_J),
                modifierFlags: [.option]
            )
        case .openSessionList:
            return GlobalShortcut(
                keyCode: UInt16(kVK_ANSI_L),
                modifierFlags: [.option]
            )
        }
    }

    var legacyDefaultShortcuts: [GlobalShortcut] {
        switch self {
        case .openActiveSession:
            return [
                GlobalShortcut(
                    keyCode: UInt16(kVK_ANSI_J),
                    modifierFlags: [.option, .command]
                ),
                GlobalShortcut(
                    keyCode: UInt16(kVK_ANSI_J),
                    modifierFlags: [.control, .option, .command]
                )
            ].compactMap { $0 }
        case .openSessionList:
            return [
                GlobalShortcut(
                    keyCode: UInt16(kVK_ANSI_L),
                    modifierFlags: [.option, .command]
                ),
                GlobalShortcut(
                    keyCode: UInt16(kVK_ANSI_L),
                    modifierFlags: [.control, .option, .command]
                )
            ].compactMap { $0 }
        }
    }

    var carbonID: UInt32 {
        switch self {
        case .openActiveSession:
            return 1
        case .openSessionList:
            return 2
        }
    }
}
