import SwiftUI

enum AudioChannelMode: String, CaseIterable, Identifiable {
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

enum AppAppearanceMode: String, CaseIterable, Identifiable {
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

enum DiscoverLayoutStyle: String, CaseIterable, Identifiable {
    case grid = "grid"
    case list = "list"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        }
    }
}

enum ShelfSortOrder: String, CaseIterable, Identifiable {
    case lastPlayed = "lastPlayed"
    case addedAt = "addedAt"
    case title = "title"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastPlayed: return "最近播放"
        case .addedAt: return "加入时间"
        case .title: return "书名"
        }
    }
}

@MainActor
@Observable
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    var audioChannel: AudioChannelMode {
        didSet { UserDefaults.standard.set(audioChannel.rawValue, forKey: "audioChannel") }
    }
    var defaultSpeed: Double {
        didSet { UserDefaults.standard.set(defaultSpeed, forKey: "defaultSpeed") }
    }
    var sleepFadeOutEnabled: Bool {
        didSet { UserDefaults.standard.set(sleepFadeOutEnabled, forKey: "sleepFadeOutEnabled") }
    }
    var autoResumeOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoResumeOnLaunch, forKey: "autoResumeOnLaunch") }
    }
    var precacheCount: Int {
        didSet { UserDefaults.standard.set(precacheCount, forKey: "precacheCount") }
    }
    var rememberBookVolume: Bool {
        didSet { UserDefaults.standard.set(rememberBookVolume, forKey: "rememberBookVolume") }
    }
    var defaultSkipIntroSec: Int {
        didSet { UserDefaults.standard.set(defaultSkipIntroSec, forKey: "defaultSkipIntroSec") }
    }
    var defaultSkipOutroSec: Int {
        didSet { UserDefaults.standard.set(defaultSkipOutroSec, forKey: "defaultSkipOutroSec") }
    }
    var discoverLayout: DiscoverLayoutStyle {
        didSet { UserDefaults.standard.set(discoverLayout.rawValue, forKey: "discoverLayout") }
    }
    var shelfLayout: DiscoverLayoutStyle {
        didSet { UserDefaults.standard.set(shelfLayout.rawValue, forKey: "shelfLayout") }
    }
    var shelfSort: ShelfSortOrder {
        didSet { UserDefaults.standard.set(shelfSort.rawValue, forKey: "shelfSort") }
    }
    var appearanceMode: AppAppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }
    var wifiOnlyDownload: Bool {
        didSet { UserDefaults.standard.set(wifiOnlyDownload, forKey: "wifiOnlyDownload") }
    }
    var currentDiscoverSourceID: String {
        didSet { UserDefaults.standard.set(currentDiscoverSourceID, forKey: "currentDiscoverSourceID") }
    }

    init() {
        let d = UserDefaults.standard
        self.audioChannel = AudioChannelMode(rawValue: d.string(forKey: "audioChannel") ?? "") ?? .spokenAudio
        let spd = d.double(forKey: "defaultSpeed")
        self.defaultSpeed = spd > 0 ? spd : 1.0
        self.sleepFadeOutEnabled = d.object(forKey: "sleepFadeOutEnabled") as? Bool ?? true
        self.autoResumeOnLaunch = d.object(forKey: "autoResumeOnLaunch") as? Bool ?? false
        self.precacheCount = d.object(forKey: "precacheCount") as? Int ?? 2
        self.rememberBookVolume = d.object(forKey: "rememberBookVolume") as? Bool ?? true
        self.defaultSkipIntroSec = d.integer(forKey: "defaultSkipIntroSec")
        self.defaultSkipOutroSec = d.integer(forKey: "defaultSkipOutroSec")
        self.discoverLayout = DiscoverLayoutStyle(rawValue: d.string(forKey: "discoverLayout") ?? "") ?? .grid
        self.shelfLayout = DiscoverLayoutStyle(rawValue: d.string(forKey: "shelfLayout") ?? "") ?? .grid
        self.shelfSort = ShelfSortOrder(rawValue: d.string(forKey: "shelfSort") ?? "") ?? .lastPlayed
        self.appearanceMode = AppAppearanceMode(rawValue: d.string(forKey: "appearanceMode") ?? "") ?? .system
        self.hapticsEnabled = d.object(forKey: "hapticsEnabled") as? Bool ?? true
        self.wifiOnlyDownload = d.object(forKey: "wifiOnlyDownload") as? Bool ?? true
        self.currentDiscoverSourceID = d.string(forKey: "currentDiscoverSourceID") ?? ""
    }

    func resetAll() {
        audioChannel = .spokenAudio
        defaultSpeed = 1.0
        sleepFadeOutEnabled = true
        autoResumeOnLaunch = false
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
    }
}
