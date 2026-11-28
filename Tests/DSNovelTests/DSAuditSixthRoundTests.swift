import DSCore
@testable import DSDownloads
import DSStorage
import Foundation
import Testing
@testable import DSNovel

private actor SixthRoundStubResolver: AudioResolving {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        throw NSError(domain: "Stub", code: -1)
    }

    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool,
        bypassCache: Bool
    ) async throws -> AudioStreamDTO {
        throw NSError(domain: "Stub", code: -1)
    }
}

@Suite("第六轮审计回归测试（下载脏记录退避解锁与搜索分页状态）")
struct DSAuditSixthRoundTests {
    @Test("F-01：下载脏记录重试耗尽 8 次后，单条成功写入或新增脏记录能重置退避计数并唤醒补写")
    @MainActor
    func dirtyPersistenceRetryUnlocksAfterSingleSuccess() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_dirty_unlock_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine.makeOffMain(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let transport = BackgroundTransferTransport(
            baseDirectory: tempRoot,
            sessionIdentifier: "com.dsnovel.app.test.dirtyunlock.\(UUID().uuidString)"
        )
        let coord = DownloadCoordinator(
            persistence: persistence,
            audioResolver: SixthRoundStubResolver(),
            downloadsRoot: tempRoot,
            transport: transport,
            logger: logger
        )
        await coord.bootstrapAndRecover()

        let staleRec = DownloadRecordSnapshot(
            id: "bookA::ch1",
            bookID: "bookA",
            bookTitle: "遗留脏记录",
            coverURL: "",
            sourceID: "s1",
            chapterID: "ch1",
            chapterIndex: 0,
            chapterTitle: "第1章",
            chapterURL: "https://example.com/1.mp3",
            kind: .manual,
            state: .completed,
            qualityTier: .standard
        )
        let freshRec = DownloadRecordSnapshot(
            id: "bookB::ch1",
            bookID: "bookB",
            bookTitle: "新写入成功记录",
            coverURL: "",
            sourceID: "s1",
            chapterID: "ch1",
            chapterIndex: 0,
            chapterTitle: "第1章",
            chapterURL: "https://example.com/2.mp3",
            kind: .manual,
            state: .completed,
            qualityTier: .standard
        )

        // 模拟脏集合中已有残留项且退避计数已达上限 8（原本会永久锁死）
        coord.allRecordsByID[staleRec.id] = staleRec
        coord.dirtyPersistenceIDs.insert(staleRec.id)
        coord.dirtyRetryAttemptCount = 8

        // 当另一条记录写入成功时，应重置退避计数并重新调度剩余脏记录补写
        coord.allRecordsByID[freshRec.id] = freshRec
        await coord.persistRecordWithDirtyRetry(freshRec)
        #expect(coord.dirtyRetryAttemptCount == 0)
        #expect(coord.dirtyRetryTask != nil)

        // 主动 flush 验证残留脏记录顺利落盘并清空脏集合
        await coord.flushDirtyPersistenceIfNeeded()
        #expect(coord.dirtyPersistenceIDs.isEmpty)
        #expect(coord.dirtyRetryAttemptCount == 0)
        let persisted = try await persistence.fetchDownloads(kind: .manual, limit: 20)
        #expect(persisted.contains(where: { $0.id == staleRec.id }))
    }

    @Test("F-03：SearchViewModel 取消分页任务后状态干净归位")
    @MainActor
    func searchPaginationCancelResetsLoadingState() {
        let vm = SearchViewModel()
        vm.isLoadingMore = true
        vm.cancelLoadMoreTask()
        #expect(!vm.isLoadingMore)
        #expect(vm.loadMoreTask == nil)
    }
}
