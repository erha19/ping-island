import SwiftUI

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// Protocol for mascot character views
protocol ProviderMascot: View {
    var status: MascotStatus { get }
    var size: CGFloat { get }
    
    var providerName: String { get }
    var idleIcon: String { get }
    var workingIcon: String { get }
    var warningIcon: String { get }
    
    var idleColor: Color { get }
    var workingColor: Color { get }
    var warningColor: Color { get }
}

/// Default implementation for provider mascots
extension ProviderMascot {
    var body: some View {
        ZStack {
            // Background glow based on status
            Circle()
                .fill(colorForStatus.opacity(0.2))
                .frame(width: size * 1.4, height: size * 1.4)
            
            // Icon with animation
            Image(systemName: iconForStatus)
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(colorForStatus)
                .symbolEffect(.pulse, isActive: status == .working)
                .symbolEffect(.bounce, value: status)
        }
        .frame(width: size, height: size)
    }
    
    private var iconForStatus: String {
        switch status {
        case .idle: return idleIcon
        case .working: return workingIcon
        case .warning: return warningIcon
        }
    }
    
    private var colorForStatus: Color {
        switch status {
        case .idle: return idleColor
        case .working: return workingColor
        case .warning: return warningColor
        }
    }
}

// MARK: - Claude Mascot
struct ClaudeMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Claude"
    let idleIcon = "brain"
    let workingIcon = "brain.head.profile"
    let warningIcon = "brain.experimental"
    
    let idleColor = Color(hex: "8B5CF6")       // Purple
    let workingColor = Color(hex: "A78BFA")    // Light purple
    let warningColor = Color(hex: "F59E0B")   // Amber
}

// MARK: - Codex Mascot
struct CodexMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Codex"
    let idleIcon = "chevron.left.forwardslash.chevron.right"
    let workingIcon = "cursorarrow.and.arrow.trianglehead.2"
    let warningIcon = "exclamationmark.triangle"
    
    let idleColor = Color(hex: "10B981")       // Emerald
    let workingColor = Color(hex: "34D399")    // Light green
    let warningColor = Color(hex: "EF4444")    // Red
}

// MARK: - Qoder Mascot
struct QoderMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Qoder"
    let idleIcon = "swift"
    let workingIcon = "hammer"
    let warningIcon = "exclamationmark.bolt"
    
    let idleColor = Color(hex: "F97316")       // Orange
    let workingColor = Color(hex: "FB923C")    // Light orange
    let warningColor = Color(hex: "DC2626")   // Dark red
}

// MARK: - Cursor Mascot
struct CursorMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Cursor"
    let idleIcon = "cursorarrow.click.2"
    let workingIcon = "cursorarrow.motionlines"
    let warningIcon = "cursorarrow.click"
    
    let idleColor = Color(hex: "3B82F6")       // Blue
    let workingColor = Color(hex: "60A5FA")    // Light blue
    let warningColor = Color(hex: "F59E0B")   // Amber
}

// MARK: - Gemini Mascot
struct GeminiMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Gemini"
    let idleIcon = "sparkles"
    let workingIcon = "wand.and.stars"
    let warningIcon = "star.exclamationmark"
    
    let idleColor = Color(hex: "8B5CF6")       // Purple (Google)
    let workingColor = Color(hex: "A78BFA")    // Light purple
    let warningColor = Color(hex: "F59E0B")   // Amber
}

// MARK: - Generic Mascot
struct GenericMascot: ProviderMascot {
    let status: MascotStatus
    var size: CGFloat = 40
    
    let providerName = "Unknown"
    let idleIcon = "questionmark.circle"
    let workingIcon = "gearshape.2"
    let warningIcon = "exclamationmark.circle"
    
    let idleColor = Color.gray
    let workingColor = Color.gray.opacity(0.8)
    let warningColor = Color.orange
}

// MARK: - Main Mascot View that routes to correct provider
struct MascotView: View {
    let provider: SessionProvider
    let status: MascotStatus
    var size: CGFloat = 40
    
    var body: some View {
        switch provider {
        case .claude:
            ClaudeMascot(status: status, size: size)
        case .codex:
            CodexMascot(status: status, size: size)
        }
    }
}

// MARK: - Preview
#Preview("Claude States") {
    HStack(spacing: 20) {
        ClaudeMascot(status: .idle)
        ClaudeMascot(status: .working)
        ClaudeMascot(status: .warning)
    }
    .padding()
}

#Preview("Codex States") {
    HStack(spacing: 20) {
        CodexMascot(status: .idle)
        CodexMascot(status: .working)
        CodexMascot(status: .warning)
    }
    .padding()
}