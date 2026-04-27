import AppKit
import Combine
import SwiftUI

@MainActor
final class HardwareSimulatorWindowController: NSWindowController {
    static let shared = HardwareSimulatorWindowController()

    private let model = HardwareSimulatorModel()

    private init() {
        let hostingView = NSHostingView(rootView: HardwareSimulatorView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ping Island Hardware Simulator"
        window.contentView = hostingView
        window.minSize = NSSize(width: 460, height: 360)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class HardwareSimulatorModel: ObservableObject {
    @Published var mascot = "island"
    @Published var status = "idle"
    @Published var tool = ""
    @Published var brightness = 0.75
    @Published var orientation: HardwareSimulatorOrientation = .portrait

    var frame: HardwareSimulatorFrame {
        HardwareSimulatorFrame(
            mascot: mascot,
            status: status,
            tool: tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : tool,
            brightness: brightness,
            orientation: orientation
        )
    }

    var lineProtocol: String {
        HardwareSimulatorCodec.lineProtocol(frame)
    }
}

private struct HardwareSimulatorView: View {
    @ObservedObject var model: HardwareSimulatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hardware Simulator")
                        .font(.system(size: 22, weight: .bold))
                    Text("BLE/status protocol preview for future desk hardware.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                simulatorPreview
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text("Mascot")
                    TextField("mascot", text: $model.mascot)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Status")
                    Picker("", selection: $model.status) {
                        Text("idle").tag("idle")
                        Text("working").tag("working")
                        Text("approval").tag("approval")
                        Text("completed").tag("completed")
                        Text("error").tag("error")
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("Tool")
                    TextField("optional tool", text: $model.tool)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Brightness")
                    Slider(value: $model.brightness, in: 0...1)
                }

                GridRow {
                    Text("Orientation")
                    Picker("", selection: $model.orientation) {
                        ForEach(HardwareSimulatorOrientation.allCases) { orientation in
                            Text(orientation.rawValue).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Protocol Frame")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(model.lineProtocol)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var simulatorPreview: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(previewTint.opacity(0.22))
            .frame(width: 92, height: model.orientation == .portrait ? 132 : 72)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: previewSymbol)
                        .font(.system(size: 26, weight: .bold))
                    Text(model.status)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(previewTint)
            )
            .opacity(0.35 + model.brightness * 0.65)
    }

    private var previewSymbol: String {
        switch model.status {
        case "working": return "gearshape.2.fill"
        case "approval": return "hand.raised.fill"
        case "completed": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "sparkles"
        }
    }

    private var previewTint: Color {
        switch model.status {
        case "working": return .blue
        case "approval": return .orange
        case "completed": return .green
        case "error": return .red
        default: return .secondary
        }
    }
}
