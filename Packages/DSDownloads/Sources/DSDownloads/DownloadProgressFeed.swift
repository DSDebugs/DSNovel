import DSCore
import Foundation
import Observation

/// 独立下载进度通道（AUD-53：按 taskID 持有独立 @Observable ItemProgress 节点，彻底隔离行级重绘）
@Observable
@MainActor
public final class DownloadProgressFeed {
    @Observable
    @MainActor
    public final class ItemProgress {
        public fileprivate(set) var progress: Double = 0
        public fileprivate(set) var speedBytesPerSec: Int64 = 0

        public init(progress: Double = 0, speedBytesPerSec: Int64 = 0) {
            self.progress = progress
            self.speedBytesPerSec = speedBytesPerSec
        }
    }

    @ObservationIgnored
    private var itemsByID: [String: ItemProgress] = [:]

    public var progressByID: [String: Double] {
        itemsByID.mapValues(\.progress)
    }

    public var speedBytesPerSecByID: [String: Int64] {
        itemsByID.mapValues(\.speedBytesPerSec)
    }

    public init() {}

    public func item(for id: String) -> ItemProgress {
        if let existing = itemsByID[id] {
            return existing
        }
        let created = ItemProgress()
        itemsByID[id] = created
        return created
    }

    public func update(id: String, downloaded: Int64, total: Int64, speed: Int64 = 0) {
        let node = item(for: id)
        if total > 0 {
            node.progress = min(1, max(0, Double(downloaded) / Double(total)))
        }
        if speed >= 0 {
            node.speedBytesPerSec = speed
        }
    }

    public func clearSpeed(for id: String) {
        itemsByID[id]?.speedBytesPerSec = 0
    }

    public func remove(id: String) {
        if let existing = itemsByID.removeValue(forKey: id) {
            existing.progress = 0
            existing.speedBytesPerSec = 0
        }
    }

    public func progress(for id: String) -> Double {
        item(for: id).progress
    }

    public func speedBytesPerSec(for id: String) -> Int64 {
        item(for: id).speedBytesPerSec
    }
}
