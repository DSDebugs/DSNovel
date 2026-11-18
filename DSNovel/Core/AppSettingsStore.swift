import SwiftUI

enum AudioChannelMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case music = "music"
    case spokenAudio = "spokenAudio"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "音乐"
        case .spokenAudio: return "人声"
        }
    }
    var subtitle: String {
        switch self {
        case .music: return "使用标准音频通道（.default），保留完整动态范围与背景配乐细节"
        case .spokenAudio: return "使用人声增强通道（.spokenAudio），优化语音清晰度并支持导航避让"
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum DiscoverLayoutStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case grid = "grid"
    case list = "list"
    case largeCard = "largeCard"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        case .largeCard: return "大图"
        }
    }
}

enum ShelfSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case lastPlayed = "lastPlayed"
    case addedAt = "addedAt"
    case title = "title"
    case recentlyUpdated = "recentlyUpdated"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastPlayed: return "最近播放"
        case .addedAt: return "加入时间"
        case .title: return "书名"
        case .recentlyUpdated: return "最近更新"
        }
    }
}

/// T3-05 启动时的行为三选一
enum LaunchBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
    case restorePaused = "restorePaused"
    case autoPlay = "autoPlay"
    case doNothing = "doNothing"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .restorePaused: return "恢复到上次位置并暂停"
        case .autoPlay: return "自动续播"
        case .doNothing: return "什么都不做"
        }
    }

    static func migrate(fromLegacyAutoResume autoResume: Bool?) -> LaunchBehavior {
        guard let autoResume else { return .restorePaused }
        return autoResume ? .autoPlay : .restorePaused
    }
}

