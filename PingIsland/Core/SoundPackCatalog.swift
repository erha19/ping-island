import AppKit
import Combine
import Foundation

enum NotificationEvent: String, CaseIterable, Identifiable {
    case processingStarted
    case attentionRequired
    case taskCompleted
    case taskError
    case resourceLimit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processingStarted:
            return "开始处理"
        case .attentionRequired:
            return "需要介入"
        case .taskCompleted:
            return "完成"
        case .taskError:
            return "任务失败"
        case .resourceLimit:
            return "资源受限"
        }
    }

    var subtitle: String {
        switch self {
        case .processingStarted:
            return "会话开始处理、运行工具或进入阶段切换。"
        case .attentionRequired:
            return "等待审批、回答问题或其他需要你接手的时刻。"
        case .taskCompleted:
            return "当前处理结束，回到等待你下一步输入。"
        case .taskError:
            return "工具或子代理执行失败。"
        case .resourceLimit:
            return "进入 PreCompact / compacting，通常表示上下文或资源逼近限制。"
        }
    }

    var defaultSound: NotificationSound {
        switch self {
        case .processingStarted:
            return .tink
        case .attentionRequired:
            return .glass
        case .taskCompleted:
            return .blow
        case .taskError:
            return .basso
        case .resourceLimit:
            return .morse
        }
    }

    var cespCategories: [String] {
        switch self {
        case .processingStarted:
            return ["task.acknowledge", "session.start"]
        case .attentionRequired:
            return ["input.required"]
        case .taskCompleted:
            return ["task.complete"]
        case .taskError:
            return ["task.error"]
        case .resourceLimit:
            return ["resource.limit"]
        }
    }
}

enum SoundThemeMode: String, CaseIterable, Identifiable {
    case builtIn
    case soundPack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn:
            return "系统音"
        case .soundPack:
            return "主题包"
        }
    }

    var subtitle: String {
        switch self {
        case .builtIn:
            return "为不同阶段分别选择 macOS 系统音。"
        case .soundPack:
            return "使用兼容 OpenPeon / CESP 的本地音效包。"
        }
    }
}

struct OpenPeonSoundEntry: Decodable, Equatable {
    let file: String
    let label: String?
    let sha256: String?
}

struct OpenPeonCategoryManifest: Decodable, Equatable {
    let sounds: [OpenPeonSoundEntry]
}

struct OpenPeonManifest: Decodable, Equatable {
    let cespVersion: String
    let name: String
    let displayName: String?
    let version: String?
    let description: String?
    let categories: [String: OpenPeonCategoryManifest]

    enum CodingKeys: String, CodingKey {
        case cespVersion = "cesp_version"
        case name
        case displayName = "display_name"
        case version
        case description
        case categories
    }
}

struct SoundPack: Identifiable, Equatable {
    let rootURL: URL
    let manifest: OpenPeonManifest

    var id: String { rootURL.path }

    var displayName: String {
        manifest.displayName ?? manifest.name
    }

    var detailText: String {
        if let version = manifest.version, !version.isEmpty {
            return version
        }
        return rootURL.lastPathComponent
    }

    func sounds(for category: String) -> [OpenPeonSoundEntry] {
        manifest.categories[category]?.sounds ?? []
    }
}

@MainActor
final class SoundPackCatalog: NSObject, ObservableObject, NSSoundDelegate {
    static let shared = SoundPackCatalog()

    @Published private(set) var availablePacks: [SoundPack] = []

    private let defaults = UserDefaults.standard
    private var activeSound: NSSound?
    private var lastPlayedSoundPathByCategory: [String: String] = [:]

    private enum Keys {
        static let importedPackPaths = "importedSoundPackPaths"
    }

    private override init() {
        super.init()
        refresh()
    }

