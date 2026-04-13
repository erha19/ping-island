import SwiftUI

enum MascotClient: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case qwen
    case openclaw
    case opencode
    case cursor
    case qoder
    case codebuddy
    case trae
    case copilot

    static let allCases: [MascotClient] = [
        .claude,
        .codex,
        .gemini,
        .qwen,
        .openclaw,
        .opencode,
        .cursor,
        .qoder,
        .codebuddy,
        .copilot,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini CLI"
        case .qwen:
            return "Qwen Code"
        case .openclaw:
            return "OpenClaw"
        case .opencode:
            return "OpenCode"
        case .cursor:
            return "Cursor"
        case .qoder:
            return "Qoder"
        case .codebuddy:
            return "CodeBuddy"
        case .trae:
            return "Trae"
        case .copilot:
            return "Copilot"
        }
    }

    var subtitle: String {
        switch self {
        case .claude:
            return "Claude Hooks 与默认 Claude Code 会话"
        case .codex:
            return "Codex App 与 Codex CLI"
        case .gemini:
            return "Gemini CLI hooks 与默认 Gemini CLI 会话"
        case .qwen:
            return "Qwen Code 官方 hooks 与青羽问答燕"
        case .openclaw:
            return "OpenClaw Gateway hooks 与默认小龙虾形象"
        case .opencode:
            return "OpenCode 插件 hooks 会话"
        case .cursor:
            return "Cursor IDE 中的 Claude 会话"
        case .qoder:
            return "Qoder、QoderWork 与 JetBrains 插件"
        case .codebuddy:
            return "CodeBuddy、WorkBuddy 客户端"
        case .trae:
            return "Trae IDE 中的 Claude 会话"
        case .copilot:
            return "GitHub Copilot Hooks 客户端"
        }
    }

    nonisolated var defaultMascotKind: MascotKind {
        switch self {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .gemini:
            return .gemini
        case .qwen:
            return .qwen
        case .openclaw:
            return .openclaw
        case .opencode:
            return .opencode
        case .cursor:
            return .cursor
        case .qoder:
            return .qoder
        case .codebuddy:
            return .codebuddy
        case .trae:
            return .claude
        case .copilot:
            return .copilot
        }
    }

    nonisolated init(provider: SessionProvider) {
        switch provider {
        case .codex:
            self = .codex
        case .claude:
            self = .claude
        case .copilot:
            self = .copilot
        }
    }

    nonisolated init(clientInfo: SessionClientInfo, provider: SessionProvider) {
        if let profileID = clientInfo.resolvedProfile(for: provider)?.id {
            let resolvedClient: MascotClient? = switch profileID {
            case "cursor":
                .cursor
            case "qwen-code":
                .qwen
            case "openclaw":
                .openclaw
            case "opencode":
                .opencode
            case "qoder", "qoderwork", "qoder-cli", "jb-plugin":
                .qoder
            case "codebuddy":
                .codebuddy
            case "gemini":
                .gemini
            case "trae":
                .trae
            case "codex-app", "codex-cli":
                .codex
            default:
                nil
            }

            if let resolvedClient {
                self = resolvedClient
                return
            }
        }

        switch clientInfo.brand {
        case .codebuddy:
            self = .codebuddy
        case .codex:
            self = .codex
        case .gemini:
            self = .gemini
        case .qwen:
            self = .qwen
        case .neutral:
            if clientInfo.resolvedProfile(for: provider)?.id == "openclaw" {
                self = .openclaw
                return
            }
            if clientInfo.resolvedProfile(for: provider)?.id == "qwen-code" {
                self = .qwen
                return
            }
            switch provider {
            case .codex:
                self = .codex
            case .copilot:
                self = .copilot
            case .claude:
                self = .claude
            }
        case .opencode:
            self = .opencode
        case .qoder:
            self = .qoder
        case .copilot:
            self = .copilot
        case .claude:
            switch provider {
            case .codex:
                self = .codex
            case .copilot:
                self = .copilot
            case .claude:
                self = .claude
            }
        }
    }
}

enum MascotKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case qwen
    case openclaw
    case opencode
    case cursor
    case qoder
    case codebuddy
    case copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini CLI"
        case .qwen:
            return "Qwen Code"
        case .openclaw:
            return "OpenClaw"
        case .opencode:
            return "OpenCode"
        case .cursor:
            return "Cursor"
        case .qoder:
            return "Qoder"
        case .codebuddy:
            return "CodeBuddy"
        case .copilot:
            return "Copilot"
        }
    }

    var subtitle: String {
        switch self {
        case .claude:
            return "桌前橘猫"
        case .codex:
            return "终端云团"
        case .gemini:
            return "蓝色双子星灵"
        case .qwen:
            return "青羽问答燕"
        case .openclaw:
            return "像素小龙虾"
        case .opencode:
            return "高高的白色小章鱼"
        case .cursor:
            return "黑曜晶体"
        case .qoder:
            return "Q 仔"
        case .codebuddy:
            return "宇航员猫"
        case .copilot:
            return "黑框眼镜机器人"
        }
    }

    var alertColor: Color {
        switch self {
        case .claude:
            return Color(red: 1.0, green: 0.49, blue: 0.24)
        case .codex:
            return Color(red: 1.0, green: 0.67, blue: 0.12)
        case .gemini:
            return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .qwen:
            return Color(red: 0.12, green: 0.78, blue: 0.90)
        case .openclaw:
            return Color(red: 1.0, green: 0.38, blue: 0.24)
        case .opencode:
            return Color(red: 0.34, green: 0.96, blue: 0.82)
        case .cursor:
            return Color(red: 1.0, green: 0.52, blue: 0.24)
        case .qoder:
            return Color(red: 0.98, green: 0.53, blue: 0.18)
        case .codebuddy:
            return Color(red: 1.0, green: 0.45, blue: 0.34)
        case .copilot:
            return Color(red: 1.0, green: 0.56, blue: 0.28)
        }
    }

    nonisolated init(client: MascotClient) {
        self = client.defaultMascotKind
    }

    nonisolated init(provider: SessionProvider) {
        self = MascotKind(client: MascotClient(provider: provider))
    }

    nonisolated init(clientInfo: SessionClientInfo, provider: SessionProvider) {
        self = MascotKind(client: MascotClient(clientInfo: clientInfo, provider: provider))
    }
}

extension SessionState {
    nonisolated var mascotClient: MascotClient {
        MascotClient(clientInfo: clientInfo, provider: provider)
    }

    nonisolated var defaultMascotKind: MascotKind {
        MascotKind(client: mascotClient)
    }
}

extension MascotStatus {
    init(session: SessionState) {
        if session.needsManualAttention {
            self = .warning
        } else if session.phase.isActive {
            self = .working
        } else {
            self = .idle
        }
    }
}

struct MascotView: View {
    let kind: MascotKind
    let status: MascotStatus
    var size: CGFloat = 40
    var animationTime: TimeInterval?

    init(kind: MascotKind, status: MascotStatus, size: CGFloat = 40, animationTime: TimeInterval? = nil) {
        self.kind = kind
        self.status = status
        self.size = size
        self.animationTime = animationTime
    }

