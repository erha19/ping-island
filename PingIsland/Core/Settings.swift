//
//  Settings.swift
//  PingIsland
//
//  App settings manager using UserDefaults
//

import AppKit
import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    func resolvedLanguageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system:
            let preferredLanguage = preferredLanguages.first?.lowercased() ?? ""
            if preferredLanguage.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    func resolvedLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedLanguageCode(preferredLanguages: preferredLanguages))
    }
}

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum UsageValueMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .used:
            return "已用量"
        case .remaining:
            return "剩余量"
        }
    }
}

enum NotchDisplayMode: String, CaseIterable, Identifiable {
    case compact
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "简约"
        case .detailed:
            return "详细"
        }
    }

    var subtitle: String {
        switch self {
        case .compact:
            return "只显示图标和会话数量"
        case .detailed:
            return "额外显示激活会话的最新消息"
        }
    }
}

enum SubagentVisibilityMode: String, CaseIterable, Identifiable {
    case hidden
    case visible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden:
            return "不显示"
        case .visible:
            return "显示"
        }
    }

    var subtitle: String {
        switch self {
        case .hidden:
            return "主列表里隐藏所有子 Agent 消息项"
        case .visible:
            return "主列表里展示所有子 Agent 消息项"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case Self.hidden.rawValue:
            self = .hidden
        case Self.visible.rawValue, "firstLevelOnly", "all":
            self = .visible
        default:
            return nil
        }
    }
}

