import Foundation

enum HardwareSimulatorOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape
    case inverted

    var id: String { rawValue }
}

struct HardwareSimulatorFrame: Codable, Equatable, Sendable {
    let mascot: String
    let status: String
    let tool: String?
    let brightness: Double
    let orientation: HardwareSimulatorOrientation
    let timestamp: Date

    init(
        mascot: String,
        status: String,
        tool: String? = nil,
        brightness: Double,
        orientation: HardwareSimulatorOrientation,
        timestamp: Date = Date()
    ) {
        self.mascot = mascot
        self.status = status
        self.tool = tool
        self.brightness = min(1, max(0, brightness))
        self.orientation = orientation
        self.timestamp = timestamp
    }
}

enum HardwareSimulatorCodec {
    static func encode(_ frame: HardwareSimulatorFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(frame)
    }

    static func decode(_ data: Data) throws -> HardwareSimulatorFrame {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HardwareSimulatorFrame.self, from: data)
    }

    static func lineProtocol(_ frame: HardwareSimulatorFrame) -> String {
        guard let data = try? encode(frame),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return "PING_ISLAND_HW \(json)"
    }
}