    init(provider: SessionProvider, status: MascotStatus, size: CGFloat = 40, animationTime: TimeInterval? = nil) {
        self.init(kind: MascotKind(provider: provider), status: status, size: size, animationTime: animationTime)
    }

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                idleScene(time: animationTime)
            case .working:
                workingScene(time: animationTime)
            case .warning:
                warningScene(time: animationTime)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityLabel(AppLocalization.format("%@ %@", kind.title, status.displayName))
    }

    private func idleScene(time: TimeInterval?) -> some View {
        ZStack(alignment: .topTrailing) {
            canvasScene(interval: 0.06, mode: .idle, time: time)
            FloatingZOverlay(size: size, time: time)
        }
    }

    private func workingScene(time: TimeInterval?) -> some View {
        canvasScene(interval: 0.03, mode: .working, time: time)
    }

    private func warningScene(time: TimeInterval?) -> some View {
        ZStack {
            AlertHalo(tint: kind.alertColor, size: size, time: time)
            canvasScene(interval: 0.03, mode: .warning, time: time)
        }
    }

    @ViewBuilder
    private func canvasScene(interval: TimeInterval, mode: MascotRenderMode, time: TimeInterval?) -> some View {
        if let time {
            canvasFrame(time: time, mode: mode)
        } else {
            animatedCanvas(interval: interval, mode: mode)
        }
    }

    private func animatedCanvas(interval: TimeInterval, mode: MascotRenderMode) -> some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            canvasFrame(time: context.date.timeIntervalSinceReferenceDate, mode: mode)
        }
    }

    private func canvasFrame(time: TimeInterval, mode: MascotRenderMode) -> some View {
        Canvas { graphicsContext, canvasSize in
            drawMascot(
                in: graphicsContext,
                canvasSize: canvasSize,
                time: time,
                mode: mode
            )
        }
        .frame(width: size, height: size)
    }

    private func drawMascot(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        switch kind {
        case .claude:
            drawClaude(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .codex:
            drawCodex(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .gemini:
            drawGemini(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .qwen:
            drawQwen(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .openclaw:
            drawOpenClaw(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .opencode:
            drawOpenCode(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .cursor:
            drawCursor(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .qoder:
            drawQoder(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .codebuddy:
            drawCodeBuddy(in: context, canvasSize: canvasSize, time: time, mode: mode)
        case .copilot:
            drawCopilot(in: context, canvasSize: canvasSize, time: time, mode: mode)
        }
    }

    private func drawClaude(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 17, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let body = Color(red: 0.87, green: 0.53, blue: 0.43)
        let dark = Color(red: 0.63, green: 0.35, blue: 0.25)
        let eye = Color.black
        let keyboardBase = Color(red: 0.26, green: 0.29, blue: 0.34)
        let keyboardKey = Color(red: 0.55, green: 0.60, blue: 0.67)

        drawShadow(in: context, space: space, centerX: 8.5, y: 15.6, width: 8.2 - abs(motion.bounce) * 0.3, opacity: 0.24)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 12.5,
                base: keyboardBase,
                key: keyboardKey,
                highlight: .white,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (13, 4, 9), (12, 3, 11), (11, 3, 11), (10, 3, 11),
            (9, 4, 9), (8, 4, 9), (7, 4, 9), (6, 5, 7)
        ]
        for row in rows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)), with: .color(body))
        }
        context.fill(Path(space.rect(4.2 + motion.shake, 4.7 + motion.vertical, 2.1 * motion.squashX, 1.8)), with: .color(body))
        context.fill(Path(space.rect(10.7 + motion.shake, 4.7 + motion.vertical, 2.1 * motion.squashX, 1.8)), with: .color(body))
        context.fill(Path(space.rect(5.0 + motion.shake, 5.3 + motion.vertical, 0.9, 0.8)), with: .color(Color(red: 0.98, green: 0.73, blue: 0.63).opacity(0.55)))
        context.fill(Path(space.rect(11.0 + motion.shake, 5.3 + motion.vertical, 0.9, 0.8)), with: .color(Color(red: 0.98, green: 0.73, blue: 0.63).opacity(0.55)))
        context.fill(Path(space.rect(12.8 + motion.shake, 11.1 + motion.vertical, 1.8, 0.8)), with: .color(dark))
        context.fill(Path(space.rect(13.7 + motion.shake, 10.2 + motion.vertical, 0.9, 0.8)), with: .color(dark))
        context.fill(Path(space.rect(5.0 + motion.shake, 13.8 + motion.vertical, 1.2, 1.2)), with: .color(dark))
        context.fill(Path(space.rect(10.8 + motion.shake, 13.8 + motion.vertical, 1.2, 1.2)), with: .color(dark))

        let eyeHeight: CGFloat = mode == .idle ? 0.45 : (mode == .warning ? 1.35 : blinkHeight(time: time, closedHeight: 0.2, openHeight: 1.35))
        context.fill(Path(space.rect(6.0 + motion.shake, 8.0 + motion.vertical, 1.0, eyeHeight)), with: .color(eye))
        context.fill(Path(space.rect(10.0 + motion.shake, 8.0 + motion.vertical, 1.0, eyeHeight)), with: .color(eye))

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 12.3 + motion.shake, y: 2.2, color: kind.alertColor)
        }
    }

    private func drawCodex(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 16, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let cloud = Color(red: 0.93, green: 0.93, blue: 0.94)
        let dark = Color(red: 0.67, green: 0.68, blue: 0.70)
        let prompt = Color.black
        let keyboardBase = Color(red: 0.18, green: 0.18, blue: 0.20)
        let keyboardKey = Color(red: 0.39, green: 0.40, blue: 0.43)

        drawShadow(in: context, space: space, centerX: 8, y: 15.5, width: 7.6 - abs(motion.bounce) * 0.3, opacity: 0.23)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 12.8,
                base: keyboardBase,
                key: keyboardKey,
                highlight: .white,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (13, 4, 8), (12, 3, 10), (11, 2, 12), (10, 2, 12),
            (9, 2, 12), (8, 3, 10), (7, 3, 10), (6, 4, 3),
            (6, 7, 3), (6, 10, 3), (5, 4.5, 2), (5, 7.1, 2), (5, 9.7, 2)
        ]
        for row in rows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)), with: .color(cloud))
        }

        context.fill(Path(space.rect(5.1 + motion.shake, 13.7 + motion.vertical, 0.9, 1.1)), with: .color(dark))
        context.fill(Path(space.rect(9.6 + motion.shake, 13.7 + motion.vertical, 0.9, 1.1)), with: .color(dark))

        if mode == .idle {
            context.fill(Path(space.rect(6.7 + motion.shake, 11.0 + motion.vertical, 2.2, 0.6)), with: .color(prompt.opacity(0.32)))
        } else {
            context.fill(Path(space.rect(5.3 + motion.shake, 9.0 + motion.vertical, 0.9, 0.9)), with: .color(prompt))
            context.fill(Path(space.rect(6.2 + motion.shake, 9.9 + motion.vertical, 0.9, 0.9)), with: .color(prompt))
            context.fill(Path(space.rect(5.3 + motion.shake, 10.8 + motion.vertical, 0.9, 0.9)), with: .color(prompt))

            let cursorWidth: CGFloat = mode == .working && Int(time * 6).isMultiple(of: 2) ? 2.8 : 2.0
            context.fill(Path(space.rect(8.1 + motion.shake, 10.8 + motion.vertical, cursorWidth, 0.9)), with: .color(prompt))
        }

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 11.7 + motion.shake, y: 2.2, color: kind.alertColor)
        }
    }

    private func drawCursor(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 16, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let dark = Color(red: 0.08, green: 0.07, blue: 0.04)
        let mid = Color(red: 0.15, green: 0.14, blue: 0.12)
        let edge = Color(red: 0.30, green: 0.28, blue: 0.24)
        let light = Color(red: 0.93, green: 0.93, blue: 0.93)

        drawShadow(in: context, space: space, centerX: 8, y: 15.5, width: 7.4 - abs(motion.bounce) * 0.25, opacity: 0.22)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 12.9,
                base: Color(red: 0.12, green: 0.11, blue: 0.08),
                key: Color(red: 0.28, green: 0.27, blue: 0.23),
                highlight: light,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let top = space.point(8 + motion.shake, 5.1 + motion.vertical)
        let topRight = space.point(12.4 + motion.shake, 7.0 + motion.vertical)
        let bottomRight = space.point(12.4 + motion.shake, 11.0 + motion.vertical)
        let bottom = space.point(8 + motion.shake, 13.2 + motion.vertical)
        let bottomLeft = space.point(3.6 + motion.shake, 11.0 + motion.vertical)
        let topLeft = space.point(3.6 + motion.shake, 7.0 + motion.vertical)
        let center = space.point(8 + motion.shake, 9.2 + motion.vertical)

        var leftFacet = Path()
        leftFacet.move(to: topLeft)
        leftFacet.addLine(to: top)
        leftFacet.addLine(to: center)
        leftFacet.addLine(to: bottomLeft)
        leftFacet.closeSubpath()
        context.fill(leftFacet, with: .color(dark))

        var rightFacet = Path()
        rightFacet.move(to: top)
        rightFacet.addLine(to: topRight)
        rightFacet.addLine(to: bottomRight)
        rightFacet.addLine(to: center)
        rightFacet.closeSubpath()
        context.fill(rightFacet, with: .color(mid))

        var bottomFacet = Path()
        bottomFacet.move(to: bottomLeft)
        bottomFacet.addLine(to: center)
        bottomFacet.addLine(to: bottomRight)
        bottomFacet.addLine(to: bottom)
        bottomFacet.closeSubpath()
        context.fill(bottomFacet, with: .color(edge))

        var slash = Path()
        slash.move(to: space.point(8.6 + motion.shake, 5.8 + motion.vertical))
        slash.addLine(to: space.point(12.0 + motion.shake, 7.2 + motion.vertical))
        slash.addLine(to: space.point(8.4 + motion.shake, 9.4 + motion.vertical))
        slash.closeSubpath()
        context.fill(slash, with: .color(light.opacity(mode == .working ? 0.95 : 0.82)))

        var outline = Path()
        outline.move(to: top)
        outline.addLine(to: topRight)
        outline.addLine(to: bottomRight)
        outline.addLine(to: bottom)
        outline.addLine(to: bottomLeft)
        outline.addLine(to: topLeft)
        outline.closeSubpath()
        context.stroke(outline, with: .color(light.opacity(0.32)), lineWidth: max(1, space.pixel * 0.45))

        let eyeHeight: CGFloat = mode == .idle ? 0.45 : (mode == .warning ? 1.2 : blinkHeight(time: time, closedHeight: 0.25, openHeight: 1.2))
        context.fill(Path(space.rect(5.0 + motion.shake, 9.0 + motion.vertical, 1.1, eyeHeight)), with: .color(light))
        context.fill(Path(space.rect(7.4 + motion.shake, 9.0 + motion.vertical, 1.1, eyeHeight)), with: .color(light))

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 11.5 + motion.shake, y: 2.0, color: kind.alertColor)
        }
    }

    private func drawGemini(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 17, logicalHeight: 15, yOffset: 1.5)
        let motion = motionValues(for: mode, time: time)
        let core = Color(red: 0.26, green: 0.52, blue: 0.96)
        let highlight = Color(red: 0.73, green: 0.86, blue: 1.0)
        let deep = Color(red: 0.16, green: 0.33, blue: 0.73)
        let sparkle = Color.white
        let face = Color(red: 0.08, green: 0.15, blue: 0.34)

        drawShadow(in: context, space: space, centerX: 8.5, y: 15.8, width: 7.0 - abs(motion.bounce) * 0.22, opacity: 0.20)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.2,
                base: Color(red: 0.13, green: 0.18, blue: 0.31),
                key: Color(red: 0.25, green: 0.36, blue: 0.59),
                highlight: highlight,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let outerRows: [(CGFloat, CGFloat, CGFloat)] = [
            (5.0, 7.4, 1.2),
            (6.0, 6.8, 2.4),
            (7.0, 5.7, 4.6),
            (8.0, 4.6, 6.8),
            (9.0, 3.4, 9.2),
            (10.0, 2.2, 11.6),
            (11.0, 3.4, 9.2),
            (12.0, 4.6, 6.8),
            (13.0, 5.7, 4.6),
            (14.0, 6.8, 2.4),
            (15.0, 7.4, 1.2)
        ]
        for row in outerRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)),
                with: .color(core)
            )
        }

        let innerRows: [(CGFloat, CGFloat, CGFloat)] = [
            (7.2, 6.6, 2.8),
            (8.2, 5.9, 4.2),
            (9.2, 5.0, 6.0),
            (10.2, 4.2, 7.6),
            (11.2, 5.0, 6.0),
            (12.2, 5.9, 4.2),
            (13.2, 6.6, 2.8)
        ]
        for row in innerRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)),
                with: .color(highlight.opacity(0.92))
            )
        }

        let shadeRows: [(CGFloat, CGFloat, CGFloat)] = [
            (10.1, 9.8, 2.6),
            (11.1, 9.0, 2.7),
            (12.1, 8.3, 2.5),
            (13.1, 7.7, 1.9)
        ]
        for row in shadeRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)),
                with: .color(deep.opacity(0.78))
            )
        }

        context.fill(Path(space.rect(7.3 + motion.shake, 5.8 + motion.vertical, 1.5, 0.45)), with: .color(sparkle.opacity(0.72)))
        context.fill(Path(space.rect(6.4 + motion.shake, 6.8 + motion.vertical, 1.2, 0.35)), with: .color(sparkle.opacity(0.44)))

        let eyeHeight: CGFloat = mode == .idle ? 0.35 : (mode == .warning ? 0.92 : blinkHeight(time: time, closedHeight: 0.16, openHeight: 0.92))
        context.fill(Path(space.rect(6.8 + motion.shake, 9.0 + motion.vertical, 0.72, eyeHeight)), with: .color(face))
        context.fill(Path(space.rect(9.5 + motion.shake, 9.0 + motion.vertical, 0.72, eyeHeight)), with: .color(face))

        if mode == .idle {
            context.fill(Path(space.rect(7.6 + motion.shake, 10.8 + motion.vertical, 2.0, 0.18)), with: .color(face.opacity(0.35)))
        } else {
            context.fill(Path(space.rect(7.4 + motion.shake, 10.7 + motion.vertical, 2.4, 0.28)), with: .color(sparkle.opacity(0.86)))
            context.fill(Path(space.rect(12.7 + motion.shake, 7.1 + motion.vertical, 0.7, 0.7)), with: .color(highlight.opacity(0.88)))
            context.fill(Path(space.rect(13.5 + motion.shake, 7.9 + motion.vertical, 0.4, 0.4)), with: .color(sparkle.opacity(0.76)))
        }

        if mode == .warning {
            context.fill(Path(space.rect(3.0 + motion.shake, 8.1 + motion.vertical, 0.6, 1.2)), with: .color(sparkle.opacity(0.78)))
            context.fill(Path(space.rect(2.7 + motion.shake, 8.4 + motion.vertical, 1.2, 0.6)), with: .color(sparkle.opacity(0.78)))
            drawAlertGlyph(in: context, space: space, x: 12.7 + motion.shake, y: 2.1, color: kind.alertColor)
        }
    }

    private func drawQwen(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 17, logicalHeight: 15, yOffset: 1.5)
        let motion = motionValues(for: mode, time: time)
        let body = Color(red: 0.16, green: 0.73, blue: 0.87)
        let deep = Color(red: 0.08, green: 0.49, blue: 0.64)
        let wing = Color(red: 0.11, green: 0.58, blue: 0.72)
        let belly = Color(red: 0.86, green: 0.99, blue: 0.97)
        let beak = Color(red: 1.0, green: 0.75, blue: 0.27)
        let eye = Color(red: 0.05, green: 0.15, blue: 0.22)
        let accent = Color.white
        let bubble = Color(red: 0.77, green: 0.97, blue: 1.0)

        drawShadow(in: context, space: space, centerX: 8.7, y: 15.7, width: 7.1 - abs(motion.bounce) * 0.22, opacity: 0.2)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.2,
                base: Color(red: 0.11, green: 0.18, blue: 0.22),
                key: Color(red: 0.22, green: 0.36, blue: 0.44),
                highlight: belly,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (4.9, 7.8, 1.4),
            (5.8, 6.6, 3.6),
            (6.8, 5.2, 6.3),
            (7.8, 4.2, 8.5),
            (8.8, 3.7, 9.4),
            (9.8, 3.5, 9.6),
            (10.8, 3.9, 8.7),
            (11.8, 4.8, 7.0),
            (12.8, 6.0, 5.1),
            (13.8, 7.2, 2.8)
        ]
        for row in rows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)),
                with: .color(body)
            )
        }

        let crestRows: [(CGFloat, CGFloat, CGFloat)] = [
            (3.9, 7.0, 0.7),
            (4.2, 7.8, 0.9),
            (4.3, 8.7, 0.7)
        ]
        for row in crestRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.8)),
                with: .color(deep.opacity(0.92))
            )
        }

        let bellyRows: [(CGFloat, CGFloat, CGFloat)] = [
            (8.3, 6.6, 2.7),
            (9.3, 5.9, 4.0),
            (10.3, 5.5, 4.5),
            (11.3, 5.8, 4.0),
            (12.3, 6.6, 2.7)
        ]
        for row in bellyRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)),
                with: .color(belly)
            )
        }

        let leftWingRows: [(CGFloat, CGFloat, CGFloat)] = [
            (8.6, 3.6, 1.8),
            (9.6, 3.1, 2.3),
            (10.6, 3.6, 2.0),
            (11.6, 4.3, 1.4)
        ]
        for row in leftWingRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)),
                with: .color(wing)
            )
        }

        let rightWingRows: [(CGFloat, CGFloat, CGFloat)] = [
            (8.4, 11.3, 1.8),
            (9.4, 11.7, 2.2),
            (10.4, 11.1, 2.4),
            (11.4, 10.5, 1.7)
        ]
        for row in rightWingRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)),
                with: .color(deep.opacity(0.9))
            )
        }

        let tailRows: [(CGFloat, CGFloat, CGFloat)] = [
            (12.9, 8.4, 0.8),
            (13.6, 8.1, 0.8),
            (13.6, 9.0, 0.8)
        ]
        for row in tailRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 1.2)),
                with: .color(deep)
            )
        }

        context.fill(Path(space.rect(8.2 + motion.shake, 4.2 + motion.vertical, 1.4, 0.8)), with: .color(accent.opacity(0.7)))
        context.fill(Path(space.rect(7.1 + motion.shake, 5.0 + motion.vertical, 2.4, 0.42)), with: .color(accent.opacity(0.4)))

        let eyeHeight: CGFloat = mode == .idle ? 0.35 : (mode == .warning ? 1.0 : blinkHeight(time: time, closedHeight: 0.16, openHeight: 1.0))
        context.fill(Path(space.rect(6.8 + motion.shake, 8.6 + motion.vertical, 0.7, eyeHeight)), with: .color(eye))
        context.fill(Path(space.rect(9.6 + motion.shake, 8.6 + motion.vertical, 0.7, eyeHeight)), with: .color(eye))

        context.fill(Path(space.rect(11.6 + motion.shake, 8.9 + motion.vertical, 1.1, 0.8)), with: .color(beak))
        context.fill(Path(space.rect(12.5 + motion.shake, 9.2 + motion.vertical, 0.8, 0.42)), with: .color(beak.opacity(0.82)))

        if mode == .idle {
            context.fill(Path(space.rect(7.3 + motion.shake, 11.1 + motion.vertical, 2.6, 0.18)), with: .color(eye.opacity(0.26)))
        } else {
            context.fill(Path(space.rect(7.0 + motion.shake, 10.9 + motion.vertical, 3.0, 0.35)), with: .color(belly.opacity(0.94)))
            context.fill(Path(space.rect(12.7 + motion.shake, 5.1 + motion.vertical, 1.4, 1.1)), with: .color(bubble.opacity(0.95)))
            context.fill(Path(space.rect(13.1 + motion.shake, 6.0 + motion.vertical, 0.5, 0.45)), with: .color(bubble.opacity(0.95)))
            context.fill(Path(space.rect(13.0 + motion.shake, 5.4 + motion.vertical, 0.22, 0.22)), with: .color(deep))
            context.fill(Path(space.rect(13.45 + motion.shake, 5.4 + motion.vertical, 0.22, 0.22)), with: .color(deep))
            context.fill(Path(space.rect(13.9 + motion.shake, 5.4 + motion.vertical, 0.22, 0.22)), with: .color(deep))
        }

        if mode == .warning {
            context.fill(Path(space.rect(5.6 + motion.shake, 3.0 + motion.vertical, 0.6, 1.4)), with: .color(accent.opacity(0.78)))
            context.fill(Path(space.rect(5.2 + motion.shake, 3.4 + motion.vertical, 1.4, 0.55)), with: .color(accent.opacity(0.78)))
            drawAlertGlyph(in: context, space: space, x: 12.5 + motion.shake, y: 2.0, color: kind.alertColor)
        }
    }

    private func drawOpenCode(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 16, logicalHeight: 14, yOffset: 1.5)
        let motion = motionValues(for: mode, time: time)
        let body = Color(red: 0.95, green: 0.98, blue: 1.0)
        let shade = Color(red: 0.77, green: 0.84, blue: 0.90)
        let deepShade = Color(red: 0.55, green: 0.64, blue: 0.72)
        let accent = Color(red: 0.43, green: 0.91, blue: 0.88)
        let eye = Color(red: 0.10, green: 0.18, blue: 0.24)

        drawShadow(in: context, space: space, centerX: 9, y: 15.8, width: 7.0 - abs(motion.bounce) * 0.24, opacity: 0.18)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.2,
                base: Color(red: 0.15, green: 0.21, blue: 0.24),
                key: Color(red: 0.33, green: 0.44, blue: 0.48),
                highlight: accent,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (13.2, 6.0, 6.0), (12.2, 5.0, 8.0), (11.2, 4.2, 9.6), (10.2, 3.9, 10.2),
            (9.2, 4.1, 9.8), (8.2, 4.5, 9.0), (7.2, 5.2, 7.6), (6.2, 6.0, 6.0), (5.2, 7.0, 4.0)
        ]
        for row in rows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)),
                with: .color(body)
            )
        }

        let shadeRows: [(CGFloat, CGFloat, CGFloat)] = [
            (12.4, 9.9, 2.0), (11.4, 10.2, 2.2), (10.4, 10.3, 2.4), (9.4, 10.1, 2.3),
            (8.4, 9.7, 2.1), (7.4, 8.8, 1.8)
        ]
        for row in shadeRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 1)),
                with: .color(shade.opacity(0.72))
            )
        }

        let crownRows: [(CGFloat, CGFloat, CGFloat)] = [
            (5.4, 7.5, 1.0), (6.1, 6.8, 2.2), (7.0, 6.1, 3.6), (8.0, 5.5, 4.8)
        ]
        for row in crownRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.8)),
                with: .color(.white.opacity(0.72))
            )
        }

        context.fill(Path(space.rect(6.5 + motion.shake, 8.6 + motion.vertical, 1.0, 1.2)), with: .color(eye))
        context.fill(Path(space.rect(10.5 + motion.shake, 8.6 + motion.vertical, 1.0, 1.2)), with: .color(eye))
        context.fill(Path(space.rect(7.0 + motion.shake, 9.0 + motion.vertical, 0.3, 0.4)), with: .color(.white.opacity(0.48)))
        context.fill(Path(space.rect(11.0 + motion.shake, 9.0 + motion.vertical, 0.3, 0.4)), with: .color(.white.opacity(0.48)))

        if mode == .idle {
            context.fill(Path(space.rect(7.4 + motion.shake, 10.8 + motion.vertical, 3.2, 0.4)), with: .color(deepShade.opacity(0.42)))
        } else {
            context.fill(Path(space.rect(7.2 + motion.shake, 10.7 + motion.vertical, 1.2, 0.4)), with: .color(accent))
            context.fill(Path(space.rect(8.7 + motion.shake, 10.7 + motion.vertical, 0.5, 0.4)), with: .color(accent.opacity(0.55)))
            context.fill(Path(space.rect(9.8 + motion.shake, 10.7 + motion.vertical, 1.2, 0.4)), with: .color(accent))
        }

        let tentacles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (5.1, 12.9, 1.0, 1.8), (7.2, 13.0, 1.0, 2.0),
            (9.8, 13.0, 1.0, 2.0), (11.9, 12.9, 1.0, 1.8)
        ]
        for tentacle in tentacles {
            context.fill(Path(space.rect(tentacle.0 + motion.shake, tentacle.1 + motion.vertical, tentacle.2, tentacle.3)), with: .color(body))
        }
        context.fill(Path(space.rect(5.3 + motion.shake, 14.4 + motion.vertical, 0.7, 0.7)), with: .color(shade))
        context.fill(Path(space.rect(7.4 + motion.shake, 14.8 + motion.vertical, 0.7, 0.7)), with: .color(shade))
        context.fill(Path(space.rect(10.0 + motion.shake, 14.8 + motion.vertical, 0.7, 0.7)), with: .color(shade))
        context.fill(Path(space.rect(12.1 + motion.shake, 14.4 + motion.vertical, 0.7, 0.7)), with: .color(shade))

        context.fill(Path(space.rect(4.2 + motion.shake, 8.7 + motion.vertical, 0.7, 2.2)), with: .color(body.opacity(0.94)))
        context.fill(Path(space.rect(13.1 + motion.shake, 8.7 + motion.vertical, 0.7, 2.2)), with: .color(body.opacity(0.94)))
        context.fill(Path(space.rect(3.8 + motion.shake, 10.4 + motion.vertical, 0.8, 0.4)), with: .color(accent.opacity(0.54)))
        context.fill(Path(space.rect(13.4 + motion.shake, 10.4 + motion.vertical, 0.8, 0.4)), with: .color(accent.opacity(0.54)))

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 12.8 + motion.shake, y: 2.2, color: kind.alertColor)
        }
    }

    private func drawOpenClaw(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 18, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let shell = Color(red: 1.0, green: 0.36, blue: 0.25)
        let highlight = Color(red: 1.0, green: 0.56, blue: 0.43)
        let dark = Color(red: 0.27, green: 0.07, blue: 0.07)
        let eye = Color.black

        drawShadow(in: context, space: space, centerX: 9, y: 15.7, width: 7.8 - abs(motion.bounce) * 0.28, opacity: 0.2)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.1,
                base: Color(red: 0.22, green: 0.12, blue: 0.12),
                key: Color(red: 0.43, green: 0.20, blue: 0.19),
                highlight: highlight,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let bodyRows: [(CGFloat, CGFloat, CGFloat)] = [
            (12.8, 5.6, 6.8), (11.8, 4.6, 8.8), (10.8, 3.6, 10.8), (9.8, 2.8, 12.4),
            (8.8, 2.2, 13.6), (7.8, 2.8, 12.4), (6.8, 3.6, 10.8), (5.8, 4.6, 8.8)
        ]
        for row in bodyRows {
            context.fill(
                Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)),
                with: .color(shell)
            )
        }

        let outlineRows: [(CGFloat, CGFloat, CGFloat)] = [
            (4.9, 5.1, 7.8), (13.7, 5.1, 7.8), (4.1, 6.0, 1.0), (12.9, 6.0, 1.0),
            (3.2, 7.0, 1.0), (13.8, 7.0, 1.0), (2.4, 8.1, 1.0), (14.6, 8.1, 1.0),
            (2.1, 9.1, 1.0), (14.9, 9.1, 1.0), (2.4, 10.1, 1.0), (14.6, 10.1, 1.0),
            (3.2, 11.1, 1.0), (13.8, 11.1, 1.0), (4.1, 12.1, 1.0), (12.9, 12.1, 1.0)
        ]
        for row in outlineRows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)), with: .color(dark))
        }

        context.fill(Path(space.rect(6.0 + motion.shake, 6.0 + motion.vertical, 6.0, 0.9)), with: .color(dark))
        context.fill(Path(space.rect(6.8 + motion.shake, 8.1 + motion.vertical, 1.4, 2.0)), with: .color(.white))
        context.fill(Path(space.rect(10.4 + motion.shake, 8.1 + motion.vertical, 1.4, 2.0)), with: .color(.white))

        let eyeHeight: CGFloat = mode == .idle ? 0.6 : (mode == .warning ? 1.2 : blinkHeight(time: time, closedHeight: 0.2, openHeight: 1.2))
        context.fill(Path(space.rect(7.2 + motion.shake, 9.0 + motion.vertical, 0.9, eyeHeight)), with: .color(eye))
        context.fill(Path(space.rect(10.8 + motion.shake, 9.0 + motion.vertical, 0.9, eyeHeight)), with: .color(eye))

        let highlightRows: [(CGFloat, CGFloat, CGFloat)] = [
            (8.0, 4.1, 1.4), (8.0, 13.4, 1.4), (11.0, 4.6, 1.0), (11.0, 12.8, 1.0)
        ]
        for row in highlightRows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.8)), with: .color(highlight.opacity(0.55)))
        }

        // Claws
        let clawRects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.8, 8.6, 1.2, 2.0), (1.8, 7.8, 1.2, 1.0), (1.8, 10.3, 1.2, 1.0),
            (16.0, 8.6, 1.2, 2.0), (15.0, 7.8, 1.2, 1.0), (15.0, 10.3, 1.2, 1.0)
        ]
        for rect in clawRects {
            context.fill(Path(space.rect(rect.0 + motion.shake, rect.1 + motion.vertical, rect.2, rect.3)), with: .color(shell))
        }
        context.fill(Path(space.rect(1.0 + motion.shake, 8.8 + motion.vertical, 0.9, 0.9)), with: .color(dark))
        context.fill(Path(space.rect(1.0 + motion.shake, 9.9 + motion.vertical, 0.9, 0.9)), with: .color(dark))
        context.fill(Path(space.rect(16.3 + motion.shake, 8.8 + motion.vertical, 0.9, 0.9)), with: .color(dark))
        context.fill(Path(space.rect(16.3 + motion.shake, 9.9 + motion.vertical, 0.9, 0.9)), with: .color(dark))

        // Tail and legs
        let tailRows: [(CGFloat, CGFloat, CGFloat)] = [
            (13.4, 7.1, 4.0), (14.4, 6.2, 2.8), (15.4, 5.3, 1.8)
        ]
        for row in tailRows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2, 0.9)), with: .color(dark))
        }

        let legs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (6.0, 13.5, 0.9, 1.4), (5.1, 14.4, 1.6, 0.8),
            (11.1, 13.5, 0.9, 1.4), (11.3, 14.4, 1.6, 0.8),
            (7.5, 12.8, 0.9, 1.2), (10.0, 12.8, 0.9, 1.2)
        ]
        for leg in legs {
            context.fill(Path(space.rect(leg.0 + motion.shake, leg.1 + motion.vertical, leg.2, leg.3)), with: .color(dark))
        }

        if mode != .idle {
            context.fill(Path(space.rect(7.2 + motion.shake, 11.2 + motion.vertical, 1.4, 0.5)), with: .color(highlight))
            context.fill(Path(space.rect(9.4 + motion.shake, 11.2 + motion.vertical, 1.4, 0.5)), with: .color(highlight))
        }

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 13.9 + motion.shake, y: 2.1, color: kind.alertColor)
        }
    }

    private func drawQoder(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 17, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let body = Color(red: 0.12, green: 0.86, blue: 0.56)
        let belly = Color(red: 0.72, green: 0.97, blue: 0.80)
        let spike = Color(red: 0.36, green: 0.95, blue: 0.62)
        let eye = Color(red: 0.98, green: 0.95, blue: 0.76)
        let shadow = Color(red: 0.05, green: 0.32, blue: 0.18)

        drawShadow(in: context, space: space, centerX: 8.5, y: 15.5, width: 8.0 - abs(motion.bounce) * 0.25, opacity: 0.22)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.1,
                base: Color(red: 0.10, green: 0.18, blue: 0.12),
                key: Color(red: 0.20, green: 0.37, blue: 0.24),
                highlight: belly,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (13, 5.4, 7.2), (12, 4.2, 8.8), (11, 3.2, 10.0), (10, 3.0, 10.4),
            (9, 4.0, 9.6), (8, 5.2, 8.4), (7, 6.0, 6.6)
        ]
        for row in rows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)), with: .color(body))
        }
        context.fill(Path(space.rect(10.8 + motion.shake, 7.0 + motion.vertical, 2.3, 2.0)), with: .color(body))
        context.fill(Path(space.rect(1.8 + motion.shake, 9.5 + motion.vertical, 2.0, 1.0)), with: .color(body))
        context.fill(Path(space.rect(1.0 + motion.shake, 8.8 + motion.vertical, 1.6, 0.8)), with: .color(body))

        context.fill(Path(space.rect(6.1 + motion.shake, 9.3 + motion.vertical, 4.1, 2.6)), with: .color(belly))
        context.fill(Path(space.rect(4.6 + motion.shake, 5.7 + motion.vertical, 0.9, 1.0)), with: .color(spike))
        context.fill(Path(space.rect(6.2 + motion.shake, 5.1 + motion.vertical, 1.0, 1.0)), with: .color(spike))
        context.fill(Path(space.rect(7.8 + motion.shake, 5.4 + motion.vertical, 1.0, 0.9)), with: .color(spike))
        context.fill(Path(space.rect(10.6 + motion.shake, 7.9 + motion.vertical, 1.0, 1.0)), with: .color(eye))
        context.fill(Path(space.rect(11.3 + motion.shake, 8.2 + motion.vertical, 0.6, 0.6)), with: .color(shadow))
        context.fill(Path(space.rect(5.8 + motion.shake, 13.8 + motion.vertical, 1.0, 0.9)), with: .color(shadow))
        context.fill(Path(space.rect(9.2 + motion.shake, 13.8 + motion.vertical, 1.0, 0.9)), with: .color(shadow))
        context.fill(Path(space.rect(11.7 + motion.shake, 10.1 + motion.vertical, 1.0, 0.45)), with: .color(shadow.opacity(0.82)))

        if mode == .working {
            context.fill(Path(space.rect(2.6 + motion.shake, 8.3 + motion.vertical, 0.8, 0.5)), with: .color(spike.opacity(0.85)))
            context.fill(Path(space.rect(1.6 + motion.shake, 8.0 + motion.vertical, 0.8, 0.5)), with: .color(spike.opacity(0.58)))
        }

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 11.8 + motion.shake, y: 2.1, color: kind.alertColor)
        }
    }

    private func drawCodeBuddy(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 16, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let body = Color(red: 0.42, green: 0.30, blue: 1.0)
        let dark = Color(red: 0.34, green: 0.24, blue: 0.83)
        let glow = Color(red: 0.20, green: 0.90, blue: 0.73)

        drawShadow(in: context, space: space, centerX: 8, y: 15.7, width: 8.0 - abs(motion.bounce) * 0.3, opacity: 0.22)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.0,
                base: Color(red: 0.18, green: 0.15, blue: 0.30),
                key: Color(red: 0.35, green: 0.30, blue: 0.55),
                highlight: glow,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (13, 3, 9), (12, 2, 11), (11, 2, 11), (10, 2, 11),
            (9, 3, 9), (8, 3, 9), (7, 3, 9), (6, 4, 7)
        ]
        for row in rows {
            context.fill(Path(space.rect(row.1 + motion.shake, row.0 + motion.vertical, row.2 * motion.squashX, 1 * motion.squashY)), with: .color(body))
        }

        context.fill(Path(space.rect(2.8 + motion.shake, 4.5 + motion.vertical, 2.0, 1.9)), with: .color(body))
        context.fill(Path(space.rect(11.2 + motion.shake, 4.5 + motion.vertical, 2.0, 1.9)), with: .color(body))
        context.fill(Path(space.rect(3.4 + motion.shake, 5.1 + motion.vertical, 0.9, 0.8)), with: .color(glow.opacity(0.55)))
        context.fill(Path(space.rect(11.7 + motion.shake, 5.1 + motion.vertical, 0.9, 0.8)), with: .color(glow.opacity(0.55)))
        context.fill(Path(space.rect(4.1 + motion.shake, 7.2 + motion.vertical, 7.8, 2.6)), with: .color(dark))
        context.fill(Path(space.rect(12.0 + motion.shake, 11.0 + motion.vertical, 1.7, 0.8)), with: .color(body))
        context.fill(Path(space.rect(12.8 + motion.shake, 10.2 + motion.vertical, 0.9, 0.8)), with: .color(body))
        context.fill(Path(space.rect(4.1 + motion.shake, 14.0 + motion.vertical, 1.3, 1.0)), with: .color(dark))
        context.fill(Path(space.rect(10.6 + motion.shake, 14.0 + motion.vertical, 1.3, 1.0)), with: .color(dark))

        let eyeHeight: CGFloat = mode == .idle ? 0.45 : (mode == .warning ? 1.25 : blinkHeight(time: time, closedHeight: 0.2, openHeight: 1.25))
        context.fill(Path(space.rect(5.3 + motion.shake, 8.0 + motion.vertical, 1.0, eyeHeight)), with: .color(glow))
        context.fill(Path(space.rect(9.0 + motion.shake, 8.0 + motion.vertical, 1.0, eyeHeight)), with: .color(glow))

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 12.0 + motion.shake, y: 2.1, color: kind.alertColor)
        }
    }

    private func drawCopilot(
        in context: GraphicsContext,
        canvasSize: CGSize,
        time: TimeInterval,
        mode: MascotRenderMode
    ) {
        let space = PixelSpace(canvasSize, logicalWidth: 16, logicalHeight: 14, yOffset: 2)
        let motion = motionValues(for: mode, time: time)
        let shell = Color(red: 0.83, green: 0.87, blue: 0.92)
        let trim = Color(red: 0.34, green: 0.39, blue: 0.45)
        let face = Color(red: 0.96, green: 0.97, blue: 0.99)
        let glasses = Color(red: 0.07, green: 0.08, blue: 0.10)
        let eye = Color(red: 0.42, green: 0.82, blue: 1.0)
        let accent = Color(red: 0.33, green: 0.63, blue: 0.98)

        drawShadow(in: context, space: space, centerX: 8, y: 15.5, width: 7.0 - abs(motion.bounce) * 0.25, opacity: 0.21)

        if mode == .working {
            drawKeyboard(
                in: context,
                space: space,
                y: 13.0,
                base: Color(red: 0.15, green: 0.18, blue: 0.22),
                key: Color(red: 0.31, green: 0.36, blue: 0.42),
                highlight: accent,
                flashIndex: keyboardFlashIndex(time: time)
            )
        }

        context.fill(Path(space.rect(4.0 + motion.shake, 6.0 + motion.vertical, 8.0 * motion.squashX, 6.8 * motion.squashY)), with: .color(shell))
        context.fill(Path(space.rect(4.4 + motion.shake, 6.4 + motion.vertical, 7.2, 6.0)), with: .color(face))
        context.fill(Path(space.rect(5.0 + motion.shake, 13.3 + motion.vertical, 1.0, 1.1)), with: .color(trim))
        context.fill(Path(space.rect(10.0 + motion.shake, 13.3 + motion.vertical, 1.0, 1.1)), with: .color(trim))
        context.fill(Path(space.rect(6.8 + motion.shake, 4.6 + motion.vertical, 1.1, 1.4)), with: .color(trim))
        context.fill(Path(space.rect(6.2 + motion.shake, 3.8 + motion.vertical, 2.2, 0.8)), with: .color(accent))
        context.fill(Path(space.rect(3.3 + motion.shake, 8.0 + motion.vertical, 0.7, 2.2)), with: .color(trim))
        context.fill(Path(space.rect(12.0 + motion.shake, 8.0 + motion.vertical, 0.7, 2.2)), with: .color(trim))

        context.fill(Path(space.rect(5.0 + motion.shake, 7.5 + motion.vertical, 2.7, 2.2)), with: .color(glasses))
        context.fill(Path(space.rect(8.4 + motion.shake, 7.5 + motion.vertical, 2.7, 2.2)), with: .color(glasses))
        context.fill(Path(space.rect(7.7 + motion.shake, 8.2 + motion.vertical, 0.8, 0.6)), with: .color(glasses))
        context.fill(Path(space.rect(5.4 + motion.shake, 7.9 + motion.vertical, 1.9, 1.4)), with: .color(face))
        context.fill(Path(space.rect(8.8 + motion.shake, 7.9 + motion.vertical, 1.9, 1.4)), with: .color(face))

        let eyeHeight: CGFloat = mode == .idle ? 0.4 : (mode == .warning ? 1.0 : blinkHeight(time: time, closedHeight: 0.2, openHeight: 1.0))
        context.fill(Path(space.rect(6.0 + motion.shake, 8.2 + motion.vertical, 0.75, eyeHeight)), with: .color(eye))
        context.fill(Path(space.rect(9.4 + motion.shake, 8.2 + motion.vertical, 0.75, eyeHeight)), with: .color(eye))

        if mode == .working {
            context.fill(Path(space.rect(5.6 + motion.shake, 11.2 + motion.vertical, 4.8, 0.7)), with: .color(accent.opacity(0.85)))
        } else {
            context.fill(Path(space.rect(6.2 + motion.shake, 11.3 + motion.vertical, 3.6, 0.45)), with: .color(trim.opacity(0.65)))
        }

        if mode == .warning {
            drawAlertGlyph(in: context, space: space, x: 11.6 + motion.shake, y: 2.0, color: kind.alertColor)
        }
    }

    private func motionValues(for mode: MascotRenderMode, time: TimeInterval) -> MascotMotion {
        switch mode {
        case .idle:
            return MascotMotion(
                vertical: CGFloat(sin(time * 1.8) * 0.6),
                bounce: 0,
                shake: 0,
                squashX: 1,
                squashY: 1
            )
        case .working:
            let bounce = CGFloat(sin(time * .pi * 5) * 0.9)
            return MascotMotion(
                vertical: bounce,
                bounce: bounce,
                shake: 0,
                squashX: 1,
                squashY: 1
            )
        case .warning:
            let cycle = time.truncatingRemainder(dividingBy: 1.2)
            let pct = CGFloat(cycle / 1.2)
            let jump = lerp(
                [(0, 0), (0.10, -0.8), (0.18, -4.8), (0.28, 1.0), (0.36, -2.2), (0.50, 0.4), (1, 0)],
                at: pct
            )
            let shake = pct < 0.55 ? CGFloat(sin(time * 42) * 0.55) : 0
            let squashX: CGFloat = jump > 0.4 ? 1.06 : 1.0
            let squashY: CGFloat = jump > 0.4 ? 0.95 : 1.0
            return MascotMotion(
                vertical: jump,
                bounce: jump,
                shake: shake,
                squashX: squashX,
                squashY: squashY
            )
        }
    }

    private func keyboardFlashIndex(time: TimeInterval) -> Int {
        Int(time * 10) % 12
    }

    private func blinkHeight(time: TimeInterval, closedHeight: CGFloat, openHeight: CGFloat) -> CGFloat {
        let cycle = time.truncatingRemainder(dividingBy: 2.8)
        if cycle > 2.45 && cycle < 2.58 {
            return closedHeight
        }
        return openHeight
    }

    private func drawKeyboard(
        in context: GraphicsContext,
        space: PixelSpace,
        y: CGFloat,
        base: Color,
        key: Color,
        highlight: Color,
        flashIndex: Int
    ) {
        context.fill(Path(space.rect(0.5, y, 15.0, 2.6)), with: .color(base))
        for row in 0..<2 {
            for column in 0..<6 {
                let index = row * 6 + column
                let x = 1.1 + CGFloat(column) * 2.3
                let keyColor = index == flashIndex ? highlight.opacity(0.92) : key
                context.fill(Path(space.rect(x, y + 0.45 + CGFloat(row) * 1.0, 1.7, 0.55)), with: .color(keyColor))
            }
        }
    }

    private func drawAlertGlyph(
        in context: GraphicsContext,
        space: PixelSpace,
        x: CGFloat,
        y: CGFloat,
        color: Color
    ) {
        context.fill(Path(space.rect(x, y, 0.9, 2.0)), with: .color(color))
        context.fill(Path(space.rect(x, y + 2.5, 0.9, 0.9)), with: .color(color))
    }

    private func drawShadow(
        in context: GraphicsContext,
        space: PixelSpace,
        centerX: CGFloat,
        y: CGFloat,
        width: CGFloat,
        opacity: Double
    ) {
        context.fill(
            Path(roundedRect: space.rect(centerX - width / 2, y, width, 0.9), cornerRadius: max(0.8, space.pixel * 0.18)),
            with: .color(.black.opacity(opacity))
        )
    }

    private func lerp(_ frames: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = frames.first else { return 0 }
        if pct <= first.0 {
            return first.1
        }
        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let next = frames[index]
            if pct <= next.0 {
                let progress = (pct - previous.0) / (next.0 - previous.0)
                return previous.1 + (next.1 - previous.1) * progress
            }
        }
        return frames.last?.1 ?? 0
    }
}

