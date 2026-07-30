import AppKit
import Foundation
import SwiftUI

@MainActor
@main
struct SSHClaudePosterExporterMain {
    static func main() throws {
        let options = try PosterOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        try options.prepareOutputDirectory()

        let outputURL = options.outputDirectory.appendingPathComponent(options.outputName)
        let posterView = SSHClaudePosterView(options: options)
            .frame(width: options.canvasSize.width, height: options.canvasSize.height)

        let renderer = ImageRenderer(content: posterView)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = .init(width: options.canvasSize.width, height: options.canvasSize.height)

        guard let cgImage = renderer.cgImage else {
            throw PosterExportError.failedToRender(outputURL.path)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PosterExportError.failedToEncode(outputURL.path)
        }

        try data.write(to: outputURL, options: .atomic)
        print("wrote \(outputURL.path)")
    }
}

private struct PosterOptions {
    let outputDirectory: URL
    let outputName: String
    let canvasSize: CGSize
    let iconURL: URL
    let previewURL: URL

    init(arguments: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var outputDirectory = cwd.appendingPathComponent("docs/images", isDirectory: true)
        var outputName = "ping-island-ssh-claude-poster.png"
        var width = 2800
        var height = 1800
        var iconURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")
        var previewURL = cwd.appendingPathComponent("docs/images/notch-panel.png")

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                outputDirectory = URL(
                    fileURLWithPath: try Self.value(after: argument, at: index, in: arguments),
                    isDirectory: true
                )
            case "--output-name":
                index += 1
                outputName = try Self.value(after: argument, at: index, in: arguments)
            case "--width":
                index += 1
                width = try Self.intValue(after: argument, at: index, in: arguments)
            case "--height":
                index += 1
                height = try Self.intValue(after: argument, at: index, in: arguments)
            case "--icon":
                index += 1
                iconURL = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments))
            case "--preview":
                index += 1
                previewURL = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments))
            case "--help", "-h":
                throw PosterExportError.helpText
            default:
                throw PosterExportError.unknownArgument(argument)
            }
            index += 1
        }

        guard width > 0, height > 0 else {
            throw PosterExportError.invalidValue("canvas", "\(width)x\(height)")
        }

        self.outputDirectory = outputDirectory
        self.outputName = outputName
        self.canvasSize = CGSize(width: width, height: height)
        self.iconURL = iconURL
        self.previewURL = previewURL
    }

    func prepareOutputDirectory() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private static func value(after flag: String, at index: Int, in arguments: [String]) throws -> String {
        guard arguments.indices.contains(index) else {
            throw PosterExportError.missingValue(flag)
        }
        return arguments[index]
    }

    private static func intValue(after flag: String, at index: Int, in arguments: [String]) throws -> Int {
        let raw = try value(after: flag, at: index, in: arguments)
        guard let value = Int(raw) else {
            throw PosterExportError.invalidValue(flag, raw)
        }
        return value
    }
}

private enum PosterExportError: LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case failedToRender(String)
    case failedToEncode(String)
    case helpText

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "Invalid value for \(flag): \(value)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .failedToRender(let path):
            return "Failed to render poster for \(path)"
        case .failedToEncode(let path):
            return "Failed to encode PNG for \(path)"
        case .helpText:
            return """
            Usage: render-ssh-claude-poster.sh [options]

              --output-dir <path>   Output directory (default: docs/images)
              --output-name <name>  Output filename (default: ping-island-ssh-claude-poster.png)
              --width <pixels>      Canvas width (default: 2800)
              --height <pixels>     Canvas height (default: 1800)
              --icon <path>         App icon path (default: AppIcon 1024 PNG)
              --preview <path>      Notch preview image path (default: docs/images/notch-panel.png)
            """
        }
    }
}

private struct SSHClaudePosterView: View {
    let options: PosterOptions

    var body: some View {
        ZStack {
            PosterBackground()

            VStack(spacing: 48) {
                header

                HStack(alignment: .top, spacing: 40) {
                    narrativeCard
                    VStack(spacing: 30) {
                        claudeFocusCard
                        previewCard
                    }
                    .frame(width: 860)
                }

                bottomRibbon
            }
            .padding(.horizontal, 110)
            .padding(.vertical, 90)
        }
    }

