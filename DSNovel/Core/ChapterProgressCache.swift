import Foundation
import Observation
import SwiftData

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

    private var byBook: [String: [String: ChapterProgressSnapshot]] = [:]
    private var lastPersistedAt: [String: TimeInterval] = [:]
    var modelContext: ModelContext?

    init() {}

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
        if dict.isEmpty {
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
        loadBookIfNeeded(bookID)
        return byBook[bookID]?[chapterID]
    }

    func allProgressMap(for bookID: String) -> [String: Int] {
        loadBookIfNeeded(bookID)
        guard let map = byBook[bookID] else { return [:] }
        var result: [String: Int] = [:]
        for (cid, snap) in map where snap.positionMs > 0 {
            result[cid] = snap.positionMs
        }
        return result
    }

    func allSnapshotsMap(for bookID: String) -> [String: ChapterProgressSnapshot] {
        loadBookIfNeeded(bookID)
        return byBook[bookID] ?? [:]
    }

    func setFinished(bookID: String, chapterID: String, isFinished: Bool, durationMs: Int = 0) {
        guard !bookID.isEmpty, !chapterID.isEmpty else { return }
        loadBookIfNeeded(bookID)
        let existing = byBook[bookID]?[chapterID]
        let resolvedDur = max(durationMs, existing?.durationMs ?? 0)
        let resolvedPos = isFinished ? max(resolvedDur, existing?.positionMs ?? 0) : (existing?.positionMs ?? 0)
        update(
            bookID: bookID,
            chapterID: chapterID,
            positionMs: resolvedPos,
            durationMs: resolvedDur,
            isFinished: isFinished,
            forceFlush: true
        )
    }

    func update(
        bookID: String,
        chapterID: String,
        positionMs: Int,
        durationMs: Int = 0,
        isFinished: Bool = false,
        forceFlush: Bool = false,
        now: Date = .now
    ) {
        guard !bookID.isEmpty, !chapterID.isEmpty else { return }
        loadBookIfNeeded(bookID)
        let existingFinished = byBook[bookID]?[chapterID]?.isFinished ?? false
        let resolvedDurationMs = max(0, durationMs)
        let resolvedPositionMs = max(0, positionMs)
        let autoFinished = resolvedDurationMs > 0 && resolvedPositionMs >= Int(Double(resolvedDurationMs) * 0.98)
        let finalFinished = isFinished || autoFinished || (existingFinished && resolvedPositionMs >= Int(Double(max(resolvedDurationMs, 1)) * 0.90))
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
        let ts = now.timeIntervalSince1970
        let lastTS = lastPersistedAt[key] ?? 0
        if forceFlush || (ts - lastTS) >= 5.0 {
            lastPersistedAt[key] = ts
            persistToStore(snap)
        }
    }

    private func persistToStore(_ snap: ChapterProgressSnapshot) {
        ChapterProgressStore.save(
            bookID: snap.bookID,
            chapterID: snap.chapterID,
            positionMs: snap.positionMs,
            now: snap.updatedAt.timeIntervalSince1970
        )
        guard let ctx = modelContext else { return }
        let pid = "\(snap.bookID)::\(snap.chapterID)"
        let desc = FetchDescriptor<ChapterProgress>(predicate: #Predicate<ChapterProgress> { $0.id == pid })
        if let existing = try? ctx.fetch(desc).first {
            existing.positionMs = snap.positionMs
            existing.durationMs = snap.durationMs
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
        enforceBounds(in: ctx, bookID: snap.bookID)
        try? ctx.save()
    }

    func enforceBounds(in ctx: ModelContext, bookID: String) {
        let bookDesc = FetchDescriptor<ChapterProgress>(
            predicate: #Predicate<ChapterProgress> { $0.bookID == bookID },
            sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .reverse)]
        )
        if let bookItems = try? ctx.fetch(bookDesc), bookItems.count > Self.maxPerBook {
            for stale in bookItems.dropFirst(Self.maxPerBook) {
                ctx.delete(stale)
            }
        }
        let globalDesc = FetchDescriptor<ChapterProgress>(
            sortBy: [SortDescriptor(\ChapterProgress.updatedAt, order: .reverse)]
        )
        if let allItems = try? ctx.fetch(globalDesc), allItems.count > Self.maxGlobal {
            for stale in allItems.dropFirst(Self.maxGlobal) {
                ctx.delete(stale)
            }
        }
    }

    func resetMemoryForTesting() {
        byBook.removeAll()
        lastPersistedAt.removeAll()
    }
}
