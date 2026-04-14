import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@main
struct MascotPosterExporterMain {
    static func main() throws {
        let options = try PosterOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        try options.prepareOutputDirectory()

        let outputURL = options.outputDirectory.appendingPathComponent(options.outputName)
        switch outputURL.pathExtension.lowercased() {
        case "gif":
            try exportPosterGIF(options: options, outputURL: outputURL)
        default:
            try exportPosterPNG(options: options, outputURL: outputURL)
        }
        print("wrote \(outputURL.path)")
    }

    private static func exportPosterPNG(
        options: PosterOptions,
        outputURL: URL
    ) throws {
        let posterView = MascotPosterView(
            canvasSize: options.canvasSize,
            iconURL: options.iconURL,
            animationTime: nil
        )
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
    }

    private static func exportPosterGIF(
        options: PosterOptions,
        outputURL: URL
    ) throws {
        let frameCount = max(1, Int((options.duration * Double(options.fps)).rounded(.toNearestOrEven)))
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw PosterExportError.failedToEncode(outputURL.path)
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary)

        let frameDelay = 1.0 / Double(options.fps)
        for frameIndex in 0..<frameCount {
            let time = Double(frameIndex) * frameDelay
            let posterView = MascotPosterView(
                canvasSize: options.canvasSize,
                iconURL: options.iconURL,
                animationTime: time
            )
            .frame(width: options.canvasSize.width, height: options.canvasSize.height)

            let renderer = ImageRenderer(content: posterView)
            renderer.scale = 1
            renderer.isOpaque = true
            renderer.proposedSize = .init(width: options.canvasSize.width, height: options.canvasSize.height)

            guard let cgImage = renderer.cgImage else {
                throw PosterExportError.failedToRender(outputURL.path)
            }

            CGImageDestinationAddImage(destination, cgImage, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                ],
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw PosterExportError.failedToEncode(outputURL.path)
        }
    }
}

private struct PosterOptions {
    let outputDirectory: URL
    let outputName: String
    let canvasSize: CGSize
    let iconURL: URL
    let fps: Int
    let duration: TimeInterval

    init(arguments: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var outputDirectory = cwd.appendingPathComponent("docs/images", isDirectory: true)
        var outputName = "ping-island-mascot-poster.png"
        var width = 2800
        var height = 2120
        var iconURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")
        var fps = 18
        var duration = 2.4

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
            case "--fps":
                index += 1
                fps = try Self.intValue(after: argument, at: index, in: arguments)
            case "--duration":
                index += 1
                duration = try Self.doubleValue(after: argument, at: index, in: arguments)
            case "--help", "-h":
                throw PosterExportError.helpText
            default:
                throw PosterExportError.unknownArgument(argument)
            }
            index += 1
        }

        guard width > 0, height > 0, fps > 0, duration > 0 else {
            throw PosterExportError.invalidValue("canvas", "\(width)x\(height) @ \(fps)fps / \(duration)s")
        }

        self.outputDirectory = outputDirectory
        self.outputName = outputName
        self.canvasSize = CGSize(width: width, height: height)
        self.iconURL = iconURL
        self.fps = fps
        self.duration = duration
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

    private static func doubleValue(after flag: String, at index: Int, in arguments: [String]) throws -> TimeInterval {
        let raw = try value(after: flag, at: index, in: arguments)
        guard let value = Double(raw) else {
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
    case missingIcon(String)
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
        case .missingIcon(let path):
            return "Failed to load icon image at \(path)"
        case .helpText:
            return """
            Usage: render-mascot-poster.sh [options]

              --output-dir <path>   Output directory (default: docs/images)
              --output-name <name>  Output filename (default: ping-island-mascot-poster.png)
              --width <pixels>      Canvas width (default: 2800)
              --height <pixels>     Canvas height (default: 2120)
              --icon <path>         App icon path (default: AppIcon 1024 PNG)
              --fps <number>        GIF frame rate (default: 18)
              --duration <seconds>  GIF duration (default: 2.4)
            """
        }
    }
}

private struct MascotPosterView: View {
    let canvasSize: CGSize
    let iconURL: URL
    let animationTime: TimeInterval?

    private let columns = [
        GridItem(.flexible(), spacing: 52),
        GridItem(.flexible(), spacing: 52),
        GridItem(.flexible(), spacing: 52),
        GridItem(.flexible(), spacing: 52),
    ]