private enum MascotRenderMode {
    case idle
    case working
    case warning
}

private struct MascotMotion {
    let vertical: CGFloat
    let bounce: CGFloat
    let shake: CGFloat
    let squashX: CGFloat
    let squashY: CGFloat
}

private struct PixelSpace {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let pixel: CGFloat
    let logicalWidth: CGFloat
    let yOffset: CGFloat

    init(_ canvasSize: CGSize, logicalWidth: CGFloat, logicalHeight: CGFloat, yOffset: CGFloat) {
        let scale = min(canvasSize.width / logicalWidth, canvasSize.height / logicalHeight)
        self.pixel = max(1, floor(scale))
        self.logicalWidth = logicalWidth
        self.offsetX = (canvasSize.width - logicalWidth * pixel) / 2
        self.offsetY = (canvasSize.height - logicalHeight * pixel) / 2
        self.yOffset = yOffset
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: offsetX + x * pixel,
            y: offsetY + (y - yOffset) * pixel,
            width: width * pixel,
            height: height * pixel
        )
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: offsetX + x * pixel,
            y: offsetY + (y - yOffset) * pixel
        )
    }
}

private struct FloatingZOverlay: View {
    let size: CGFloat
    var time: TimeInterval?

    var body: some View {
        if let time {
            overlayBody(time: time)
        } else {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                overlayBody(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func overlayBody(time: TimeInterval) -> some View {
        let cycle = 2.9
        let baseProgress = wrappedProgress((time / cycle).truncatingRemainder(dividingBy: 1))

        return ZStack(alignment: .topLeading) {
            ForEach(floatingZConfigs.indices, id: \.self) { index in
                let config = floatingZConfigs[index]
                let progress = wrappedProgress(baseProgress + config.phaseOffset)
                let visibility = floatingZVisibility(progress: progress)

                if visibility > 0.01 {
                    let fontSize = max(6, size * CGFloat(config.fontScale + progress * 0.08))
                    let xOffset = size * CGFloat(config.startX + progress * config.travelX)
                    let yOffset = size * CGFloat(config.startY - progress * config.travelY)
                    let opacity = config.maxOpacity * visibility

                    Text("z")
                        .font(.system(size: fontSize, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white.opacity(opacity))
                        .scaleEffect(0.92 + CGFloat(progress) * 0.32)
                        .shadow(color: Color.white.opacity(opacity * 0.18), radius: 1.2, y: 0.8)
                        .offset(x: xOffset, y: yOffset)
                }
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    private func wrappedProgress(_ progress: Double) -> Double {
        let wrapped = progress.truncatingRemainder(dividingBy: 1)
        return wrapped >= 0 ? wrapped : wrapped + 1
    }

    private func floatingZVisibility(progress: Double) -> Double {
        let fadeIn = min(max(progress / 0.18, 0), 1)
        let fadeOut = min(max((1 - progress) / 0.34, 0), 1)
        return fadeIn * fadeOut
    }

    private var floatingZConfigs: [FloatingZConfig] {
        [
            FloatingZConfig(phaseOffset: 0.00, fontScale: 0.16, startX: 0.40, startY: 0.28, travelX: 0.18, travelY: 0.24, maxOpacity: 0.44),
            FloatingZConfig(phaseOffset: 0.28, fontScale: 0.21, startX: 0.48, startY: 0.20, travelX: 0.20, travelY: 0.30, maxOpacity: 0.58),
            FloatingZConfig(phaseOffset: 0.56, fontScale: 0.26, startX: 0.56, startY: 0.12, travelX: 0.22, travelY: 0.34, maxOpacity: 0.72)
        ]
    }
}

private struct FloatingZConfig {
    let phaseOffset: Double
    let fontScale: Double
    let startX: Double
    let startY: Double
    let travelX: Double
    let travelY: Double
    let maxOpacity: Double
}

private struct AlertHalo: View {
    let tint: Color
    let size: CGFloat
    var time: TimeInterval?

    var body: some View {
        if let time {
            haloBody(time: time)
        } else {
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                haloBody(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func haloBody(time: TimeInterval) -> some View {
        let pulse = CGFloat(sin(time * 6) * 0.5 + 0.5)

        return Circle()
            .fill(tint.opacity(0.10 + pulse * 0.12))
            .frame(width: size * (0.78 + pulse * 0.10))
            .blur(radius: size * 0.07)
    }
}

#Preview("Mascot Grid") {
    VStack(spacing: 20) {
        ForEach(MascotStatus.allCases, id: \.self) { status in
            HStack(spacing: 14) {
                ForEach(MascotKind.allCases) { kind in
                    VStack(spacing: 8) {
                        MascotView(kind: kind, status: status, size: 32)
                        Text(kind.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    .padding()
    .background(Color.black)
}
