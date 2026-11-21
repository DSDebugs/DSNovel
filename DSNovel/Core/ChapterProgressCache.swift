import Foundation
import Observation
import SwiftData
import UIKit

struct ChapterProgressSnapshot: Equatable, Hashable, Sendable {
    var bookID: String
    var chapterID: String
    var positionMs: Int
    var durationMs: Int
    var isFinished: Bool
    var updatedAt: Date
}

@MainActor
@Observable
final class ChapterProgressCache {
    static let shared = ChapterProgressCache()

    static let migrationFlagKey = "chapterProgressMigratedV1"
    static let maxPerBook = 2000
    static let maxGlobal = 20000
    static let boundsCheckWriteInterval = 50
    static let boundsBatchLimit = 200
    static let periodicPersistInterval: TimeInterval = 20.0
    static let significantPublishDeltaMs = 30_000

    /// 细粒度变更版本号：仅在章节切换、标记已听、进度跨越显著阈值或强制刷新时递增，隔离播放期间 1Hz 全字典广播
    private(set) var changeVersion: UInt64 = 0

    @ObservationIgnored private var byBook: [String: [String: ChapterProgressSnapshot]] = [:]
    @ObservationIgnored private var lastPersistedAt: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastPublishedPositionByKey: [String: Int] = [:]
    @ObservationIgnored private var lastPublishedChapterIDByBook: [String: String] = [:]
    @ObservationIgnored private var writesSinceBoundsCheck: Int = 0
    @ObservationIgnored private var lastWrittenBookID: String?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserverToken: NSObjectProtocol?
    @ObservationIgnored var modelContext: ModelContext?
    @ObservationIgnored var persistenceActor: PersistenceActor?

