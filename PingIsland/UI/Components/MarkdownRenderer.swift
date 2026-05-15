import Foundation
import SwiftUI

struct MarkdownText: View {
    let text: String
    let baseColor: Color
    let fontSize: CGFloat

    init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13) {
        self.text = text
        self.baseColor = color
        self.fontSize = fontSize
    }

    var body: some View {
        Text(renderedText)
            .foregroundColor(baseColor)
            .font(.system(size: fontSize))
            .textSelection(.enabled)
    }

    private var renderedText: AttributedString {
        MarkdownTextCache.shared.attributedString(for: text)
    }
}

@MainActor
private final class MarkdownTextCache {
    static let shared = MarkdownTextCache()

    private final class Entry {
        let value: AttributedString

        init(value: AttributedString) {
            self.value = value
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 2 * 1024 * 1024
    }

    func attributedString(for text: String) -> AttributedString {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        let rendered = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)

        cache.setObject(Entry(value: rendered), forKey: key, cost: text.utf8.count)
        return rendered
    }
}

struct MarkdownContentView: View {
    let blocks: [UpdateReleaseNotesBlock]
    let baseColor: Color
    let fontSize: CGFloat

    init(
        _ markdown: String,
        color: Color = .white.opacity(0.9),
        fontSize: CGFloat = 13
    ) {
        self.blocks = UpdateReleaseNotesMarkdownParser.blocks(from: markdown)
        self.baseColor = color
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(baseColor.opacity(0.92))
    }

    @ViewBuilder
    private func blockView(_ block: UpdateReleaseNotesBlock) -> some View {
        switch block {
        case .paragraph(let text):
            MarkdownText(text, color: baseColor, fontSize: fontSize)
                .lineSpacing(max(3, fontSize * 0.25))
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            MarkdownListRows(
                items: items,
                style: .unordered,
                color: baseColor,
                fontSize: fontSize
            )

        case .orderedList(let items):
            MarkdownListRows(
                items: items,
                style: .ordered,
                color: baseColor,
                fontSize: fontSize
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(baseColor.opacity(0.4))
                    .frame(width: 3)

                MarkdownText(text, color: baseColor.opacity(0.9), fontSize: fontSize)
                    .lineSpacing(max(3, fontSize * 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(baseColor.opacity(0.55))
                }

                CodeBlockView(code: code)
            }

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level: level))
                .foregroundColor(.white.opacity(level <= 3 ? 0.95 : 0.88))
                .fixedSize(horizontal: false, vertical: true)

        case .divider:
            Divider()
                .overlay(baseColor.opacity(0.12))
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: fontSize + 8, weight: .bold)
        case 2:
            return .system(size: fontSize + 5, weight: .bold)
        default:
            return .system(size: fontSize + 2, weight: .semibold)
        }
    }
}

private struct MarkdownListRows: View {
    enum ListStyle {
        case unordered
        case ordered
    }

    let items: [String]
    let style: ListStyle
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    marker(for: index)
                    MarkdownText(item, color: color.opacity(0.92), fontSize: fontSize)
                        .lineSpacing(max(2, fontSize * 0.18))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 8)

                if index < items.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func marker(for index: Int) -> some View {
        switch style {
        case .unordered:
            Circle()
                .fill(color.opacity(0.82))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
        case .ordered:
            Text("\(index + 1)")
                .font(.system(size: max(10, fontSize - 3), weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(color.opacity(0.2))
                )
        }
    }
}

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SwiftUI.Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
    }
}
