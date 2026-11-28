import DSCore
import Foundation

/// 单书独立倍速与智能暂停回退偏好扩展（拆分自 AppSettingsStore 保持单文件 ≤ 384 行）
extension AppSettingsStore {
    public static let maxPerBookRateEntries = 200
    public static let supportedSmartRewindThresholds = [5, 10, 30]
    public static let supportedSmartRewindSeconds = [5, 10, 15]

    public func hasBookPlaybackRate(forBookID bookID: String) -> Bool {
        guard !bookID.isEmpty else { return false }
        return bookPlaybackRateMap[bookID] != nil
    }

    public func resolvedPlaybackRate(forBookID bookID: String?) -> Double {
        guard let bookID, !bookID.isEmpty, let custom = bookPlaybackRateMap[bookID] else {
            return playbackRate
        }
        return Self.clampPerBookRate(custom)
    }

    public func setBookPlaybackRate(_ rate: Double?, forBookID bookID: String) {
        guard !bookID.isEmpty else { return }
        var map = bookPlaybackRateMap
        if let rate {
            let clamped = Self.clampPerBookRate(rate)
            map[bookID] = clamped
            if map.count > Self.maxPerBookRateEntries {
                let overflow = map.count - Self.maxPerBookRateEntries
                for key in map.keys.sorted().prefix(overflow) where key != bookID {
                    map.removeValue(forKey: key)
                }
            }
        } else {
            map.removeValue(forKey: bookID)
        }
        bookPlaybackRateMap = map
    }

    public static func clampPerBookRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(3.0, max(0.5, value))
    }

    public static func clampSmartRewindThresholdMinutes(_ value: Int) -> Int {
        min(60, max(1, value))
    }

    public static func clampSmartRewindSeconds(_ value: Int) -> Int {
        min(30, max(3, value))
    }
}