enum NotchPetStyle: String, CaseIterable, Identifiable {
    case crab
    case slime
    case cat
    case sittingCat
    case owl
    case snowyOwl
    case bee
    case roundBlob
    case antennaBean
    case tinyDino

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crab:
            return "小螃蟹"
        case .slime:
            return "果冻史莱姆"
        case .cat:
            return "团子猫"
        case .sittingCat:
            return "坐着猫"
        case .owl:
            return "豆豆鸮"
        case .snowyOwl:
            return "雪团鸮"
        case .bee:
            return "小蜜蜂"
        case .roundBlob:
            return "正面团子兽"
        case .antennaBean:
            return "天线豆豆"
        case .tinyDino:
            return "侧身小恐龙"
        }
    }

    var subtitle: String {
        switch self {
        case .crab:
            return "经典横向步行动画"
        case .slime:
            return "软弹变形与高光晃动"
        case .cat:
            return "尾巴摆动和眨眼反馈"
        case .sittingCat:
            return "一直端坐，支持更多表情动作"
        case .owl:
            return "轻拍翅膀和点头观察"
        case .snowyOwl:
            return "圆脸立姿与扑翼巡航"
        case .bee:
            return "条纹圆身与振翅动画"
        case .roundBlob:
            return "早期口袋宠物式正面团子构图"
        case .antennaBean:
            return "大头小身与双角剪影"
        case .tinyDino:
            return "侧身尾巴外扩的经典小兽构图"
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    private let defaults: UserDefaults
    private var isBootstrapping = true
    private var subagentVisibilityModeStorage: SubagentVisibilityMode

    // MARK: - Keys

    private enum Keys {
        static let appLanguage = "appLanguage"
        static let notificationSound = "notificationSound"
        static let soundEnabled = "soundEnabled"
        static let soundVolume = "soundVolume"
        static let temporarilyMuteNotificationsUntil = "temporarilyMuteNotificationsUntil"
        static let processingStartSound = "processingStartSound"
        static let attentionRequiredSound = "attentionRequiredSound"
        static let taskCompletedSound = "taskCompletedSound"
        static let taskErrorSound = "taskErrorSound"
        static let resourceLimitSound = "resourceLimitSound"
        static let processingStartSoundEnabled = "processingStartSoundEnabled"
        static let attentionRequiredSoundEnabled = "attentionRequiredSoundEnabled"
        static let taskCompletedSoundEnabled = "taskCompletedSoundEnabled"
        static let taskErrorSoundEnabled = "taskErrorSoundEnabled"
        static let resourceLimitSoundEnabled = "resourceLimitSoundEnabled"
        static let soundThemeMode = "soundThemeMode"
        static let island8BitStartSoundMigrated = "island8BitStartSoundMigrated"
        static let selectedSoundPackPath = "selectedSoundPackPath"
        static let hideInFullscreen = "hideInFullscreen"
        static let autoHideWhenIdle = "autoHideWhenIdle"
        static let autoCollapseOnLeave = "autoCollapseOnLeave"
        static let smartSuppression = "smartSuppression"
        static let autoOpenCompletionPanel = "autoOpenCompletionPanel"
        static let autoOpenCompactedNotificationPanel = "autoOpenCompactedNotificationPanel"
        static let showAgentDetail = "showAgentDetail"
        static let subagentVisibilityMode = "subagentVisibilityMode"
        static let legacyCodexSubagentVisibilityMode = "codexSubagentVisibilityMode"
        static let showUsage = "showUsage"
        static let usageValueMode = "usageValueMode"
        static let contentFontSize = "contentFontSize"
        static let maxPanelHeight = "maxPanelHeight"
        static let notchPetStyle = "notchPetStyle"
        static let notchDisplayMode = "notchDisplayMode"
        static let mascotOverrides = "mascotOverrides"
        static let openActiveSessionShortcut = "openActiveSessionShortcut"
        static let openSessionListShortcut = "openSessionListShortcut"
    }

    // MARK: - Published Settings

    @Published var appLanguage: AppLanguage {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
        }
    }

    @Published var notificationSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notificationSound.rawValue, forKey: Keys.notificationSound)
            taskCompletedSound = notificationSound
        }
    }

    @Published var soundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(soundEnabled, forKey: Keys.soundEnabled)
        }
    }

    @Published var soundVolume: Double {
        didSet {
            let clamped = min(max(soundVolume, 0), 1)
            if soundVolume != clamped {
                soundVolume = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(soundVolume, forKey: Keys.soundVolume)
        }
    }

    @Published var temporarilyMuteNotificationsUntil: Date? {
        didSet {
            guard !isBootstrapping else { return }

            if let temporarilyMuteNotificationsUntil {
                defaults.set(
                    temporarilyMuteNotificationsUntil.timeIntervalSince1970,
                    forKey: Keys.temporarilyMuteNotificationsUntil
                )
            } else {
                defaults.removeObject(forKey: Keys.temporarilyMuteNotificationsUntil)
            }
        }
    }

    @Published var processingStartSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(processingStartSound.rawValue, forKey: Keys.processingStartSound)
        }
    }

    @Published var attentionRequiredSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(attentionRequiredSound.rawValue, forKey: Keys.attentionRequiredSound)
        }
    }

    @Published var taskCompletedSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskCompletedSound.rawValue, forKey: Keys.taskCompletedSound)
            if notificationSound != taskCompletedSound {
                notificationSound = taskCompletedSound
            }
        }
    }

    @Published var taskErrorSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskErrorSound.rawValue, forKey: Keys.taskErrorSound)
        }
    }

    @Published var resourceLimitSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(resourceLimitSound.rawValue, forKey: Keys.resourceLimitSound)
        }
    }

    @Published var processingStartSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(processingStartSoundEnabled, forKey: Keys.processingStartSoundEnabled)
        }
    }

    @Published var attentionRequiredSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(attentionRequiredSoundEnabled, forKey: Keys.attentionRequiredSoundEnabled)
        }
    }

    @Published var taskCompletedSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskCompletedSoundEnabled, forKey: Keys.taskCompletedSoundEnabled)
        }
    }

    @Published var taskErrorSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskErrorSoundEnabled, forKey: Keys.taskErrorSoundEnabled)
        }
    }

    @Published var resourceLimitSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(resourceLimitSoundEnabled, forKey: Keys.resourceLimitSoundEnabled)
        }
    }

    @Published var soundThemeMode: SoundThemeMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(soundThemeMode.rawValue, forKey: Keys.soundThemeMode)
            applyIsland8BitStartSoundMigrationIfNeeded(for: soundThemeMode)
        }
    }

    @Published var selectedSoundPackPath: String {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(selectedSoundPackPath, forKey: Keys.selectedSoundPackPath)
        }
    }

    @Published var hideInFullscreen: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(hideInFullscreen, forKey: Keys.hideInFullscreen)
        }
    }

    @Published var autoHideWhenIdle: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoHideWhenIdle, forKey: Keys.autoHideWhenIdle)
        }
    }

    @Published var autoCollapseOnLeave: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoCollapseOnLeave, forKey: Keys.autoCollapseOnLeave)
        }
    }

    @Published var smartSuppression: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(smartSuppression, forKey: Keys.smartSuppression)
        }
    }

    @Published var autoOpenCompletionPanel: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoOpenCompletionPanel, forKey: Keys.autoOpenCompletionPanel)
        }
    }

    @Published var autoOpenCompactedNotificationPanel: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoOpenCompactedNotificationPanel, forKey: Keys.autoOpenCompactedNotificationPanel)
        }
    }

    @Published var showAgentDetail: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showAgentDetail, forKey: Keys.showAgentDetail)
        }
    }

    var subagentVisibilityMode: SubagentVisibilityMode {
        get { subagentVisibilityModeStorage }
        set {
            let shouldUpdatePublishedState = subagentVisibilityModeStorage != newValue
            if shouldUpdatePublishedState {
                objectWillChange.send()
                subagentVisibilityModeStorage = newValue
            }

            guard !isBootstrapping else { return }

            let persistedValue = newValue.rawValue
            let primaryStoredValue = defaults.string(forKey: Keys.subagentVisibilityMode)
            let legacyStoredValue = defaults.string(forKey: Keys.legacyCodexSubagentVisibilityMode)
            guard shouldUpdatePublishedState
                    || primaryStoredValue != persistedValue
                    || legacyStoredValue != persistedValue else { return }

            defaults.set(persistedValue, forKey: Keys.subagentVisibilityMode)
            defaults.set(persistedValue, forKey: Keys.legacyCodexSubagentVisibilityMode)
        }
    }

    @Published var showUsage: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showUsage, forKey: Keys.showUsage)
        }
    }

    @Published var usageValueMode: UsageValueMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(usageValueMode.rawValue, forKey: Keys.usageValueMode)
        }
    }

    @Published var contentFontSize: Double {
        didSet {
            let clamped = min(max(contentFontSize, 11), 17)
            if contentFontSize != clamped {
                contentFontSize = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(contentFontSize, forKey: Keys.contentFontSize)
        }
    }

    @Published var maxPanelHeight: Double {
        didSet {
            let clamped = min(max(maxPanelHeight, 480), 700)
            if maxPanelHeight != clamped {
                maxPanelHeight = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(maxPanelHeight, forKey: Keys.maxPanelHeight)
        }
    }

    @Published var notchPetStyle: NotchPetStyle {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notchPetStyle.rawValue, forKey: Keys.notchPetStyle)
        }
    }

    @Published var notchDisplayMode: NotchDisplayMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notchDisplayMode.rawValue, forKey: Keys.notchDisplayMode)
        }
    }

    @Published var mascotOverrides: [String: String] {
        didSet {
            let sanitized = Self.sanitizedMascotOverrides(mascotOverrides)
            if mascotOverrides != sanitized {
                mascotOverrides = sanitized
                return
            }
            guard !isBootstrapping else { return }
            Self.persistValue(mascotOverrides, defaults: defaults, key: Keys.mascotOverrides)
        }
    }

    @Published var openActiveSessionShortcut: GlobalShortcut? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistShortcut(openActiveSessionShortcut, defaults: defaults, key: Keys.openActiveSessionShortcut)
        }
    }

    @Published var openSessionListShortcut: GlobalShortcut? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistShortcut(openSessionListShortcut, defaults: defaults, key: Keys.openSessionListShortcut)
        }
    }

    func mascotOverride(for client: MascotClient) -> MascotKind? {
        guard let rawValue = mascotOverrides[client.rawValue] else {
            return nil
        }
        return MascotKind(rawValue: rawValue)
    }

    func mascotKind(for client: MascotClient) -> MascotKind {
        mascotOverride(for: client) ?? client.defaultMascotKind
    }

    func hasCustomMascot(for client: MascotClient) -> Bool {
        mascotOverride(for: client) != nil
    }

    func setMascotOverride(_ mascot: MascotKind?, for client: MascotClient) {
        var updated = mascotOverrides
        if let mascot, mascot != client.defaultMascotKind {
            updated[client.rawValue] = mascot.rawValue
        } else {
            updated.removeValue(forKey: client.rawValue)
        }
        mascotOverrides = updated
    }

    func resetMascotOverrides() {
        mascotOverrides = [:]
    }

    func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        switch action {
        case .openActiveSession:
            return openActiveSessionShortcut
        case .openSessionList:
            return openSessionListShortcut
        }
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: GlobalShortcutAction) {
        let normalized = Self.sanitizedShortcut(shortcut)

        switch action {
        case .openActiveSession:
            openActiveSessionShortcut = normalized
            if normalized != nil, normalized == openSessionListShortcut {
                openSessionListShortcut = nil
            }
        case .openSessionList:
            openSessionListShortcut = normalized
            if normalized != nil, normalized == openActiveSessionShortcut {
                openActiveSessionShortcut = nil
            }
        }
    }

    func resetShortcut(_ action: GlobalShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    var customizedMascotClientCount: Int {
        mascotOverrides.count
    }

    var locale: Locale {
        appLanguage.resolvedLocale()
    }

    var areNotificationsMutedTemporarily: Bool {
        Self.isNotificationMuteActive(until: temporarilyMuteNotificationsUntil)
    }

    func muteNotifications(for duration: TimeInterval, now: Date = Date()) {
        temporarilyMuteNotificationsUntil = now.addingTimeInterval(duration)
    }

    nonisolated static func isNotificationMuteActive(until date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date > now
    }

    private static func decodeValue<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private static func persistValue<T: Encodable>(
        _ value: T?,
        defaults: UserDefaults,
        key: String
    ) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        guard let data = try? JSONEncoder().encode(value) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private static func boolValue(
        from defaults: UserDefaults,
        key: String,
        exists: Bool,
        default defaultValue: Bool
    ) -> Bool {
        exists ? defaults.bool(forKey: key) : defaultValue
    }

    private static func doubleValue(
        from defaults: UserDefaults,
        key: String,
        exists: Bool,
        default defaultValue: Double
    ) -> Double {
        exists ? defaults.double(forKey: key) : defaultValue
    }

    private func containsPersistedValue(forKey key: String) -> Bool {
        defaults.dictionaryRepresentation()[key] != nil
    }

    private static func sanitizedMascotOverrides(_ rawOverrides: [String: String]) -> [String: String] {
        rawOverrides.reduce(into: [:]) { result, entry in
            guard let client = MascotClient(rawValue: entry.key),
                  let mascot = MascotKind(rawValue: entry.value),
                  mascot != client.defaultMascotKind else {
                return
            }
            result[client.rawValue] = mascot.rawValue
        }
    }

    private static func sanitizedShortcut(_ shortcut: GlobalShortcut?) -> GlobalShortcut? {
        guard let shortcut else { return nil }
        return GlobalShortcut(keyCode: shortcut.keyCode, modifierFlags: shortcut.modifierFlags)
    }

    private static func shortcut(from defaults: UserDefaults, key: String) -> GlobalShortcut? {
        if let shortcut = decodeValue(GlobalShortcut.self, from: defaults, key: key) {
            return sanitizedShortcut(shortcut)
        }

        guard let rawValue = defaults.dictionary(forKey: key) as? [String: Int] else {
            return nil
        }

        guard let keyCode = rawValue["keyCode"],
              let modifiers = rawValue["modifierFlags"] else {
            return nil
        }

        let shortcut = GlobalShortcut(
            keyCode: UInt16(keyCode),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )

        persistShortcut(shortcut, defaults: defaults, key: key)
        return shortcut
    }

    private static func resolvedShortcut(
        from defaults: UserDefaults,
        key: String,
        action: GlobalShortcutAction
    ) -> GlobalShortcut? {
        let persistedShortcut = shortcut(from: defaults, key: key)

        if let persistedShortcut,
           action.legacyDefaultShortcuts.contains(persistedShortcut) {
            return action.defaultShortcut
        }

        return persistedShortcut ?? action.defaultShortcut
    }

    private static func persistShortcut(_ shortcut: GlobalShortcut?, defaults: UserDefaults, key: String) {
        persistValue(shortcut, defaults: defaults, key: key)
    }

    private static func mascotOverrides(from defaults: UserDefaults, key: String) -> [String: String] {
        if let overrides = decodeValue([String: String].self, from: defaults, key: key) {
            return overrides
        }

        let legacyOverrides = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if !legacyOverrides.isEmpty {
            persistValue(legacyOverrides, defaults: defaults, key: key)
        }

        return legacyOverrides
    }

    private func applyIsland8BitStartSoundMigrationIfNeeded(for mode: SoundThemeMode) {
        guard mode == .island8Bit else { return }
        guard !containsPersistedValue(forKey: Keys.island8BitStartSoundMigrated) else { return }

        if containsPersistedValue(forKey: Keys.processingStartSoundEnabled),
           processingStartSoundEnabled == false {
            processingStartSoundEnabled = true
        }

        defaults.set(true, forKey: Keys.island8BitStartSoundMigrated)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.subagentVisibilityModeStorage = .visible
        let persistedKeys = Set(defaults.dictionaryRepresentation().keys)
        let appLanguageRaw = defaults.string(forKey: Keys.appLanguage)
        let legacyNotificationSound = NotificationSound(
            rawValue: defaults.string(forKey: Keys.notificationSound) ?? ""
        ) ?? .blow
        let usageValueModeRaw = defaults.string(forKey: Keys.usageValueMode)
        let soundThemeModeRaw = defaults.string(forKey: Keys.soundThemeMode)
        let resolvedSoundThemeMode = SoundThemeMode(
            rawValue: soundThemeModeRaw ?? ""
        ) ?? .island8Bit
        let subagentVisibilityModeRaw = defaults.string(forKey: Keys.subagentVisibilityMode)
            ?? defaults.string(forKey: Keys.legacyCodexSubagentVisibilityMode)
        let temporarilyMuteNotificationsUntilTimestamp = persistedKeys.contains(Keys.temporarilyMuteNotificationsUntil)
            ? defaults.double(forKey: Keys.temporarilyMuteNotificationsUntil)
            : nil
        let notchPetStyleRaw = defaults.string(forKey: Keys.notchPetStyle)
        let notchDisplayModeRaw = defaults.string(forKey: Keys.notchDisplayMode)
        let mascotOverrideRaw = Self.mascotOverrides(from: defaults, key: Keys.mascotOverrides)
        let openActiveSessionShortcut = Self.resolvedShortcut(
            from: defaults,
            key: Keys.openActiveSessionShortcut,
            action: .openActiveSession
        )
        let openSessionListShortcut = Self.resolvedShortcut(
            from: defaults,
            key: Keys.openSessionListShortcut,
            action: .openSessionList
        )
        let temporarilyMuteNotificationsUntil = temporarilyMuteNotificationsUntilTimestamp.map {
            Date(timeIntervalSince1970: $0)
        }
        let activeTemporaryMute =
            Self.isNotificationMuteActive(until: temporarilyMuteNotificationsUntil)
            ? temporarilyMuteNotificationsUntil
            : nil

        _appLanguage = Published(initialValue: AppLanguage(rawValue: appLanguageRaw ?? "") ?? .system)
        _notificationSound = Published(initialValue: legacyNotificationSound)
        _soundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.soundEnabled,
            exists: persistedKeys.contains(Keys.soundEnabled),
            default: true
        ))
        _soundVolume = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.soundVolume,
            exists: persistedKeys.contains(Keys.soundVolume),
            default: 0.9
        ))
        _temporarilyMuteNotificationsUntil = Published(initialValue: activeTemporaryMute)
        _processingStartSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.processingStartSound) ?? ""
        ) ?? .tink)
        _attentionRequiredSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.attentionRequiredSound) ?? ""
        ) ?? .glass)
        _taskCompletedSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.taskCompletedSound) ?? ""
        ) ?? legacyNotificationSound)
        _taskErrorSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.taskErrorSound) ?? ""
        ) ?? .basso)
        _resourceLimitSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.resourceLimitSound) ?? ""
        ) ?? .morse)
        _processingStartSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.processingStartSoundEnabled,
            exists: persistedKeys.contains(Keys.processingStartSoundEnabled),
            default: true
        ))
        _attentionRequiredSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.attentionRequiredSoundEnabled,
            exists: persistedKeys.contains(Keys.attentionRequiredSoundEnabled),
            default: true
        ))
        _taskCompletedSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.taskCompletedSoundEnabled,
            exists: persistedKeys.contains(Keys.taskCompletedSoundEnabled),
            default: true
        ))
        _taskErrorSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.taskErrorSoundEnabled,
            exists: persistedKeys.contains(Keys.taskErrorSoundEnabled),
            default: true
        ))
        _resourceLimitSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.resourceLimitSoundEnabled,
            exists: persistedKeys.contains(Keys.resourceLimitSoundEnabled),
            default: true
        ))
        _soundThemeMode = Published(initialValue: resolvedSoundThemeMode)
        _selectedSoundPackPath = Published(initialValue: defaults.string(forKey: Keys.selectedSoundPackPath) ?? "")
        _hideInFullscreen = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.hideInFullscreen,
            exists: persistedKeys.contains(Keys.hideInFullscreen),
            default: true
        ))
        _autoHideWhenIdle = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoHideWhenIdle,
            exists: persistedKeys.contains(Keys.autoHideWhenIdle),
            default: false
        ))
        _autoCollapseOnLeave = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoCollapseOnLeave,
            exists: persistedKeys.contains(Keys.autoCollapseOnLeave),
            default: true
        ))
        _smartSuppression = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.smartSuppression,
            exists: persistedKeys.contains(Keys.smartSuppression),
            default: true
        ))
        _autoOpenCompletionPanel = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoOpenCompletionPanel,
            exists: persistedKeys.contains(Keys.autoOpenCompletionPanel),
            default: true
        ))
        _autoOpenCompactedNotificationPanel = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoOpenCompactedNotificationPanel,
            exists: persistedKeys.contains(Keys.autoOpenCompactedNotificationPanel),
            default: true
        ))
        _showAgentDetail = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.showAgentDetail,
            exists: persistedKeys.contains(Keys.showAgentDetail),
            default: true
        ))
        subagentVisibilityModeStorage = SubagentVisibilityMode(
            persistedValue: subagentVisibilityModeRaw ?? ""
        ) ?? .visible
        if defaults.string(forKey: Keys.subagentVisibilityMode) == nil {
            defaults.set(subagentVisibilityModeStorage.rawValue, forKey: Keys.subagentVisibilityMode)
        }
        _showUsage = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.showUsage,
            exists: persistedKeys.contains(Keys.showUsage),
            default: false
        ))
        _usageValueMode = Published(initialValue: UsageValueMode(rawValue: usageValueModeRaw ?? "") ?? .used)
        _contentFontSize = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.contentFontSize,
            exists: persistedKeys.contains(Keys.contentFontSize),
            default: 13
        ))
        _maxPanelHeight = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.maxPanelHeight,
            exists: persistedKeys.contains(Keys.maxPanelHeight),
            default: 580
        ))
        _notchPetStyle = Published(initialValue: NotchPetStyle(rawValue: notchPetStyleRaw ?? "") ?? .cat)
        _notchDisplayMode = Published(initialValue: NotchDisplayMode(rawValue: notchDisplayModeRaw ?? "") ?? .compact)
        _mascotOverrides = Published(initialValue: Self.sanitizedMascotOverrides(mascotOverrideRaw))
        _openActiveSessionShortcut = Published(initialValue: openActiveSessionShortcut)
        _openSessionListShortcut = Published(initialValue: openSessionListShortcut)

        if defaults.string(forKey: Keys.soundThemeMode) == nil {
            defaults.set(resolvedSoundThemeMode.rawValue, forKey: Keys.soundThemeMode)
        }
        if activeTemporaryMute == nil {
            defaults.removeObject(forKey: Keys.temporarilyMuteNotificationsUntil)
        }
        if !persistedKeys.contains(Keys.processingStartSoundEnabled) {
            defaults.set(true, forKey: Keys.processingStartSoundEnabled)
        }
        applyIsland8BitStartSoundMigrationIfNeeded(for: resolvedSoundThemeMode)

        isBootstrapping = false
    }
}

