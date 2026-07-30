import AppKit
import Foundation
import SwiftUI

@MainActor
@main
struct AutoUpdatePosterExporterMain {
    static func main() throws {
        let options = try PosterOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        try options.prepareOutputDirectory()

        let outputURL = options.outputDirectory.appendingPathComponent(options.outputName)
        let posterView = AutoUpdatePosterView(options: options)
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

    init(arguments: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var outputDirectory = cwd.appendingPathComponent("docs/images", isDirectory: true)
        var outputName = "ping-island-auto-update-poster.png"
        var width = 2800
        var height = 1800
        var iconURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")

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
            Usage: render-auto-update-poster.sh [options]

              --output-dir <path>   Output directory (default: docs/images)
              --output-name <name>  Output filename (default: ping-island-auto-update-poster.png)
              --width <pixels>      Canvas width (default: 2800)
              --height <pixels>     Canvas height (default: 1800)
              --icon <path>         App icon path (default: AppIcon 1024 PNG)
            """
        }
    }
}

private struct AutoUpdatePosterView: View {
    let options: PosterOptions

    var body: some View {
        ZStack {
            PosterBackground()

            VStack(spacing: 48) {
                header

                HStack(alignment: .top, spacing: 40) {
                    narrativeCard

                    VStack(spacing: 28) {
                        lifecycleCard
                        promiseCard
                    }
                    .frame(width: 920)
                }

                footerRibbon
            }
            .padding(.horizontal, 110)
            .padding(.vertical, 90)
        }
    }

    private var header: some View {
        HStack(spacing: 58) {
            appIconHero

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Badge(text: "v0.1.0", tint: Color(red: 0.95, green: 0.48, blue: 0.17))
                    Badge(text: "Silent Update", tint: Color(red: 0.24, green: 0.67, blue: 0.42))
                    Badge(text: "Sparkle", tint: Color(red: 0.97, green: 0.72, blue: 0.24))
                }

                Text("NotchCode")
                    .font(.system(size: 134, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))

                Text("0.1.0 支持静默自动更新")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.24))

                Text("启动时检查，空闲时后台更新，准备好后自动安装并重启。")
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
                featurePill("启动即检查", icon: "sparkle.magnifyingglass")
                featurePill("后台自动下载", icon: "arrow.down.circle")
                featurePill("空闲时自动安装", icon: "powerplug")
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("让版本升级像消息提醒一样自然")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))

                Text("0.1.0 合并了 0.0.5 到 0.0.9 的更新能力，并接入 Sparkle 自动更新链路。NotchCode 会在启动和会话空闲时静默检查新版本，后台完成下载与准备。")
                    .font(.system(size: 31, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.33, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
            }

            updateFlow

            VStack(alignment: .leading, spacing: 18) {
                Text("你会看到的更新体验：")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.30, green: 0.23, blue: 0.17))

                HStack(spacing: 16) {
                    eventPill("检查中...", tint: Color(red: 0.24, green: 0.58, blue: 0.98))
                    eventPill("发现 v0.1.0", tint: Color(red: 1.0, green: 0.55, blue: 0.22))
                    eventPill("后台下载", tint: Color(red: 0.96, green: 0.68, blue: 0.22))
                    eventPill("自动重启安装", tint: Color(red: 0.32, green: 0.77, blue: 0.48))
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 980, alignment: .topLeading)
        .background(cardBackground)
    }

    private var updateFlow: some View {
        HStack(spacing: 18) {
            FlowStepCard(
                icon: "play.circle.fill",
                title: "启动检查",
                detail: "应用启动时先静默检查更新源，确保版本信息保持新鲜。"
            )

            flowArrow

            FlowStepCard(
                icon: "arrow.down.circle.fill",
                title: "后台准备",
                detail: "发现新版本后自动下载、解包并准备安装，不打断当前会话。"
            )

            flowArrow

            FlowStepCard(
                icon: "arrow.clockwise.circle.fill",
                title: "空闲安装",
                detail: "没有活跃会话时自动重启安装，让升级尽量无感发生。"
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

    private var lifecycleCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("静默更新状态")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))
                Spacer()
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.46, blue: 0.29))
            }

            VStack(spacing: 16) {
                updateStateRow(title: "检查中...", subtitle: "正在后台检查更新", accent: Color(red: 0.24, green: 0.58, blue: 0.98), progress: 0.28)
                updateStateRow(title: "静默更新中", subtitle: "发现新版本 v0.1.0，将静默下载并安装", accent: Color(red: 1.0, green: 0.58, blue: 0.22), progress: 0.66)
                updateStateRow(title: "安装已就绪", subtitle: "v0.1.0 已就绪，空闲时自动重启安装", accent: Color(red: 0.30, green: 0.75, blue: 0.45), progress: 1.0)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 470, alignment: .topLeading)
        .background(cardBackground)
    }

    private var promiseCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                MiniStat(value: "10 min", label: "空闲检查周期")
                MiniStat(value: "Auto", label: "自动下载")
                MiniStat(value: "0.1.0", label: "版本里程碑")
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("这次升级带来的不是一个按钮，而是一整条更顺滑的更新路径。")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.19, green: 0.14, blue: 0.10))

                Text("你仍然可以手动查看版本历史，但默认体验已经变成：应用自己发现更新、自己下载、自己等到空闲窗口完成安装。")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.44, green: 0.34, blue: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                promiseLine(icon: "checkmark.seal.fill", text: "基于 Sparkle 的签名更新链路")
                promiseLine(icon: "moon.stars.fill", text: "减少手动下载和中断式提醒")
                promiseLine(icon: "menubar.rectangle", text: "仍保留版本历史与更新状态可见性")
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 470, alignment: .topLeading)
        .background(cardBackground)
    }

    private var footerRibbon: some View {
        HStack(spacing: 18) {
            ribbonTag(icon: "sparkles", text: "Silent update")
            ribbonTag(icon: "clock.badge.checkmark", text: "空闲时升级")
            ribbonTag(icon: "arrow.triangle.2.circlepath.circle.fill", text: "自动重启安装")
            ribbonTag(icon: "doc.text.magnifyingglass", text: "可查看更新日志")
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

    private func updateStateRow(
        title: String,
        subtitle: String,
        accent: Color,
        progress: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.10))

                Spacer()

                Text(progress >= 1 ? "Ready" : "\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }

            Text(subtitle)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.25))
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.06))

                    Capsule(style: .continuous)
                        .fill(accent)
                        .frame(width: proxy.size.width * max(0, min(progress, 1)))
                }
            }
            .frame(height: 12)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.98), lineWidth: 2)
        )
    }

    private func promiseLine(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(red: 0.95, green: 0.57, blue: 0.21))

            Text(text)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.16))
        }
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

    var body: some View {
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
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.98), lineWidth: 2)
        )
    }
}

private struct MiniStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.95, green: 0.57, blue: 0.21))

            Text(label)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.47, green: 0.36, blue: 0.26))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 1.0, green: 0.97, blue: 0.92))
        )
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
                    Color(red: 0.35, green: 0.82, blue: 0.60).opacity(0.14),
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