@MainActor
@Observable
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    static let allResettablePropertyNames: [String] = [
        "audioChannel",
        "defaultSpeed",
        "sleepFadeOutEnabled",
        "autoResumeOnLaunch",
        "launchBehavior",
        "precacheCount",
        "rememberBookVolume",
        "defaultSkipIntroSec",
        "defaultSkipOutroSec",
        "discoverLayout",
        "shelfLayout",
        "shelfSort",
        "appearanceMode",
        "hapticsEnabled",
        "wifiOnlyDownload",
        "currentDiscoverSourceID",
        "nightDimEnabled",
        "reduceMotionOverride"
    ]

    private let defaults: UserDefaults

    var audioChannel: AudioChannelMode {
        didSet { defaults.set(audioChannel.rawValue, forKey: "audioChannel") }
    }
    var defaultSpeed: Double {
        didSet { defaults.set(defaultSpeed, forKey: "defaultSpeed") }
    }
    var sleepFadeOutEnabled: Bool {
        didSet { defaults.set(sleepFadeOutEnabled, forKey: "sleepFadeOutEnabled") }
    }
    var autoResumeOnLaunch: Bool {
        didSet {
            defaults.set(autoResumeOnLaunch, forKey: "autoResumeOnLaunch")
            if autoResumeOnLaunch && launchBehavior != .autoPlay {
                launchBehavior = .autoPlay
            } else if !autoResumeOnLaunch && launchBehavior == .autoPlay {
                launchBehavior = .restorePaused
            }
        }
    }
    var launchBehavior: LaunchBehavior {
        didSet {
            defaults.set(launchBehavior.rawValue, forKey: "launchBehavior")
            let shouldAuto = (launchBehavior == .autoPlay)
            if autoResumeOnLaunch != shouldAuto {
                autoResumeOnLaunch = shouldAuto
            }
        }
    }
    var precacheCount: Int {
        didSet { defaults.set(precacheCount, forKey: "precacheCount") }
    }
    var rememberBookVolume: Bool {
        didSet { defaults.set(rememberBookVolume, forKey: "rememberBookVolume") }
    }
    var defaultSkipIntroSec: Int {
        didSet { defaults.set(defaultSkipIntroSec, forKey: "defaultSkipIntroSec") }
    }
    var defaultSkipOutroSec: Int {
        didSet { defaults.set(defaultSkipOutroSec, forKey: "defaultSkipOutroSec") }
    }
    var discoverLayout: DiscoverLayoutStyle {
        didSet { defaults.set(discoverLayout.rawValue, forKey: "discoverLayout") }
    }
    var shelfLayout: DiscoverLayoutStyle {
        didSet { defaults.set(shelfLayout.rawValue, forKey: "shelfLayout") }
    }
    var shelfSort: ShelfSortOrder {
        didSet { defaults.set(shelfSort.rawValue, forKey: "shelfSort") }
    }
    var appearanceMode: AppAppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }
    var wifiOnlyDownload: Bool {
        didSet { defaults.set(wifiOnlyDownload, forKey: "wifiOnlyDownload") }
    }
    var currentDiscoverSourceID: String {
        didSet { defaults.set(currentDiscoverSourceID, forKey: "currentDiscoverSourceID") }
    }
    /// T6-02 夜间降亮
    var nightDimEnabled: Bool {
        didSet { defaults.set(nightDimEnabled, forKey: "nightDimEnabled") }
    }
    /// T6-02 应用内减弱动画覆盖（false=跟随系统，true=始终减弱）
    var reduceMotionOverride: Bool {
        didSet { defaults.set(reduceMotionOverride, forKey: "reduceMotionOverride") }
    }

    /// §3.2 音质档位与听书音效持久化
    var audioQualityTier: AudioQualityTier {
        didSet { defaults.set(audioQualityTier.rawValue, forKey: "audioQualityTier") }
    }
    var audioEffectPreset: AudioEffectPreset {
        didSet { defaults.set(audioEffectPreset.rawValue, forKey: "audioEffectPreset") }
    }
    var customEQBandsDb: [Double] {
        didSet { defaults.set(customEQBandsDb, forKey: "customEQBandsDb") }
    }
    var audioBoostDB: Double {
        didSet { defaults.set(audioBoostDB, forKey: "audioBoostDB") }
    }
    var audioBalance: Double {
        didSet { defaults.set(audioBalance, forKey: "audioBalance") }
    }
    var onlyPlayDownloadedInOffline: Bool {
        didSet { defaults.set(onlyPlayDownloadedInOffline, forKey: "onlyPlayDownloadedInOffline") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.audioChannel = AudioChannelMode(rawValue: defaults.string(forKey: "audioChannel") ?? "") ?? .spokenAudio
        let spd = defaults.double(forKey: "defaultSpeed")
        self.defaultSpeed = spd > 0 ? spd : 1.0
        self.sleepFadeOutEnabled = defaults.object(forKey: "sleepFadeOutEnabled") as? Bool ?? true
        let legacyAutoResume = defaults.object(forKey: "autoResumeOnLaunch") as? Bool
        self.autoResumeOnLaunch = legacyAutoResume ?? false
        if let savedBehavior = defaults.string(forKey: "launchBehavior"),
           let parsed = LaunchBehavior(rawValue: savedBehavior) {
            self.launchBehavior = parsed
        } else {
            let migrated = LaunchBehavior.migrate(fromLegacyAutoResume: legacyAutoResume)
            self.launchBehavior = migrated
            defaults.set(migrated.rawValue, forKey: "launchBehavior")
        }
        self.precacheCount = defaults.object(forKey: "precacheCount") as? Int ?? 2
        self.rememberBookVolume = defaults.object(forKey: "rememberBookVolume") as? Bool ?? true
        self.defaultSkipIntroSec = defaults.integer(forKey: "defaultSkipIntroSec")
        self.defaultSkipOutroSec = defaults.integer(forKey: "defaultSkipOutroSec")
        self.discoverLayout = DiscoverLayoutStyle(rawValue: defaults.string(forKey: "discoverLayout") ?? "") ?? .grid
        self.shelfLayout = DiscoverLayoutStyle(rawValue: defaults.string(forKey: "shelfLayout") ?? "") ?? .grid
        self.shelfSort = ShelfSortOrder(rawValue: defaults.string(forKey: "shelfSort") ?? "") ?? .lastPlayed
        self.appearanceMode = AppAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        self.hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        self.wifiOnlyDownload = defaults.object(forKey: "wifiOnlyDownload") as? Bool ?? true
        self.currentDiscoverSourceID = defaults.string(forKey: "currentDiscoverSourceID") ?? ""
        self.nightDimEnabled = defaults.object(forKey: "nightDimEnabled") as? Bool ?? false
        self.reduceMotionOverride = defaults.object(forKey: "reduceMotionOverride") as? Bool ?? false

        self.audioQualityTier = AudioQualityTier(rawValue: defaults.string(forKey: "audioQualityTier") ?? "") ?? .high
        self.audioEffectPreset = AudioEffectPreset(rawValue: defaults.string(forKey: "audioEffectPreset") ?? "") ?? .original
        if let savedBands = defaults.array(forKey: "customEQBandsDb") as? [Double], savedBands.count == 5 {
            self.customEQBandsDb = savedBands
        } else {
            self.customEQBandsDb = [0.0, 0.0, 0.0, 0.0, 0.0]
        }
        self.audioBoostDB = defaults.object(forKey: "audioBoostDB") as? Double ?? 0.0
        self.audioBalance = defaults.object(forKey: "audioBalance") as? Double ?? 0.0
        self.onlyPlayDownloadedInOffline = defaults.object(forKey: "onlyPlayDownloadedInOffline") as? Bool ?? false
    }

    func resetAll() {
        audioChannel = .spokenAudio
        defaultSpeed = 1.0
        sleepFadeOutEnabled = true
        autoResumeOnLaunch = false
        launchBehavior = .restorePaused
        precacheCount = 2
        rememberBookVolume = true
        defaultSkipIntroSec = 0
        defaultSkipOutroSec = 0
        discoverLayout = .grid
        shelfLayout = .grid
        shelfSort = .lastPlayed
        appearanceMode = .system
        hapticsEnabled = true
        wifiOnlyDownload = true
        currentDiscoverSourceID = ""
        nightDimEnabled = false
        reduceMotionOverride = false
        audioQualityTier = .high
        audioEffectPreset = .original
        customEQBandsDb = [0.0, 0.0, 0.0, 0.0, 0.0]
        audioBoostDB = 0.0
        audioBalance = 0.0
        onlyPlayDownloadedInOffline = false
    }
}
