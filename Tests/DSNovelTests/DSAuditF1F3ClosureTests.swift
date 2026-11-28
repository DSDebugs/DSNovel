import DSCore
@testable import DSDownloads
import DSStorage
import Foundation
import Testing

private actor StubAuditAudioResolver: AudioResolving {
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

@Suite("F1 孤儿隔离、F2 安全快照还原与 F3 真实防覆盖回归测试")
struct DSAuditF1F3ClosureTests {
    @Test("F1：StorageReconciler 将超 10 分钟孤儿音频移入 .orphan_quarantine 隔离而非立即销毁，满 3 天后清理")
    func reconcilerQuarantinesOrphansBeforePermanentDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_quarantine_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookDir = root.appendingPathComponent("bookA", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let orphanFile = bookDir.appendingPathComponent("chap1.mp3")
        try Data(repeating: 0x55, count: 1024).write(to: orphanFile)
        let past = Date().addingTimeInterval(-900)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: orphanFile.path)

        let reconciler = StorageReconciler(downloadsRoot: root, minIntervalSeconds: 1)
        let report = await reconciler.reconcileIfNeeded(completedRecords: [], force: true)
        #expect(report?.orphanFilesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: orphanFile.path))

        let quarantineDir = root.appendingPathComponent(".orphan_quarantine", isDirectory: true)
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)) ?? []
        #expect(quarantined.count == 1)

        if let firstName = quarantined.first {
            let qFile = quarantineDir.appendingPathComponent(firstName)
            let fourDaysAgo = Date().addingTimeInterval(-4 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: fourDaysAgo], ofItemAtPath: qFile.path)
            _ = await reconciler.reconcileIfNeeded(completedRecords: [], force: true)
            let afterExpired = (try? FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)) ?? []
            #expect(afterExpired.isEmpty)
        }
    }

    @Test("F1/N4：reconcileDisk 会先补写脏记录并保护其音频不被隔离")
    @MainActor
    func reconcileDiskProtectsDirtyRecordBeforeRetryFlush() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_dirty_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine.makeOffMain(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let transport = BackgroundTransferTransport(
            baseDirectory: tempRoot,
            sessionIdentifier: "com.dsnovel.app.test.dirty.\(UUID().uuidString)"
        )
        let coord = DownloadCoordinator(
            persistence: persistence,
            audioResolver: StubAuditAudioResolver(),
            downloadsRoot: tempRoot,
            transport: transport,
            logger: logger
        )
        await coord.bootstrapAndRecover()

        let relPath = DownloadRecordSnapshot.canonicalRelativePath(bookID: "bookDirty", chapterID: "ch1", ext: "mp3")
        let audioURL = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 2048).write(to: audioURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-900)], ofItemAtPath: audioURL.path)

        let rec = DownloadRecordSnapshot(
            id: "bookDirty::ch1", bookID: "bookDirty", bookTitle: "脏记录测试书", coverURL: "",
            sourceID: "src", chapterID: "ch1", chapterIndex: 0, chapterTitle: "第一章",
            chapterURL: "https://example.com/1", kind: .manual, state: .completed,
            qualityTier: .standard, localRelPath: relPath, totalBytes: 2048, downloadedBytes: 2048
        )
        coord.allRecordsByID[rec.id] = rec
        coord.dirtyPersistenceIDs.insert(rec.id)

        await coord.reconcileDisk(force: true)

        #expect(coord.dirtyPersistenceIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test("F3/N2：DownloadCoordinator.handleFailure 与 markFailedWithoutRetry 绝不将 paused/cancelled 改写为 queued 或 failed")
    @MainActor
    func coordinatorFailureHandlersProtectPausedAndCancelledTasks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_f3_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let container = try StorageContainerFactory.makeInMemory()
        let persistence = PersistenceEngine.makeOffMain(modelContainer: container)
        let logger = DSDiagnosticLogStore()
        let transport = BackgroundTransferTransport(
            baseDirectory: tempRoot,
            sessionIdentifier: "com.dsnovel.app.test.f3.\(UUID().uuidString)"
        )
        let coord = DownloadCoordinator(
            persistence: persistence,
            audioResolver: StubAuditAudioResolver(),
            downloadsRoot: tempRoot,
            transport: transport,
            logger: logger
        )

        let pausedRec = DownloadRecordSnapshot(
            id: "book::ch1", bookID: "book", bookTitle: "测试书", coverURL: "",
            sourceID: "src", chapterID: "ch1", chapterIndex: 0, chapterTitle: "第一章",
            chapterURL: "https://example.com/1", kind: .manual, state: .paused, qualityTier: .standard
        )
        let cancelledRec = DownloadRecordSnapshot(
            id: "book::ch2", bookID: "book", bookTitle: "测试书", coverURL: "",
            sourceID: "src", chapterID: "ch2", chapterIndex: 1, chapterTitle: "第二章",
            chapterURL: "https://example.com/2", kind: .manual, state: .cancelled, qualityTier: .standard
        )
        coord.allRecordsByID[pausedRec.id] = pausedRec
        coord.allRecordsByID[cancelledRec.id] = cancelledRec

        // 模拟晚到的网络失败（可重试状态码 503 与不可重试 404）
        await coord.handleFailure(taskID: pausedRec.id, httpStatus: 503, message: "late 503")
        await coord.handleFailure(taskID: cancelledRec.id, httpStatus: 503, message: "late 503")
        await coord.markFailedWithoutRetry(taskID: pausedRec.id, message: "late fatal")
        await coord.markFailedWithoutRetry(taskID: cancelledRec.id, message: "late fatal")

        #expect(coord.allRecordsByID[pausedRec.id]?.state == .paused)
        #expect(coord.allRecordsByID[cancelledRec.id]?.state == .cancelled)
    }

    @Test("F2：StoreBackupManager.restoreBackup 还原前生成安全快照并清理 .bak 伴生文件")
    func restoreBackupCreatesSafetySnapshotAndCleansSidecars() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_f2_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let boot = try StorageContainerFactory.makePersistent(baseDirectory: dir)
            _ = boot.container
        }
        let storeURL = dir.appendingPathComponent("DSNovelV3.store")
        let manager = StoreBackupManager(storeURL: storeURL)

        let initialBackup = try await manager.createBackup()
        let beforeList = await manager.listBackups()
        #expect(beforeList.count == 1)

        try await manager.restoreBackup(initialBackup)
        let afterList = await manager.listBackups()
        #expect(afterList.count == 2)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path + "-wal.bak"))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path + "-shm.bak"))
    }

    @Test("F2：StoreBackupManager.restoreBackup 备份目录不可写导致安全快照失败时中止还原")
    func restoreBackupAbortsWhenSafetySnapshotFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_f2_abort_\(UUID().uuidString)", isDirectory: true)
        let backupsDir = dir.appendingPathComponent("Backups", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let boot = try StorageContainerFactory.makePersistent(baseDirectory: dir)
            _ = boot.container
        }
        let storeURL = dir.appendingPathComponent("DSNovelV3.store")
        let manager = StoreBackupManager(storeURL: storeURL)
        let initialBackup = try await manager.createBackup()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backupsDir.path)
        var didThrow = false
        do {
            try await manager.restoreBackup(initialBackup)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