@MainActor
enum AppSettings {
    static var shared: AppSettingsStore { AppSettingsStore.shared }
    private static var bundledSoundCache: [String: NSSound] = [:]
    nonisolated static let defaultSettingsWindowSize = CGSize(width: 648, height: 522)
    nonisolated static let minimumSettingsWindowSize = CGSize(width: 648, height: 522)
    nonisolated static let maximumSettingsWindowSize = CGSize(width: 1440, height: 1100)

    static var notificationSound: NotificationSound {
        get { shared.notificationSound }
        set { shared.notificationSound = newValue }
    }

    static var soundEnabled: Bool {
        get { shared.soundEnabled }
        set { shared.soundEnabled = newValue }
    }

    static var soundVolume: Double {
        get { shared.soundVolume }
        set { shared.soundVolume = newValue }
    }

    static var temporarilyMuteNotificationsUntil: Date? {
        get { shared.temporarilyMuteNotificationsUntil }
        set { shared.temporarilyMuteNotificationsUntil = newValue }
    }

    static var areReminderNotificationsSuppressed: Bool {
        shared.areNotificationsMutedTemporarily
    }

    static var soundThemeMode: SoundThemeMode {
        get { shared.soundThemeMode }
        set { shared.soundThemeMode = newValue }
    }

    static var selectedSoundPackPath: String {
        get { shared.selectedSoundPackPath }
        set { shared.selectedSoundPackPath = newValue }
    }

