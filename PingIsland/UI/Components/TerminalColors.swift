//
//  TerminalColors.swift
//  PingIsland
//
//  Color palette for terminal-style UI
//

import SwiftUI

struct TerminalColors {
    static let claude = Color(red: 0.95, green: 0.67, blue: 0.28)
    static let green = Color(red: 0.4, green: 0.75, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let cyan = Color(red: 0.0, green: 0.8, blue: 0.8)
    static let blue = Color(red: 0.4, green: 0.6, blue: 1.0)
    static let magenta = Color(red: 0.8, green: 0.4, blue: 0.8)
    static let codebuddy = Color(red: 0.68, green: 0.45, blue: 0.98)
    static let qoder = Color(red: 0.12, green: 0.88, blue: 0.56)
    static let dim = Color.white.opacity(0.4)
    static let dimmer = Color.white.opacity(0.2)
    static let prompt = Color(red: 0.85, green: 0.47, blue: 0.34)  // #d97857
    static let background = Color.white.opacity(0.05)
    static let backgroundHover = Color.white.opacity(0.1)
}

extension SessionProvider {
    var brandTint: Color {
        switch self {
        case .claude:
            return TerminalColors.claude
        case .codex:
            return TerminalColors.blue
        }
    }
}

extension SessionClientBrand {
    var tintColor: Color {
        switch self {
        case .claude:
            return TerminalColors.claude
        case .codebuddy:
            return TerminalColors.codebuddy
        case .codex:
            return TerminalColors.blue
        case .qoder:
            return TerminalColors.qoder
        case .neutral:
            return Color.white.opacity(0.72)
        }
    }
}

extension SessionState {
    var clientTintColor: Color {
        clientInfo.brand == .neutral ? provider.brandTint : clientInfo.brand.tintColor
    }
}
