//
//  Settings.swift
//  PingIsland
//
//  App settings manager using UserDefaults
//

import AppKit
import Combine
import Foundation

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

    private let defaults = UserDefaults.standard
    private var isBootstrapping = true

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let soundEnabled = "soundEnabled"
        static let soundVolume = "soundVolume"
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
        static let selectedSoundPackPath = "selectedSoundPackPath"
        static let hideInFullscreen = "hideInFullscreen"
        static let autoHideWhenIdle = "autoHideWhenIdle"
        static let autoCollapseOnLeave = "autoCollapseOnLeave"
        static let smartSuppression = "smartSuppression"
        static let showAgentDetail = "showAgentDetail"
        static let showUsage = "showUsage"
        static let usageValueMode = "usageValueMode"
        static let contentFontSize = "contentFontSize"
        static let maxPanelHeight = "maxPanelHeight"
        static let notchPetStyle = "notchPetStyle"
        static let notchDisplayMode = "notchDisplayMode"
    }

    // MARK: - Published Settings

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

    @Published var showAgentDetail: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showAgentDetail, forKey: Keys.showAgentDetail)
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

    private init() {
        let legacyNotificationSound = NotificationSound(
            rawValue: defaults.string(forKey: Keys.notificationSound) ?? ""
        ) ?? .blow
        let usageValueModeRaw = defaults.string(forKey: Keys.usageValueMode)
        let soundThemeModeRaw = defaults.string(forKey: Keys.soundThemeMode)
        let notchPetStyleRaw = defaults.string(forKey: Keys.notchPetStyle)
        let notchDisplayModeRaw = defaults.string(forKey: Keys.notchDisplayMode)

        _notificationSound = Published(initialValue: legacyNotificationSound)
        _soundEnabled = Published(initialValue: defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true)
        _soundVolume = Published(initialValue: defaults.object(forKey: Keys.soundVolume) as? Double ?? 0.9)
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
        _processingStartSoundEnabled = Published(initialValue: defaults.object(forKey: Keys.processingStartSoundEnabled) as? Bool ?? false)
        _attentionRequiredSoundEnabled = Published(initialValue: defaults.object(forKey: Keys.attentionRequiredSoundEnabled) as? Bool ?? true)
        _taskCompletedSoundEnabled = Published(initialValue: defaults.object(forKey: Keys.taskCompletedSoundEnabled) as? Bool ?? true)
        _taskErrorSoundEnabled = Published(initialValue: defaults.object(forKey: Keys.taskErrorSoundEnabled) as? Bool ?? true)
        _resourceLimitSoundEnabled = Published(initialValue: defaults.object(forKey: Keys.resourceLimitSoundEnabled) as? Bool ?? true)
        _soundThemeMode = Published(initialValue: SoundThemeMode(
            rawValue: soundThemeModeRaw ?? ""
        ) ?? .builtIn)
        _selectedSoundPackPath = Published(initialValue: defaults.string(forKey: Keys.selectedSoundPackPath) ?? "")
        _hideInFullscreen = Published(initialValue: defaults.object(forKey: Keys.hideInFullscreen) as? Bool ?? true)
        _autoHideWhenIdle = Published(initialValue: defaults.object(forKey: Keys.autoHideWhenIdle) as? Bool ?? false)
        _autoCollapseOnLeave = Published(initialValue: defaults.object(forKey: Keys.autoCollapseOnLeave) as? Bool ?? true)
        _smartSuppression = Published(initialValue: defaults.object(forKey: Keys.smartSuppression) as? Bool ?? true)
        _showAgentDetail = Published(initialValue: defaults.object(forKey: Keys.showAgentDetail) as? Bool ?? true)
        _showUsage = Published(initialValue: defaults.object(forKey: Keys.showUsage) as? Bool ?? false)
        _usageValueMode = Published(initialValue: UsageValueMode(rawValue: usageValueModeRaw ?? "") ?? .used)
        _contentFontSize = Published(initialValue: defaults.object(forKey: Keys.contentFontSize) as? Double ?? 13)
        _maxPanelHeight = Published(initialValue: defaults.object(forKey: Keys.maxPanelHeight) as? Double ?? 580)
        _notchPetStyle = Published(initialValue: NotchPetStyle(rawValue: notchPetStyleRaw ?? "") ?? .cat)
        _notchDisplayMode = Published(initialValue: NotchDisplayMode(rawValue: notchDisplayModeRaw ?? "") ?? .compact)

        isBootstrapping = false
    }
}

@MainActor
enum AppSettings {
    static var shared: AppSettingsStore { AppSettingsStore.shared }

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

    static var showAgentDetail: Bool {
        get { shared.showAgentDetail }
        set { shared.showAgentDetail = newValue }
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

    static func playSound(for event: NotificationEvent) {
        guard soundEnabled, isSoundEnabled(for: event) else { return }

        if soundThemeMode == .soundPack,
           SoundPackCatalog.shared.play(
               event: event,
               packPath: selectedSoundPackPath,
               volume: Float(soundVolume)
           ) {
            return
        }

        playSound(named: sound(for: event).soundName)
    }

    static func playNotificationSound(_ sound: NotificationSound? = nil) {
        playSound(named: (sound ?? notificationSound).soundName)
    }
}