    static var hideInFullscreen: Bool {
        get { shared.hideInFullscreen }
        set { shared.hideInFullscreen = newValue }
    }

    static var autoHideWhenIdle: Bool {
        get { shared.autoHideWhenIdle }
        set { shared.autoHideWhenIdle = newValue }
    }

    static var autoCollapseOnLeave: Bool {
        get { shared.autoCollapseOnLeave }
        set { shared.autoCollapseOnLeave = newValue }
    }

    static var smartSuppression: Bool {
        get { shared.smartSuppression }
        set { shared.smartSuppression = newValue }
    }

    static var autoOpenCompletionPanel: Bool {
        get { shared.autoOpenCompletionPanel }
        set { shared.autoOpenCompletionPanel = newValue }
    }

    static var autoOpenCompactedNotificationPanel: Bool {
        get { shared.autoOpenCompactedNotificationPanel }
        set { shared.autoOpenCompactedNotificationPanel = newValue }
    }

    static func muteReminderNotifications(for duration: TimeInterval, now: Date = Date()) {
        shared.muteNotifications(for: duration, now: now)
    }

    static func clearReminderNotificationMute() {
        shared.temporarilyMuteNotificationsUntil = nil
    }

    nonisolated static func isNotificationMuteActive(until date: Date?, now: Date = Date()) -> Bool {
        AppSettingsStore.isNotificationMuteActive(until: date, now: now)
    }