    init() {
        backgroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.writesSinceBoundsCheck > 0, let bookID = self.lastWrittenBookID else { return }
                self.writesSinceBoundsCheck = 0
                await self.runBackgroundBoundsCleanup(bookID: bookID)
            }
        }
    }

    deinit {
        if let token = backgroundObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// M-P0-5：切后台清理时通过 `beginBackgroundTask` 申请后台保护窗口，优先交由 `PersistenceActor` 后台分批裁剪，并在结束/超时时释放句柄
    private func runBackgroundBoundsCleanup(bookID: String) async {
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        let finishBackgroundTask: @MainActor () -> Void = {
            if bgTaskID != .invalid {
                let idToEnd = bgTaskID
                bgTaskID = .invalid
                UIApplication.shared.endBackgroundTask(idToEnd)
            }
        }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "DSNovelChapterProgressCleanup") {
            Task { @MainActor in
                finishBackgroundTask()
            }
        }
        defer {
            finishBackgroundTask()
        }

        if let actor = persistenceActor {
            _ = try? await actor.enforceProgressBounds(
                bookID: bookID,
                maxPerBook: Self.maxPerBook,
                maxGlobal: Self.maxGlobal,
                batchLimit: Self.boundsBatchLimit
            )
        } else if let ctx = modelContext {
            enforceBounds(in: ctx, bookID: bookID)
            try? ctx.save()
        }
    }

    func migrateLegacyIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        backupHandler: () -> Void = { _ = try? StoreBackup.backupCurrentStore() }
    ) {
        self.modelContext = context
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return }
        backupHandler()

        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let existingProgress = (try? context.fetch(FetchDescriptor<ChapterProgress>())) ?? []
        var existingIDs = Set(existingProgress.map(\.id))

        for book in books {
            let legacyMap = ChapterProgressStore.loadAll(for: book.id, defaults: defaults)
            for (chapterID, posMs) in legacyMap where posMs > 0 {
                let pid = "\(book.id)::\(chapterID)"
                guard !existingIDs.contains(pid) else { continue }
                let record = ChapterProgress(
                    id: pid,
                    bookID: book.id,
                    chapterID: chapterID,
                    positionMs: posMs,
                    durationMs: 0,
                    isFinished: false,
                    updatedAt: book.lastPlayedAt ?? .now
                )
                context.insert(record)
                existingIDs.insert(pid)
            }
        }
        try? context.save()
        defaults.set(true, forKey: Self.migrationFlagKey)
    }

    func loadBookIfNeeded(_ bookID: String) {
        guard byBook[bookID] == nil, let ctx = modelContext else { return }
        let desc = FetchDescriptor<ChapterProgress>(
            predicate: #Predicate<ChapterProgress> { $0.bookID == bookID }
        )
        let records = (try? ctx.fetch(desc)) ?? []
        var dict: [String: ChapterProgressSnapshot] = [:]
        for r in records {
            dict[r.chapterID] = ChapterProgressSnapshot(
                bookID: r.bookID,
                chapterID: r.chapterID,
                positionMs: r.positionMs,
                durationMs: r.durationMs,
                isFinished: r.isFinished,
                updatedAt: r.updatedAt
            )
        }
        if dict.isEmpty && !UserDefaults.standard.bool(forKey: Self.migrationFlagKey) {
            let legacy = ChapterProgressStore.loadAll(for: bookID)
            for (cid, pos) in legacy {
                dict[cid] = ChapterProgressSnapshot(
                    bookID: bookID,
                    chapterID: cid,
                    positionMs: pos,
                    durationMs: 0,
                    isFinished: false,
                    updatedAt: .now
                )
            }
        }
        byBook[bookID] = dict
    }

    func progress(bookID: String, chapterID: String) -> ChapterProgressSnapshot? {
        _ = changeVersion
        loadBookIfNeeded(bookID)
        return byBook[bookID]?[chapterID]
    }

    func allProgressMap(for bookID: String) -> [String: Int] {
        _ = changeVersion
        loadBookIfNeeded(bookID)
        guard let map = byBook[bookID] else { return [:] }
        var result: [String: Int] = [:]
        for (cid, snap) in map where snap.positionMs > 0 {
            result[cid] = snap.positionMs
        }
        return result
    }

    func allSnapshotsMap(for bookID: String) -> [String: ChapterProgressSnapshot] {
        _ = changeVersion
        loadBookIfNeeded(bookID)
        return byBook[bookID] ?? [:]
    }

    /// 主动发布一次视图刷新信号（用于外部显式刷新）
    func publishRefresh() {
        changeVersion &+= 1
    }

    func setFinished(bookID: String, chapterID: String, isFinished: Bool, durationMs: Int = 0) {
        guard !bookID.isEmpty, !chapterID.isEmpty else { return }
        loadBookIfNeeded(bookID)
        let existing = byBook[bookID]?[chapterID]
        let resolvedDur = max(durationMs, existing?.durationMs ?? 0)
        let resolvedPos = isFinished ? max(resolvedDur, existing?.positionMs ?? 0) : 0
        update(
            bookID: bookID,
            chapterID: chapterID,
            positionMs: resolvedPos,
            durationMs: resolvedDur,
            isFinished: isFinished,
            overrideFinished: true,
            forceFlush: true
        )
    }

    func update(
        bookID: String,
        chapterID: String,
        positionMs: Int,
        durationMs: Int = 0,
        isFinished: Bool = false,
        overrideFinished: Bool = false,
        forceFlush: Bool = false,
        now: Date = .now,
        contextOverride: ModelContext? = nil,
        saveContext: Bool = true
    ) {
        guard !bookID.isEmpty, !chapterID.isEmpty else { return }
        loadBookIfNeeded(bookID)
        let existingSnap = byBook[bookID]?[chapterID]
        let existingFinished = existingSnap?.isFinished ?? false
        // 8-4：写入进度时若传入 durationMs == 0，则保留已有有效总时长，防止覆盖清空
        let incomingDurationMs = max(0, durationMs)
        let resolvedDurationMs = incomingDurationMs > 0
            ? incomingDurationMs
            : max(0, existingSnap?.durationMs ?? 0)
        let resolvedPositionMs = max(0, positionMs)
        let autoFinished = resolvedDurationMs > 0 && resolvedPositionMs >= Int(Double(resolvedDurationMs) * 0.98)
        let finalFinished = overrideFinished
            ? isFinished
            : (isFinished || autoFinished || (existingFinished && resolvedPositionMs >= Int(Double(max(resolvedDurationMs, 1)) * 0.90)))
        let snap = ChapterProgressSnapshot(
            bookID: bookID,
            chapterID: chapterID,
            positionMs: resolvedPositionMs,
            durationMs: resolvedDurationMs,
            isFinished: finalFinished,
            updatedAt: now
        )
        var bookDict = byBook[bookID] ?? [:]
        bookDict[chapterID] = snap
        if bookDict.count > Self.maxPerBook {
            let sorted = bookDict.values.sorted { $0.updatedAt > $1.updatedAt }
            var trimmed: [String: ChapterProgressSnapshot] = [:]
            for item in sorted.prefix(Self.maxPerBook) {
                trimmed[item.chapterID] = item
            }
            bookDict = trimmed
        }
        byBook[bookID] = bookDict

        let key = "\(bookID)::\(chapterID)"
        if shouldPublishChange(
            bookID: bookID,
            chapterID: chapterID,
            key: key,
            positionMs: resolvedPositionMs,
            durationMs: resolvedDurationMs,
            previousFinished: existingFinished,
            finalFinished: finalFinished,
            forceFlush: forceFlush
        ) {
            lastPublishedPositionByKey[key] = resolvedPositionMs
            lastPublishedChapterIDByBook[bookID] = chapterID
            changeVersion &+= 1
        }

        let ts = now.timeIntervalSince1970
        let lastTS = lastPersistedAt[key] ?? 0
        if forceFlush || (ts - lastTS) >= Self.periodicPersistInterval {
            lastPersistedAt[key] = ts
            persistToStore(snap, contextOverride: contextOverride, saveContext: saveContext)
        }
    }

    private func shouldPublishChange(
        bookID: String,
        chapterID: String,
        key: String,
        positionMs: Int,
        durationMs: Int,
        previousFinished: Bool,
        finalFinished: Bool,
        forceFlush: Bool
    ) -> Bool {
        if forceFlush || previousFinished != finalFinished {
            return true
        }
        if lastPublishedChapterIDByBook[bookID] != chapterID {
            return true
        }
        guard let lastPos = lastPublishedPositionByKey[key] else {
            return true
        }
        if abs(positionMs - lastPos) >= Self.significantPublishDeltaMs {
            return true
        }
        if durationMs > 0 {
            let prevBucket = Int((Double(lastPos) / Double(durationMs)) * 20.0)
            let currBucket = Int((Double(positionMs) / Double(durationMs)) * 20.0)
            if prevBucket != currBucket {
                return true
            }
        }
        return false
    }

    private func persistToStore(
        _ snap: ChapterProgressSnapshot,
        contextOverride: ModelContext? = nil,
        saveContext: Bool = true
    ) {
        let targetContext = contextOverride ?? modelContext
        let isMigrated = UserDefaults.standard.bool(forKey: Self.migrationFlagKey)
        // SwiftData 迁移完成后停止双写 UserDefaults，仅在无持久化通道或未完成迁移时回落旧存储
        if (targetContext == nil && persistenceActor == nil) || !isMigrated {
            ChapterProgressStore.save(
                bookID: snap.bookID,
                chapterID: snap.chapterID,
                positionMs: snap.positionMs,
                now: snap.updatedAt.timeIntervalSince1970
            )
        }

        // M-P0-5：高频进度写入优先交由后台 PersistenceActor 异步落盘，避免主线程 SQLite 写入卡顿
        if contextOverride == nil, saveContext, let actor = persistenceActor {
            writesSinceBoundsCheck += 1
            lastWrittenBookID = snap.bookID
            let shouldEnforceBounds = writesSinceBoundsCheck >= Self.boundsCheckWriteInterval
            if shouldEnforceBounds {
                writesSinceBoundsCheck = 0
            }
            let patch = PersistenceActor.ChapterProgressPatch(
                bookID: snap.bookID,
                chapterID: snap.chapterID,
                positionMs: snap.positionMs,
                durationMs: snap.durationMs,
                isFinished: snap.isFinished,
                updatedAt: snap.updatedAt
            )
            let bookID = snap.bookID
            Task(priority: .utility) {
                _ = try? await actor.upsertChapterProgress([patch])
                if shouldEnforceBounds {
                    _ = try? await actor.enforceProgressBounds(
                        bookID: bookID,
                        maxPerBook: Self.maxPerBook,
                        maxGlobal: Self.maxGlobal,
                        batchLimit: Self.boundsBatchLimit
                    )
                }
            }
            return
        }

        guard let ctx = targetContext else { return }
        let pid = "\(snap.bookID)::\(snap.chapterID)"
        let desc = FetchDescriptor<ChapterProgress>(predicate: #Predicate<ChapterProgress> { $0.id == pid })
        if let existing = try? ctx.fetch(desc).first {
            existing.positionMs = snap.positionMs
            // 8-4：durationMs == 0 时保留数据库已有有效总时长
            if snap.durationMs > 0 {
                existing.durationMs = snap.durationMs
            }
            existing.isFinished = snap.isFinished
            existing.updatedAt = snap.updatedAt
        } else {
            ctx.insert(ChapterProgress(
                id: pid,
                bookID: snap.bookID,
                chapterID: snap.chapterID,
                positionMs: snap.positionMs,
                durationMs: snap.durationMs,
                isFinished: snap.isFinished,
                updatedAt: snap.updatedAt
            ))
        }
        writesSinceBoundsCheck += 1
        lastWrittenBookID = snap.bookID
        if writesSinceBoundsCheck >= Self.boundsCheckWriteInterval {
            writesSinceBoundsCheck = 0
            enforceBounds(in: ctx, bookID: snap.bookID)
        }
        if saveContext {
            try? ctx.save()
        }
    }

    func enforceBounds(in ctx: ModelContext, bookID: String) {
        let bookCountDesc = FetchDescriptor<ChapterProgress>(
            predicate: #Predicate<ChapterProgress> { $0.bookID == bookID }
        )
        var bookExcess = max(0, ((try? ctx.fetchCount(bookCountDesc)) ?? 0) - Self.maxPerBook)
        while bookExcess > 0 {
            var bookDesc = FetchDescriptor<ChapterProgress>(
                predicate: #Predicate<ChapterProgress> { $0.bookID == bookID },
                sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .forward)]
            )
            bookDesc.fetchLimit = min(bookExcess, Self.boundsBatchLimit)
            guard let staleBatch = try? ctx.fetch(bookDesc), !staleBatch.isEmpty else { break }
            for stale in staleBatch {
                ctx.delete(stale)
            }
            bookExcess -= staleBatch.count
        }

        var globalExcess = max(0, ((try? ctx.fetchCount(FetchDescriptor<ChapterProgress>())) ?? 0) - Self.maxGlobal)
        while globalExcess > 0 {
            var globalDesc = FetchDescriptor<ChapterProgress>(
                sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .forward)]
            )
            globalDesc.fetchLimit = min(globalExcess, Self.boundsBatchLimit)
            guard let staleBatch = try? ctx.fetch(globalDesc), !staleBatch.isEmpty else { break }
            for stale in staleBatch {
                ctx.delete(stale)
            }
            globalExcess -= staleBatch.count
        }
    }

    func resetMemoryForTesting() {
        byBook.removeAll()
        lastPersistedAt.removeAll()
        lastPublishedPositionByKey.removeAll()
        lastPublishedChapterIDByBook.removeAll()
        writesSinceBoundsCheck = 0
        lastWrittenBookID = nil
        changeVersion = 0
    }
}
