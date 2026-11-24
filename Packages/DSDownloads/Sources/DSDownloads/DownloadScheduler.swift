import DSCore
import Foundation

/// 双池调度器（L-IOS-2：manual 优先于 precache，使用 Set 槽位集合跟踪并发，彻底杜绝 20+ precache 饿死手动下载）
public struct DownloadScheduler: Sendable {
    public let maxManualConcurrent: Int
    public let maxPrecacheConcurrent: Int

    public private(set) var activeManualIDs: Set<String> = []
    public private(set) var activePrecacheIDs: Set<String> = []

    public init(maxManualConcurrent: Int = 3, maxPrecacheConcurrent: Int = 1) {
        self.maxManualConcurrent = max(1, maxManualConcurrent)
        self.maxPrecacheConcurrent = max(1, maxPrecacheConcurrent)
    }

    public mutating func markStarted(id: String, kind: DownloadKind) {
        switch kind {
        case .manual: activeManualIDs.insert(id)
        case .precache: activePrecacheIDs.insert(id)
        }
    }

    public mutating func markFinished(id: String) {
        activeManualIDs.remove(id)
        activePrecacheIDs.remove(id)
    }

    /// 将已在途任务的活跃槽位从旧池迁移至新池（如 precache 升级为 manual）
    public mutating func migrateKind(id: String, to kind: DownloadKind) {
        let wasActive = activeManualIDs.remove(id) != nil || activePrecacheIDs.remove(id) != nil
        guard wasActive else { return }
        switch kind {
        case .manual: activeManualIDs.insert(id)
        case .precache: activePrecacheIDs.insert(id)
        }
    }

    public var totalActiveCount: Int {
        activeManualIDs.count + activePrecacheIDs.count
    }

    /// 按双池优先级挑选下一批可执行任务（同时遵守退避窗口 retryNotBefore）
    public func pickNextBatch(
        manualCandidates: [DownloadRecordSnapshot],
        precacheCandidates: [DownloadRecordSnapshot],
        now: Date = Date()
    ) -> [DownloadRecordSnapshot] {
        var picked: [DownloadRecordSnapshot] = []

        let manualSlots = max(0, maxManualConcurrent - activeManualIDs.count)
        if manualSlots > 0 {
            for item in manualCandidates {
                guard picked.count < manualSlots else { break }
                guard item.kind == .manual,
                      item.state == .queued,
                      !activeManualIDs.contains(item.id),
                      Self.isEligible(item, now: now) else { continue }
                picked.append(item)
            }
        }

        let precacheSlots = max(0, maxPrecacheConcurrent - activePrecacheIDs.count)
        if precacheSlots > 0 {
            var precachePicked = 0
            for item in precacheCandidates {
                guard precachePicked < precacheSlots else { break }
                guard item.kind == .precache,
                      item.state == .queued,
                      !activePrecacheIDs.contains(item.id),
                      Self.isEligible(item, now: now) else { continue }
                picked.append(item)
                precachePicked += 1
            }
        }

        return picked
    }

    public static func isEligible(_ item: DownloadRecordSnapshot, now: Date) -> Bool {
        if let notBefore = item.retryNotBefore, notBefore > now {
            return false
        }
        return true
    }
}