    static var showAgentDetail: Bool {
        get { shared.showAgentDetail }
        set { shared.showAgentDetail = newValue }
    }

    static var subagentVisibilityMode: SubagentVisibilityMode {
        get { shared.subagentVisibilityMode }
        set { shared.subagentVisibilityMode = newValue }
    }

    static var showUsage: Bool {
        get { shared.showUsage }
        set { shared.showUsage = newValue }
    }

    static var usageValueMode: UsageValueMode {
        get { shared.usageValueMode }
        set { shared.usageValueMode = newValue }
    }

    static var contentFontSize: Double {
        get { shared.contentFontSize }
        set { shared.contentFontSize = newValue }
    }

    static var maxPanelHeight: Double {
        get { shared.maxPanelHeight }
        set { shared.maxPanelHeight = newValue }
    }

    static var notchPetStyle: NotchPetStyle {
        get { shared.notchPetStyle }
        set { shared.notchPetStyle = newValue }
    }

    static var notchDisplayMode: NotchDisplayMode {
        get { shared.notchDisplayMode }
        set { shared.notchDisplayMode = newValue }
    }

    static func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        shared.shortcut(for: action)
    }

    static func setShortcut(_ shortcut: GlobalShortcut?, for action: GlobalShortcutAction) {
        shared.setShortcut(shortcut, for: action)
    }

    static func resetShortcut(_ action: GlobalShortcutAction) {
        shared.resetShortcut(action)
    }

    static func mascotKind(for client: MascotClient) -> MascotKind {
        shared.mascotKind(for: client)
    }

    static func isSoundEnabled(for event: NotificationEvent) -> Bool {
        switch event {
        case .processingStarted:
            return shared.processingStartSoundEnabled
        case .attentionRequired:
            return shared.attentionRequiredSoundEnabled
        case .taskCompleted:
            return shared.taskCompletedSoundEnabled
        case .taskError:
            return shared.taskErrorSoundEnabled
        case .resourceLimit:
            return shared.resourceLimitSoundEnabled
        }
    }

    static func setSoundEnabled(_ enabled: Bool, for event: NotificationEvent) {
        switch event {
        case .processingStarted:
            shared.processingStartSoundEnabled = enabled
        case .attentionRequired:
            shared.attentionRequiredSoundEnabled = enabled
        case .taskCompleted:
            shared.taskCompletedSoundEnabled = enabled
        case .taskError:
            shared.taskErrorSoundEnabled = enabled
        case .resourceLimit:
            shared.resourceLimitSoundEnabled = enabled
        }
    }

    static func sound(for event: NotificationEvent) -> NotificationSound {
        switch event {
        case .processingStarted:
            return shared.processingStartSound
        case .attentionRequired:
            return shared.attentionRequiredSound
        case .taskCompleted:
            return shared.taskCompletedSound
        case .taskError:
            return shared.taskErrorSound
        case .resourceLimit:
            return shared.resourceLimitSound
        }
    }

    static func setSound(_ sound: NotificationSound, for event: NotificationEvent) {
        switch event {
        case .processingStarted:
            shared.processingStartSound = sound
        case .attentionRequired:
            shared.attentionRequiredSound = sound
        case .taskCompleted:
            shared.taskCompletedSound = sound
        case .taskError:
            shared.taskErrorSound = sound
        case .resourceLimit:
            shared.resourceLimitSound = sound
        }
    }

    static func playSound(named soundName: String?) {
        guard soundEnabled, let soundName else { return }
        guard let sound = NSSound(named: NSSound.Name(soundName)) else { return }
        sound.volume = Float(soundVolume)
        sound.play()
    }

    static func playClientStartupSound() {
        guard soundEnabled else { return }
        playBundledSound(named: Island8BitSound.clientStartup.rawValue)
    }

    static func playReleaseNotesSuccessSound() {
        guard soundEnabled else { return }
        playBundledSound(named: Island8BitSound.releaseNotesSuccess.rawValue)
    }

    static func playSound(for event: NotificationEvent) {
        guard soundEnabled, isSoundEnabled(for: event) else { return }
        guard !areReminderNotificationsSuppressed else { return }

        switch soundThemeMode {
        case .builtIn:
            playSound(named: sound(for: event).soundName)
        case .island8Bit:
            playBundledSound(named: event.island8BitSound.rawValue)
        case .soundPack:
            if SoundPackCatalog.shared.play(
                event: event,
                packPath: selectedSoundPackPath,
                volume: Float(soundVolume)
            ) {
                return
            }

            playSound(named: sound(for: event).soundName)
        }
    }

    static func playNotificationSound(_ sound: NotificationSound? = nil) {
        playSound(named: (sound ?? notificationSound).soundName)
    }

    private static func playBundledSound(named resourceName: String) {
        guard let sound = bundledSoundCache[resourceName] ?? loadBundledSound(named: resourceName) else {
            return
        }

        bundledSoundCache[resourceName] = sound
        if sound.isPlaying {
            sound.stop()
        }
        sound.volume = Float(soundVolume)
        sound.play()
    }

    private static func loadBundledSound(named resourceName: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "wav", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: false)
        }

        if let url = Bundle.main.url(forResource: resourceName, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }

        return nil
    }
}