    func refresh() {
        var dedupedRoots: [String: URL] = [:]
        for url in discoverPackRoots() + importedPackRoots() {
            let standardized = url.standardizedFileURL
            dedupedRoots[standardized.path] = standardized
        }

        let packs = dedupedRoots.values.compactMap(loadPack(at:))
            .sorted {
                if $0.displayName == $1.displayName {
                    return $0.rootURL.path < $1.rootURL.path
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        availablePacks = packs
    }

    func importPack() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择包含 openpeon.json 的音效包目录。"

        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else {
            return false
        }
        guard loadPack(at: url) != nil else {
            NSSound.beep()
            return false
        }

        var paths = Set(importedPackRoots().map(\.path))
        paths.insert(url.path)
        defaults.set(Array(paths).sorted(), forKey: Keys.importedPackPaths)
        refresh()
        return true
    }

    func pack(for path: String?) -> SoundPack? {
        guard let path, !path.isEmpty else { return nil }
        return availablePacks.first { $0.rootURL.path == path }
    }

    func displayName(for path: String?) -> String {
        pack(for: path)?.displayName ?? "未选择"
    }

    @discardableResult
    func play(event: NotificationEvent, packPath: String?, volume: Float) -> Bool {
        guard let pack = pack(for: packPath) else { return false }

        for category in event.cespCategories {
            if play(category: category, in: pack, volume: volume) {
                return true
            }
        }

        return false
    }

    private func play(category: String, in pack: SoundPack, volume: Float) -> Bool {
        let entries = pack.sounds(for: category)
        guard !entries.isEmpty else { return false }

        let lastPlayedPath = lastPlayedSoundPathByCategory[category]
        let selectable = entries.filter { $0.file != lastPlayedPath }
        let entry = (selectable.isEmpty ? entries : selectable).randomElement()

        guard let entry,
              let soundURL = resolvedSoundURL(for: entry, in: pack),
              let sound = NSSound(contentsOf: soundURL, byReference: true) else {
            return false
        }

        sound.volume = volume
        sound.delegate = self
        activeSound = sound
        lastPlayedSoundPathByCategory[category] = entry.file
        return sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        if activeSound === sound {
            activeSound = nil
        }
    }

    private func importedPackRoots() -> [URL] {
        let paths = defaults.stringArray(forKey: Keys.importedPackPaths) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func discoverPackRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)

        let candidateDirectories = [
            home.appendingPathComponent(".openpeon/packs", isDirectory: true),
            home.appendingPathComponent(".claude/hooks/peon-ping/packs", isDirectory: true),
            cwd.appendingPathComponent(".claude/hooks/peon-ping/packs", isDirectory: true)
        ]

        var roots: [URL] = []
        for directory in candidateDirectories where fileExists(directory) {
            roots.append(contentsOf: packDirectories(in: directory))
        }
        return roots
    }

    private func packDirectories(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var roots: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "openpeon.json" else { continue }
            roots.append(url.deletingLastPathComponent())
            enumerator.skipDescendants()
        }

        return roots
    }

    private func loadPack(at rootURL: URL) -> SoundPack? {
        let manifestURL = rootURL.appendingPathComponent("openpeon.json")
        guard fileExists(manifestURL) else { return nil }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(OpenPeonManifest.self, from: data)
            guard manifest.cespVersion.hasPrefix("1.") else {
                return nil
            }
            return SoundPack(rootURL: rootURL, manifest: manifest)
        } catch {
            return nil
        }
    }

    private func resolvedSoundURL(for entry: OpenPeonSoundEntry, in pack: SoundPack) -> URL? {
        let root = pack.rootURL.standardizedFileURL
        let resolved = root.appendingPathComponent(entry.file).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
            return nil
        }
        guard fileExists(resolved), hasSupportedAudioExtension(resolved), hasValidMagicBytes(resolved) else {
            return nil
        }

        return resolved
    }

    private func hasSupportedAudioExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "wav", "ogg"].contains(ext)
    }

    private func hasValidMagicBytes(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 12) else {
            return false
        }
        try? handle.close()

        let bytes = [UInt8](data)
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "wav":
            return bytes.starts(with: [0x52, 0x49, 0x46, 0x46])
        case "ogg":
            return bytes.starts(with: [0x4F, 0x67, 0x67, 0x53])
        case "mp3":
            if bytes.starts(with: [0x49, 0x44, 0x33]) {
                return true
            }
            if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
                return true
            }
            return false
        default:
            return false
        }
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
