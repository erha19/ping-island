#!/usr/bin/env swift

import AppKit
import Foundation

struct Configuration {
    let outputPath: String
    let width: Int
    let height: Int
}

struct Layout {
    let titleFontSize: CGFloat
    let titleY: CGFloat
    let titleHeight: CGFloat
    let cornerInset: CGFloat
    let cornerLength: CGFloat
    let cornerStroke: CGFloat
    let arrowStart: CGPoint
    let arrowEnd: CGPoint
    let captionRect: NSRect
    let captionFontSize: CGFloat
    let captionKern: CGFloat
    let bottomInset: CGFloat
}

struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1
        return state
    }

    mutating func nextCGFloat() -> CGFloat {
        CGFloat(next() % 10_000) / 10_000.0
    }
}

func parseArguments() throws -> Configuration {
    var outputPath: String?
    var width = 520
    var height = 360

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--output":
            outputPath = iterator.next()
        case "--width":
            if let value = iterator.next(), let parsed = Int(value) {
                width = parsed
            }
        case "--height":
            if let value = iterator.next(), let parsed = Int(value) {
                height = parsed
            }
        default:
            continue
        }
    }

    guard let outputPath else {
        throw NSError(
            domain: "PingIslandDMG",
            code: 64,
            userInfo: [NSLocalizedDescriptionKey: "Usage: generate-dmg-background.swift --output <png-path> [--width <pixels>] [--height <pixels>]"]
        )
    }

    return Configuration(outputPath: outputPath, width: width, height: height)
}

func drawCornerBracket(at origin: CGPoint, size: CGSize, lineWidth: CGFloat, flippedY: Bool) {
    let path = NSBezierPath()
    path.lineWidth = lineWidth

    if flippedY {
        path.move(to: origin)
        path.line(to: CGPoint(x: origin.x + size.width, y: origin.y))
        path.move(to: origin)
        path.line(to: CGPoint(x: origin.x, y: origin.y - size.height))
    } else {
        path.move(to: origin)
        path.line(to: CGPoint(x: origin.x + size.width, y: origin.y))
        path.move(to: origin)
        path.line(to: CGPoint(x: origin.x, y: origin.y + size.height))
    }

    NSColor(calibratedRed: 0.21, green: 0.23, blue: 0.26, alpha: 0.78).setStroke()
    path.stroke()
}

func drawInstallArrow(from start: CGPoint, to end: CGPoint) {
    let color = NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.36, alpha: 0.72)
    let segmentWidth: CGFloat = 18
    let segmentHeight: CGFloat = 4
    let segmentGap: CGFloat = 12
    let headGap: CGFloat = 14

    for index in 0..<3 {
        let originX = start.x + CGFloat(index) * (segmentWidth + segmentGap)
        let rect = NSRect(x: originX, y: start.y - segmentHeight / 2, width: segmentWidth, height: segmentHeight)
        let segment = NSBezierPath(roundedRect: rect, xRadius: segmentHeight / 2, yRadius: segmentHeight / 2)
        color.setFill()
        segment.fill()
    }

    let segmentsEndX = start.x + (3 * segmentWidth) + (2 * segmentGap)
    let tipX = max(end.x, segmentsEndX + headGap + 14)
    let headBaseX = tipX - 14
    let head = NSBezierPath()
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: CGPoint(x: headBaseX, y: end.y + 13))
    head.line(to: CGPoint(x: tipX, y: end.y))
    head.move(to: CGPoint(x: tipX, y: end.y))
    head.line(to: CGPoint(x: headBaseX, y: end.y - 13))
    color.setStroke()
    head.stroke()
}