    private var header: some View {
        HStack(spacing: 62) {
            appIconHero

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Badge(text: "SSH Remote", tint: Color(red: 0.97, green: 0.54, blue: 0.20))
                    Badge(text: "Claude Code", tint: MascotKind.claude.alertColor)
                    Badge(text: "NotchCode", tint: Color(red: 0.95, green: 0.73, blue: 0.33))
                }

                Text("NotchCode")
                    .font(.system(size: 134, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))

                Text("支持 SSH 端 Claude Code 监控")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.24))

                Text("远程审批、提问与完成提醒，照样回到你的本机菜单栏。")
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.62, green: 0.50, blue: 0.35))
            }

            Spacer(minLength: 0)
        }
    }

    private var appIconHero: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.82),
                            Color(red: 0.98, green: 0.56, blue: 0.12).opacity(0.18),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 280
                    )
                )
                .frame(width: 560, height: 560)

            RoundedRectangle(cornerRadius: 106, style: .continuous)
                .fill(.white.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 106, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 3)
                )
                .frame(width: 452, height: 452)
                .shadow(color: Color.black.opacity(0.10), radius: 42, x: 0, y: 20)

            if let iconImage = loadedImage(from: options.iconURL) {
                iconImage
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 352, height: 352)
                    .clipShape(RoundedRectangle(cornerRadius: 78, style: .continuous))
            }
        }
        .frame(width: 560, height: 560)
    }

    private var narrativeCard: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                featurePill("自动安装 remote bridge", icon: "point.3.connected.trianglepath.dotted")
                featurePill("改写远端 hooks", icon: "arrow.trianglehead.branch")
                featurePill("双向转发通道", icon: "arrow.left.arrow.right.circle")
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("把远程 Claude Code 会话带回 NotchCode")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))

                Text("添加 SSH 主机后，NotchCode 会在远程机器上部署 bridge，接住 hooks，再把远程事件稳定转发回本机。")
                    .font(.system(size: 31, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.33, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
            }

            flowDiagram

            VStack(alignment: .leading, spacing: 18) {
                Text("你能在本机继续收到：")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.30, green: 0.23, blue: 0.17))

                HStack(spacing: 16) {
                    eventPill("审批提醒", tint: Color(red: 1.0, green: 0.55, blue: 0.22))
                    eventPill("输入提问", tint: Color(red: 0.97, green: 0.66, blue: 0.22))
                    eventPill("任务完成", tint: Color(red: 0.32, green: 0.77, blue: 0.48))
                    eventPill("会话回跳", tint: Color(red: 0.34, green: 0.58, blue: 0.98))
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 980, alignment: .topLeading)
        .background(cardBackground)
    }

    private var flowDiagram: some View {
        HStack(spacing: 18) {
            FlowStepCard(
                icon: "server.rack",
                title: "SSH 主机",
                detail: "连接你的远程 dev box、GPU 机或跳板环境"
            )

            flowArrow

            FlowStepCard(
                icon: "point.3.filled.connected.trianglepath.dotted",
                title: "远程桥接",
                detail: "部署桥接程序，接住并转发远端 hooks"
            )

            flowArrow

            FlowStepCard(
                icon: "menubar.rectangle",
                title: "NotchCode",
                detail: "在本机 notch / 菜单栏继续看见 Claude Code 动态"
            )
        }
    }

    private var flowArrow: some View {
        VStack {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color(red: 0.92, green: 0.57, blue: 0.21))
        }
    }

    private var claudeFocusCard: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(MascotKind.claude.alertColor.opacity(0.22))
                    .frame(width: 280, height: 280)
                    .blur(radius: 10)

                MascotView(
                    kind: .claude,
                    status: .working,
                    size: 230,
                    animationTime: 0.25
                )
            }
            .frame(width: 300, height: 300)

            VStack(alignment: .leading, spacing: 18) {
                Text("SSH 里的 Claude Code")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.19, green: 0.14, blue: 0.10))

                Text("远程终端里跑着 Claude，本机照样盯得住。")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.44, green: 0.34, blue: 0.25))

                terminalSnippet
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
        .background(cardBackground)
    }

    private var terminalSnippet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ssh dev@gpu-box")
            Text("claude")
            Text("审批 / 提问 / 完成提醒")
            Text("回到 NotchCode")
        }
        .font(.system(size: 20, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.94))
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.16, green: 0.18, blue: 0.23))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本机提醒视图")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))
                Spacer()
                Text("macOS notch / 菜单栏")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.46, blue: 0.29))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white.opacity(0.86))

                if let previewImage = loadedImage(from: options.previewURL) {
                    previewImage
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(22)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 78, weight: .semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.58, blue: 0.24))
                        Text("远程 Claude 事件在这里提醒你")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.26, green: 0.20, blue: 0.15))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.95), lineWidth: 2)
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
        .background(cardBackground)
    }

    private var bottomRibbon: some View {
        HStack(spacing: 18) {
            ribbonTag(icon: "checkmark.shield", text: "SSH 接入")
            ribbonTag(icon: "terminal", text: "hooks")
            ribbonTag(icon: "arrow.left.arrow.right", text: "双向转发")
            ribbonTag(icon: "bell.badge.fill", text: "注意力优先提醒")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 40, style: .continuous)
            .fill(.white.opacity(0.54))
            .overlay(
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .stroke(Color.white.opacity(0.94), lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.07), radius: 20, x: 0, y: 12)
    }

    private func loadedImage(from url: URL) -> Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }

    private func featurePill(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .foregroundStyle(Color(red: 0.50, green: 0.33, blue: 0.14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 1.0, green: 0.96, blue: 0.89))
        )
    }

    private func eventPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    private func ribbonTag(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .foregroundStyle(Color(red: 0.29, green: 0.22, blue: 0.16))
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.58))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.94), lineWidth: 2)
        )
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct FlowStepCard: View {
    let icon: String
    let title: String
    let detail: String

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.87, blue: 0.60).opacity(0.35))
                    .frame(width: 72, height: 72)

                Image(systemName: icon)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color(red: 0.95, green: 0.57, blue: 0.21))
            }

            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))

            Text(detail)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.25))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.98), lineWidth: 2)
        )
    }

    var body: some View {
        bodyView
    }
}

private struct PosterBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.96, blue: 0.90),
                    Color(red: 0.98, green: 0.91, blue: 0.80),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.90, blue: 0.63).opacity(0.52),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 24,
                endRadius: 940
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.64, blue: 0.22).opacity(0.16),
                    .clear,
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 820
            )
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 420, height: 420)
                .blur(radius: 10)
                .offset(x: 110, y: -120)
        }
        .overlay(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 170, style: .continuous)
                .fill(Color.white.opacity(0.20))
                .frame(width: 620, height: 240)
                .rotationEffect(.degrees(-12))
                .offset(x: -90, y: 90)
        }
    }
}
