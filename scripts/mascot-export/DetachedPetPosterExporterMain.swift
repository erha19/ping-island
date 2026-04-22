import AppKit
import Foundation
import SwiftUI

@MainActor
@main
struct DetachedPetPosterExporterMain {
    static func main() throws {
        let options = try PosterOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        try options.prepareOutputDirectory()

        let outputURL = options.outputDirectory.appendingPathComponent(options.outputName)
        let posterView = DetachedPetPosterView(options: options)
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
    let notchPreviewURL: URL

    init(arguments: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var outputDirectory = cwd.appendingPathComponent("docs/images", isDirectory: true)
        var outputName = "ping-island-undocked-pet-feature.png"
        var width = 2800
        var height = 1800
        var iconURL = cwd.appendingPathComponent("PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")
        var notchPreviewURL = cwd.appendingPathComponent("docs/images/notch-panel.png")

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
            case "--notch-preview":
                index += 1
                notchPreviewURL = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments))
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
        self.notchPreviewURL = notchPreviewURL
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
            Usage: render-detached-pet-poster.sh [options]

              --output-dir <path>    Output directory (default: docs/images)
              --output-name <name>   Output filename (default: ping-island-undocked-pet-feature.png)
              --width <pixels>       Canvas width (default: 2800)
              --height <pixels>      Canvas height (default: 1800)
              --icon <path>          App icon path
              --notch-preview <path> Notch preview image path
            """
        }
    }
}

private struct DetachedPetPosterView: View {
    let options: PosterOptions

    private let featureRows = [
        "Drag the mascot out of the notch into a desktop companion.",
        "Hover or click the floating pet to open anchored session bubbles.",
        "Remember the pet position, then right-click it to reopen Settings.",
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.97, blue: 0.93),
                    Color(red: 0.94, green: 0.95, blue: 0.98),
                    Color(red: 0.93, green: 0.95, blue: 0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 1.0, green: 0.67, blue: 0.25).opacity(0.16))
                .frame(width: 760, height: 760)
                .blur(radius: 24)
                .offset(x: -760, y: -420)

            Circle()
                .fill(Color(red: 0.22, green: 0.74, blue: 0.64).opacity(0.15))
                .frame(width: 860, height: 860)
                .blur(radius: 28)
                .offset(x: 760, y: 420)

            VStack(spacing: 44) {
                header

                HStack(alignment: .top, spacing: 38) {
                    featureCard
                        .frame(width: 880)

                    demoCard
                        .frame(width: 1280)
                }

                footer
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 82)
        }
    }

    private var header: some View {
        HStack(spacing: 44) {
            appIcon

            VStack(alignment: .leading, spacing: 16) {
                Text("PING ISLAND 0.4.0")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Color(red: 0.56, green: 0.45, blue: 0.30))

                Text("Pet Undocking")
                    .font(.system(size: 122, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.13, blue: 0.10))

                Text("Turn the notch mascot into a floating desktop companion for fast approvals, follow-ups, and status checks.")
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.40, green: 0.34, blue: 0.28))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var appIcon: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.14),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 220
                    )
                )
                .frame(width: 320, height: 320)

            RoundedRectangle(cornerRadius: 78, style: .continuous)
                .fill(.white.opacity(0.44))
                .overlay(
                    RoundedRectangle(cornerRadius: 78, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 2)
                )
                .frame(width: 256, height: 256)

            if let icon = loadedImage(from: options.iconURL) {
                icon
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 196, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            }
        }
        .frame(width: 320, height: 320)
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            cardLabel("Feature Highlight", accent: Color(red: 1.0, green: 0.67, blue: 0.25))

            Text("A notch that can leave the notch.")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.16, green: 0.13, blue: 0.10))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(featureRows, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 16) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.67, blue: 0.25))
                        .frame(width: 12, height: 12)
                        .padding(.top, 14)

                    Text(bullet)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.22, green: 0.18, blue: 0.14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                featureTag("drag to detach")
                featureTag("anchored bubbles")
                featureTag("remembered position")
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 980, alignment: .topLeading)
        .background(cardBackground)
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            cardLabel("Demo", accent: Color(red: 0.22, green: 0.74, blue: 0.64))

            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1.5)
                    )

                if let preview = loadedImage(from: options.notchPreviewURL) {
                    preview
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 760, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .offset(x: -180, y: -260)
                }

                Path { path in
                    path.move(to: CGPoint(x: 450, y: 240))
                    path.addQuadCurve(
                        to: CGPoint(x: 695, y: 420),
                        control: CGPoint(x: 545, y: 380)
                    )
                }
                .stroke(
                    Color.white.opacity(0.9),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 10])
                )

                FloatingDemoPet()
                    .offset(x: 180, y: 130)

                FloatingDemoBubble()
                    .offset(x: 130, y: -10)
            }
            .frame(height: 980)
        }
        .padding(34)
        .background(cardBackground)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            footerPill("New in 0.4.0")
            footerPill("Pet undocking")
            footerPill("Desktop companion")
            footerPill("Native macOS interaction")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 40, style: .continuous)
            .fill(.white.opacity(0.58))
            .overlay(
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 12)
    }

    private func cardLabel(_ text: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 14, height: 14)

            Text(text.uppercased())
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.34))
        }
    }

    private func featureTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.30, green: 0.24, blue: 0.18))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
    }

    private func footerPill(_ text: String) -> some View {
        Text(text)
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
                    .stroke(.white.opacity(0.92), lineWidth: 2)
            )
    }

    private func loadedImage(from url: URL) -> Image? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
    }
}

private struct FloatingDemoPet: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 220, height: 220)

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color.white.opacity(0.86))
                .frame(width: 180, height: 180)

            MascotView(kind: .claude, status: .dragging, size: 138, animationTime: 0.35)
        }
    }
}

private struct FloatingDemoBubble: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.67, blue: 0.25))
                    .frame(width: 10, height: 10)
                Text("Approvals, follow-ups, and status")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94))
            }

            Text("The floating pet opens anchored bubbles instead of taking over the notch.")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                bubbleTag("hover")
                bubbleTag("click")
                bubbleTag("right-click settings")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 520, alignment: .leading)
        .background(
            FloatingDemoBubbleShape()
                .fill(Color.black.opacity(0.88))
                .overlay(
                    FloatingDemoBubbleShape()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                )
        )
        .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 14)
    }

    private func bubbleTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
    }
}

private struct FloatingDemoBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 30)
        path.move(to: CGPoint(x: rect.minX + 120, y: rect.maxY - 18))
        path.addLine(to: CGPoint(x: rect.minX + 145, y: rect.maxY + 24))
        path.addLine(to: CGPoint(x: rect.minX + 170, y: rect.maxY - 18))
        path.closeSubpath()
        return path
    }
}
