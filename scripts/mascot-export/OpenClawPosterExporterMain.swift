import AppKit
import Foundation
import SwiftUI

@MainActor
@main
struct OpenClawPosterExporterMain {
    static func main() throws {
        let options = try PosterOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        try options.prepareOutputDirectory()

        let outputURL = options.outputDirectory.appendingPathComponent(options.outputName)
        let posterView = OpenClawPosterView(options: options)
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
    let logoURL: URL
    let mascotURL: URL

    init(arguments: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var outputDirectory = cwd.appendingPathComponent("docs/images", isDirectory: true)
        var outputName = "ping-island-openclaw-poster.png"
        var width = 2800
        var height = 1800
        var iconURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")
        var logoURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/OpenClawLogo.imageset/openclaw-logo.png")
        var mascotURL = cwd.appendingPathComponent("docs/images/mascots/openclaw.gif")

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
            case "--logo":
                index += 1
                logoURL = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments))
            case "--mascot":
                index += 1
                mascotURL = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments))
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
        self.logoURL = logoURL
        self.mascotURL = mascotURL
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
            Usage: render-openclaw-poster.sh [options]

              --output-dir <path>   Output directory (default: docs/images)
              --output-name <name>  Output filename (default: ping-island-openclaw-poster.png)
              --width <pixels>      Canvas width (default: 2800)
              --height <pixels>     Canvas height (default: 1800)
              --icon <path>         NotchCode app icon path
              --logo <path>         OpenClaw logo asset path
              --mascot <path>       OpenClaw mascot asset path
            """
        }
    }
}

private struct OpenClawPosterView: View {
    let options: PosterOptions

    var body: some View {
        ZStack {
            PosterBackground()

            VStack(spacing: 46) {
                header

                HStack(alignment: .top, spacing: 36) {
                    narrativeCard

                    VStack(spacing: 28) {
                        protocolCard
                        conversationCard
                    }
                    .frame(width: 920)
                }

                bottomRibbon
            }
            .padding(.horizontal, 110)
            .padding(.vertical, 90)
        }
    }

    private var header: some View {
        HStack(spacing: 58) {
            logoHero

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Badge(text: "OpenClaw", tint: Color(red: 0.90, green: 0.39, blue: 0.26))
                    Badge(text: "Latest Support", tint: Color(red: 0.98, green: 0.61, blue: 0.20))
                    Badge(text: "NotchCode", tint: Color(red: 0.82, green: 0.54, blue: 0.20))
                }

                Text("NotchCode")
                    .font(.system(size: 132, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))

                Text("OpenClaw 会话，现在看得更完整")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.32, blue: 0.23))

                Text("托管内部 hook，自动启用，再从本地 transcript 回填完整对话。")
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.62, green: 0.49, blue: 0.35))
            }

            Spacer(minLength: 0)
        }
    }

    private var logoHero: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.77, blue: 0.48).opacity(0.9),
                            Color(red: 0.93, green: 0.43, blue: 0.23).opacity(0.24),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 320
                    )
                )
                .frame(width: 560, height: 560)

            if let logoImage = loadedImage(from: options.logoURL) {
                logoImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 300, height: 300)
                    .shadow(color: Color(red: 0.93, green: 0.43, blue: 0.23).opacity(0.18), radius: 26, x: 0, y: 12)
            } else {
                Text("OpenClaw")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.32, blue: 0.23))
            }
        }
        .frame(width: 560, height: 560)
    }

    private var narrativeCard: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                featurePill("managed hooks", icon: "folder.badge.plus")
                featurePill("auto enable", icon: "checkmark.circle")
                featurePill("transcript refill", icon: "text.page.badge.magnifyingglass")
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("不只接住 OpenClaw 事件，还能把聊天内容补回来")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))

                Text("NotchCode 会管理 `~/.openclaw/hooks/ping-island-openclaw`，同步启用 `openclaw.json`，随后从 `~/.openclaw/agents/main/sessions/` 回读会话，避免 UI 只剩下一条入站消息。")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.33, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
            }

            pathCard

            flowDiagram

            VStack(alignment: .leading, spacing: 18) {
                Text("最新版本可见能力")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.30, green: 0.23, blue: 0.17))

                HStack(spacing: 16) {
                    eventPill("内部 hooks 托管", tint: Color(red: 0.95, green: 0.54, blue: 0.20))
                    eventPill("自动启用配置", tint: Color(red: 0.88, green: 0.40, blue: 0.25))
                    eventPill("完整对话回填", tint: Color(red: 0.39, green: 0.73, blue: 0.47))
                    eventPill("压缩阶段感知", tint: Color(red: 0.34, green: 0.58, blue: 0.98))
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 1040, alignment: .topLeading)
        .background(cardBackground)
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("路径与同步链路")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.92, green: 0.82, blue: 0.68))

            Text("~/.openclaw/hooks/ping-island-openclaw")
            Text("~/.openclaw/openclaw.json")
            Text("~/.openclaw/agents/main/sessions/<session-id>.jsonl")
        }
        .font(.system(size: 22, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.94))
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.19, green: 0.17, blue: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var flowDiagram: some View {
        HStack(spacing: 16) {
            FlowStepCard(
                icon: "bolt.horizontal.circle",
                title: "OpenClaw 事件",
                detail: "command、message、session 事件先快速进桥"
            )

            flowArrow

            FlowStepCard(
                icon: "arrow.triangle.branch",
                title: "Island Bridge",
                detail: "统一归一化为 OpenClaw session 流"
            )

            flowArrow

            FlowStepCard(
                icon: "text.page",
                title: "Transcript Sync",
                detail: "轮询本地 session log，把消息和摘要补齐"
            )
        }
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right.circle.fill")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(Color(red: 0.92, green: 0.57, blue: 0.21))
    }

    private var protocolCard: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.45, blue: 0.28).opacity(0.18))
                    .frame(width: 290, height: 290)
                    .blur(radius: 10)

                if let mascotImage = loadedImage(from: options.mascotURL) {
                    mascotImage
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 230, height: 230)
                } else {
                    MascotView(kind: .openclaw, status: .working, size: 220, animationTime: 0.25)
                }
            }
            .frame(width: 300, height: 300)

            VStack(alignment: .leading, spacing: 18) {
                Text("覆盖 OpenClaw 关键事件")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.19, green: 0.14, blue: 0.10))

                Text("内置支持 command / message / session 三类事件，并对 compact / patch 阶段做状态映射。")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
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
            Text("command:new")
            Text("message:received / message:sent")
            Text("session:compact:before / after")
            Text("session:patch / command:stop")
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

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("完整对话视图")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))
                Spacer()
                Text("从 transcript 回填")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.46, blue: 0.29))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))

                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        Text("hi?")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer()

                        Text("14s")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.80))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white.opacity(0.10)))

                        Text("OpenClaw")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.50, green: 0.34, blue: 0.18))
                            )
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("你：先别总结，继续保留上下文。")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.76))

                        Text("OpenClaw：收到。我会继续处理，并在合适的时候再收敛总结。")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        transcriptBadge("不只是 inbound hook")
                        transcriptBadge("还能看到往返消息")
                    }
                }
                .padding(32)
            }
            .frame(maxWidth: .infinity, minHeight: 350)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 2)
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 470, alignment: .topLeading)
        .background(cardBackground)
    }

    private var bottomRibbon: some View {
        HStack(spacing: 18) {
            ribbonTag(icon: "folder.fill.badge.plus", text: "managed hook dir")
            ribbonTag(icon: "checkmark.circle.fill", text: "openclaw.json auto-enable")
            ribbonTag(icon: "text.page.fill", text: "session transcript sync")
            ribbonTag(icon: "message.badge.fill", text: "full conversation preview")
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
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    private func transcriptBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.98, green: 0.80, blue: 0.48))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
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
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.25))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 248, alignment: .topLeading)
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
                    Color(red: 0.99, green: 0.95, blue: 0.89),
                    Color(red: 0.99, green: 0.90, blue: 0.78),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.82, blue: 0.56).opacity(0.56),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 24,
                endRadius: 960
            )

            RadialGradient(
                colors: [
                    Color(red: 0.94, green: 0.42, blue: 0.22).opacity(0.16),
                    .clear,
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 860
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
