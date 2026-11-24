import DSCore
import Foundation
import Observation

/// 外观模式
public enum AppThemeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 书架展示模式
public enum ShelfLayoutMode: String, Codable, Sendable, CaseIterable {
    case grid
    case list
}

/// 全局应用设置存储（规则 #17：零全局跳过片头片尾；L-IOS-7：支持注入独立 UserDefaults 零测试串扰）
@Observable
@MainActor
public final class AppSettingsStore {
    private let defaults: UserDefaults

    public var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }
    public var nightDimEnabled: Bool {
        didSet { defaults.set(nightDimEnabled, forKey: Keys.nightDimEnabled) }
    }
    public var shelfLayout: ShelfLayoutMode {
        didSet { defaults.set(shelfLayout.rawValue, forKey: Keys.shelfLayout) }
    }
    public var preferredQuality: AudioQualityTier {
        didSet { defaults.set(preferredQuality.rawValue, forKey: Keys.preferredQuality) }
    }
    public var playbackRate: Double {
        didSet {
            let clamped = Self.clampPlaybackRate(playbackRate)
            if playbackRate != clamped {
                playbackRate = clamped
                return
            }
            defaults.set(playbackRate, forKey: Keys.playbackRate)
        }
    }
    public var wifiOnlyDownload: Bool {
        didSet { defaults.set(wifiOnlyDownload, forKey: Keys.wifiOnlyDownload) }
    }
    public var maxConcurrentDownloads: Int {
        didSet {
            let clamped = Self.clampMaxConcurrentDownloads(maxConcurrentDownloads)
            if maxConcurrentDownloads != clamped {
                maxConcurrentDownloads = clamped
                return
            }
            defaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads)
        }
    }
    public var precacheNextCount: Int {
        didSet {
            let clamped = Self.clampPrecacheNextCount(precacheNextCount)
            if precacheNextCount != clamped {
                precacheNextCount = clamped
                return
            }
            defaults.set(precacheNextCount, forKey: Keys.precacheNextCount)
        }
    }
    public var autoPlayNextChapter: Bool {
        didSet { defaults.set(autoPlayNextChapter, forKey: Keys.autoPlayNextChapter) }
    }
    public var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }
    public var bundledSourcesSeededVersion: String {
        didSet { defaults.set(bundledSourcesSeededVersion, forKey: Keys.bundledSeededVersion) }
    }
    public var builtinParserUnlocked: Bool {
        didSet { defaults.set(builtinParserUnlocked, forKey: Keys.builtinParserUnlocked) }
    }
    public var lastDiscoverSourceID: String {
        didSet { defaults.set(lastDiscoverSourceID, forKey: Keys.lastDiscoverSourceID) }
    }
    private var bookQualityMap: [String: String] {
        didSet { defaults.set(bookQualityMap, forKey: Keys.bookQualityMap) }
    }

    /// 读取单本书记忆音质（未单独调整时默认自适应 .auto）
    public func quality(forBookID bookID: String) -> AudioQualityTier {
        guard !bookID.isEmpty, let raw = bookQualityMap[bookID] else { return .auto }
        return AudioQualityTier.fromParserToken(raw) ?? .auto
    }

    /// 保存单本书音质（切回 .auto 时清理条目保持存储精简）
    public func setQuality(_ tier: AudioQualityTier, forBookID bookID: String) {
        guard !bookID.isEmpty else { return }
        if tier == .auto {
            bookQualityMap.removeValue(forKey: bookID)
        } else {
            bookQualityMap[bookID] = tier.rawValue
        }
    }

    public func clearBookQualities() {
        bookQualityMap.removeAll()
    }

    public var customSourceGroups: [String] {
        didSet { defaults.set(customSourceGroups, forKey: Keys.customSourceGroups) }
    }

    public func addCustomSourceGroup(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "默认分组", !customSourceGroups.contains(clean) else { return }
        customSourceGroups.append(clean)
    }

    public func renameCustomSourceGroup(from oldName: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "默认分组", oldName != clean else { return }
        if let idx = customSourceGroups.firstIndex(of: oldName) {
            customSourceGroups.remove(at: idx)
            if !customSourceGroups.contains(clean) {
                customSourceGroups.insert(clean, at: idx)
            }
        } else if !customSourceGroups.contains(clean) {
            customSourceGroups.append(clean)
        }
    }

    public func removeCustomSourceGroup(_ name: String) {
        customSourceGroups.removeAll { $0 == name }
    }

    private enum Keys {
        static let themeMode = "dsnovel.v3.themeMode"
        static let nightDimEnabled = "dsnovel.v3.nightDimEnabled"
        static let shelfLayout = "dsnovel.v3.shelfLayout"
        static let preferredQuality = "dsnovel.v3.preferredQuality"
        static let playbackRate = "dsnovel.v3.playbackRate"
        static let wifiOnlyDownload = "dsnovel.v3.wifiOnlyDownload"
        static let maxConcurrentDownloads = "dsnovel.v3.maxConcurrentDownloads"
        static let precacheNextCount = "dsnovel.v3.precacheNextCount"
        static let autoPlayNextChapter = "dsnovel.v3.autoPlayNextChapter"
        static let onboardingCompleted = "dsnovel.v3.onboardingCompleted"
        static let bundledSeededVersion = "dsnovel.v3.bundledSeededVersion"
        static let builtinParserUnlocked = "dsnovel.v3.builtinParserUnlocked"
        static let lastDiscoverSourceID = "dsnovel.v3.lastDiscoverSourceID"
        static let bookQualityMap = "dsnovel.v3.bookQualityMap"
        static let customSourceGroups = "dsnovel.v3.customSourceGroups"
    }

    private static func clampPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(3.0, max(0.5, value))
    }

    private static func clampMaxConcurrentDownloads(_ value: Int) -> Int {
        min(6, max(1, value))
    }

    private static func clampPrecacheNextCount(_ value: Int) -> Int {
        min(5, max(0, value))
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "") ?? .system
        self.nightDimEnabled = defaults.bool(forKey: Keys.nightDimEnabled)
        self.shelfLayout = ShelfLayoutMode(rawValue: defaults.string(forKey: Keys.shelfLayout) ?? "") ?? .grid
        self.preferredQuality = AudioQualityTier.fromParserToken(defaults.string(forKey: Keys.preferredQuality) ?? "") ?? .auto
        if let savedRate = defaults.object(forKey: Keys.playbackRate) as? Double {
            self.playbackRate = Self.clampPlaybackRate(savedRate)
        } else {
            self.playbackRate = 1.0
        }
        self.wifiOnlyDownload = defaults.object(forKey: Keys.wifiOnlyDownload) as? Bool ?? true
        if let savedConc = defaults.object(forKey: Keys.maxConcurrentDownloads) as? Int {
            self.maxConcurrentDownloads = Self.clampMaxConcurrentDownloads(savedConc)
        } else {
            self.maxConcurrentDownloads = 3
        }
        if let savedPrecache = defaults.object(forKey: Keys.precacheNextCount) as? Int {
            self.precacheNextCount = Self.clampPrecacheNextCount(savedPrecache)
        } else {
            self.precacheNextCount = 2
        }
        self.autoPlayNextChapter = defaults.object(forKey: Keys.autoPlayNextChapter) as? Bool ?? true
        self.onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        self.bundledSourcesSeededVersion = defaults.string(forKey: Keys.bundledSeededVersion) ?? ""
        self.builtinParserUnlocked = defaults.bool(forKey: Keys.builtinParserUnlocked)
        self.lastDiscoverSourceID = defaults.string(forKey: Keys.lastDiscoverSourceID) ?? ""
        self.bookQualityMap = (defaults.dictionary(forKey: Keys.bookQualityMap) as? [String: String]) ?? [:]
        self.customSourceGroups = (defaults.stringArray(forKey: Keys.customSourceGroups)) ?? []
    }
}