    private let mascotTimes: [MascotKind: TimeInterval] = [
        .claude: 0.15,
        .codex: 0.42,
        .gemini: 0.68,
        .hermes: 0.90,
        .qwen: 1.12,
        .opencode: 1.34,
        .cursor: 1.56,
        .qoder: 1.78,
        .codebuddy: 2.00,
        .copilot: 2.22,
    ]

    var body: some View {
        ZStack {
            PosterBackground(animationTime: animationTime)

            VStack(spacing: 44) {
                header
                mascotGrid
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 84)
        }
    }

    private var header: some View {
        HStack(spacing: 72) {
            appIconHero

            VStack(alignment: .leading, spacing: 22) {
                Text("Ping Island")
                    .font(.system(size: 138, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.08))

                Text("Dynamic Island-style AI coding monitor")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.24))

                Text("App icon + live-rendered mascot lineup")
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.63, green: 0.51, blue: 0.36))
            }

            Spacer(minLength: 0)
        }
    }

    private var mascotGrid: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 44) {
            ForEach(MascotKind.allCases) { kind in
                mascotCard(for: kind)
            }
        }
    }

    private var appIconHero: some View {
        let time = animationTime ?? 0.48
        let glowScale = 1 + 0.05 * sin(time * .pi * 2 / 2.4)

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.84, blue: 0.50).opacity(0.8),
                            Color(red: 0.98, green: 0.56, blue: 0.12).opacity(0.18),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 260
                    )
                )
                .frame(width: 520, height: 520)
                .scaleEffect(glowScale)

            RoundedRectangle(cornerRadius: 104, style: .continuous)
                .fill(.white.opacity(0.44))
                .overlay(
                    RoundedRectangle(cornerRadius: 104, style: .continuous)
                        .stroke(.white.opacity(0.85), lineWidth: 3)
                )
                .frame(width: 448, height: 448)
                .shadow(color: Color.black.opacity(0.10), radius: 42, x: 0, y: 20)

            iconImage
                .resizable()
                .interpolation(.high)
                .frame(width: 352, height: 352)
                .clipShape(RoundedRectangle(cornerRadius: 76, style: .continuous))
                .rotationEffect(.degrees(1.5 * sin(time * .pi / 1.8)))
        }
        .frame(width: 540, height: 540)
    }

    private var iconImage: Image {
        guard let nsImage = NSImage(contentsOf: iconURL) else {
            fatalError(PosterExportError.missingIcon(iconURL.path).localizedDescription)
        }
        return Image(nsImage: nsImage)
    }

    private func mascotCard(for kind: MascotKind) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(kind.alertColor.opacity(0.20))
                    .frame(width: 176, height: 176)
                    .blur(radius: 16)

                MascotView(
                    kind: kind,
                    status: .working,
                    size: 164,
                    animationTime: (mascotTimes[kind] ?? 0.2) + (animationTime ?? 0.0)
                )
            }
            .frame(height: 226)

            VStack(spacing: 8) {
                Text(kind.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.17, green: 0.13, blue: 0.10))
                    .multilineTextAlignment(.center)

                Text(kind.subtitle)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.49, green: 0.40, blue: 0.29))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 332)
        .background(
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(.white.opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 20, x: 0, y: 12)
    }
}

private struct PosterBackground: View {
    let animationTime: TimeInterval?

    var body: some View {
        let time = animationTime ?? 0.0

        ZStack {
            Color.white

            Circle()
                .fill(Color(red: 1.0, green: 0.65, blue: 0.28).opacity(0.28))
                .frame(width: 880, height: 880)
                .blur(radius: 130)
                .offset(x: -760 + 30 * sin(time * .pi / 1.6), y: -520)

            Circle()
                .fill(Color(red: 0.28, green: 0.78, blue: 0.99).opacity(0.24))
                .frame(width: 980, height: 980)
                .blur(radius: 150)
                .offset(x: 820 + 24 * cos(time * .pi / 1.8), y: -360)

            Circle()
                .fill(Color(red: 0.37, green: 0.91, blue: 0.66).opacity(0.20))
                .frame(width: 920, height: 920)
                .blur(radius: 150)
                .offset(x: -600, y: 620 + 22 * sin(time * .pi / 1.7))

            RoundedRectangle(cornerRadius: 240, style: .continuous)
                .fill(Color(red: 0.95, green: 0.60, blue: 0.94).opacity(0.12))
                .frame(width: 1200, height: 520)
                .blur(radius: 120)
                .rotationEffect(.degrees(-12))
                .offset(x: 720, y: 560)
        }
    }
}