func makeLayout(width: CGFloat, height: CGFloat) -> Layout {
    Layout(
        titleFontSize: width <= 700 ? 34 : 64,
        titleY: width <= 700 ? height * 0.68 : height * 0.69,
        titleHeight: width <= 700 ? 46 : 82,
        cornerInset: width <= 700 ? 18 : 46,
        cornerLength: width <= 700 ? 28 : 48,
        cornerStroke: width <= 700 ? 3 : 4,
        arrowStart: width <= 700 ? CGPoint(x: width * 0.405, y: height * 0.53) : CGPoint(x: width * 0.36, y: height * 0.39),
        arrowEnd: width <= 700 ? CGPoint(x: width * 0.575, y: height * 0.53) : CGPoint(x: width * 0.64, y: height * 0.39),
        captionRect: width <= 700
            ? NSRect(x: width * 0.34, y: height * 0.22, width: width * 0.34, height: 42)
            : NSRect(x: width * 0.39, y: height * 0.31, width: width * 0.22, height: 40),
        captionFontSize: width <= 700 ? 16 : 28,
        captionKern: width <= 700 ? 0.9 : 1.2,
        bottomInset: width <= 700 ? 18 : 32
    )
}

func drawBackground(configuration: Configuration) throws {
    let width = configuration.width
    let height = configuration.height
    let canvasWidth = CGFloat(width)
    let canvasHeight = CGFloat(height)
    let layout = makeLayout(width: canvasWidth, height: canvasHeight)

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw NSError(domain: "PingIslandDMG", code: 65, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
    }

    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PingIslandDMG", code: 66, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context"])
    }

    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    let baseBackground = NSColor(calibratedRed: 0.985, green: 0.982, blue: 0.970, alpha: 1)
    baseBackground.setFill()
    canvas.fill()

    var random = LCG(seed: 42)
    let starCount = Int(max(40, min(95, (canvasWidth * canvasHeight) / 10_000)))
    for _ in 0..<starCount {
        let x = random.nextCGFloat() * canvasWidth
        let y = random.nextCGFloat() * canvasHeight
        let size = max(1.0, random.nextCGFloat() * (canvasWidth <= 700 ? 2.3 : 3.0))
        let alpha = 0.08 + (random.nextCGFloat() * 0.12)
        let star = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size))
        NSColor(calibratedRed: 0.35, green: 0.37, blue: 0.42, alpha: alpha).setFill()
        star.fill()
    }

    drawCornerBracket(
        at: CGPoint(x: layout.cornerInset, y: canvasHeight - layout.cornerInset),
        size: CGSize(width: layout.cornerLength, height: layout.cornerLength),
        lineWidth: layout.cornerStroke,
        flippedY: true
    )
    drawCornerBracket(
        at: CGPoint(x: canvasWidth - layout.cornerInset, y: canvasHeight - layout.cornerInset),
        size: CGSize(width: -layout.cornerLength, height: layout.cornerLength),
        lineWidth: layout.cornerStroke,
        flippedY: true
    )

    let bottomLine = NSBezierPath()
    bottomLine.lineWidth = layout.cornerStroke - 1
    bottomLine.move(to: CGPoint(x: layout.cornerInset - 4, y: layout.bottomInset))
    bottomLine.line(to: CGPoint(x: canvasWidth - (layout.cornerInset - 4), y: layout.bottomInset))
    NSColor(calibratedRed: 0.44, green: 0.46, blue: 0.50, alpha: 0.5).setStroke()
    bottomLine.stroke()

    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: layout.titleFontSize, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.20, alpha: 0.95),
        .paragraphStyle: titleStyle,
        .kern: canvasWidth <= 700 ? 1.2 : 2.0
    ]
    let title = NSAttributedString(string: "NOTCHCODE", attributes: titleAttributes)
    title.draw(in: NSRect(x: 0, y: layout.titleY, width: canvasWidth, height: layout.titleHeight))

    drawInstallArrow(from: layout.arrowStart, to: layout.arrowEnd)

    let captionStyle = NSMutableParagraphStyle()
    captionStyle.alignment = .center
    let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: layout.captionFontSize, weight: .regular),
        .foregroundColor: NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.40, alpha: 0.82),
        .paragraphStyle: captionStyle,
        .kern: layout.captionKern
    ]
    let caption = NSAttributedString(string: "drag to install", attributes: captionAttributes)
    caption.draw(in: layout.captionRect)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PingIslandDMG", code: 67, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    let outputURL = URL(fileURLWithPath: configuration.outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try data.write(to: outputURL)
}

do {
    let configuration = try parseArguments()
    try drawBackground(configuration: configuration)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
