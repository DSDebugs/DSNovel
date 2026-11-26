@testable import DSNovel
@testable import DSPlayback
import DSCore
import DSStorage
import Foundation
import Testing

/// 第七轮外部审计建议定向白盒边界单测（DownloadState 7×7 状态矩阵 + SleepTimer 边界 + 损坏库归档恢复 + 后台省电降频）
@Suite("Seventh Round Audit Whitebox Tests")
struct DSAuditSeventhRoundTests {
    @Test("DownloadState.canTransition 7×7 状态流转矩阵穷举校验")
    func downloadStateTransitionMatrix() {
        let allowed: [DownloadState: Set<DownloadState>] = [
            .queued: [.queued, .resolving, .completed, .paused, .failed, .cancelled],
            .resolving: [.resolving, .downloading, .paused, .failed, .cancelled, .queued],
            .downloading: [.downloading, .completed, .paused, .failed, .cancelled, .queued],
            .paused: [.paused, .queued, .resolving, .cancelled],
            .failed: [.failed, .queued, .cancelled],
            .completed: [],
            .cancelled: [.cancelled, .queued]
        ]

        for from in DownloadState.allCases {
            for to in DownloadState.allCases {
                let expected = allowed[from]?.contains(to) ?? false
                #expect(
                    from.canTransition(to: to) == expected,
                    "Unexpected transition \(from.rawValue) -> \(to.rawValue)"
                )
            }
        }
        #expect(DownloadState.completed.isTerminal)
        #expect(!DownloadState.failed.isTerminal)
        #expect(!DownloadState.cancelled.isTerminal)
    }

    @Test("SleepTimerEngine 0 分钟倒计时抬升至 60 秒且持久化读取越界值自动 clamp")
    @MainActor
    func sleepTimerZeroMinutesAndPersistenceClamp() throws {
        let engine = SleepTimerEngine(tickIntervalNanoseconds: 1_000_000_000)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        engine.startCountdown(minutes: 0, now: now, onFadeFactor: { _ in }, onFire: {})
        #expect(engine.remainingSeconds == 60)
        #expect(engine.estimatedEndDate == now.addingTimeInterval(60))
        engine.cancel()

        let suiteName = "dsnovel.test.sleep.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(999, forKey: "dsnovel.v3.sleep.fadeOutSec")
        defaults.set(999, forKey: "dsnovel.v3.sleep.autoRewindSec")
        defaults.set(999, forKey: "dsnovel.v3.sleep.lastCustomMin")

        engine.bindPersistence(defaults)
        #expect(engine.fadeOutLastSeconds == 120)
        #expect(engine.autoRewindOnSleepSeconds == 60)
        #expect(engine.lastCustomMinutes == 180)
    }

    @Test("StoreBackupManager 主库损坏时归档并成功从健康备份恢复")
    func storeBackupRestoreFromCorruptedPrimary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSBackupAudit7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bootstrap = try StorageContainerFactory.makePersistent(baseDirectory: dir)
        let storeURL = bootstrap.storeURL
        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 3)
        let backup = try manager.createBackup()

        // 破坏主库内容模拟损坏
        try Data("CORRUPTED_PRIMARY_DB".utf8).write(to: storeURL)
        try manager.restoreBackup(backup)

        let corruptedDir = storeURL.deletingLastPathComponent().appendingPathComponent(".corrupted", isDirectory: true)
        let archived = (try? FileManager.default.contentsOfDirectory(atPath: corruptedDir.path)) ?? []
        #expect(!archived.isEmpty)
        let restoredHeader = try Data(contentsOf: storeURL).prefix(16)
        #expect(String(data: restoredHeader, encoding: .utf8) == "SQLite format 3\0")
    }

    @Test("PlaybackCoordinator 后台省电模式正确切换落盘节流与时间观察器周期")
    @MainActor
    func playbackBackgroundPowerSavingMode() {
        let coordinator = PlaybackCoordinator(
            audioResolver: Audit7StubAudioResolver(),
            progressStore: Audit7StubProgressStore(),
            logger: DSDiagnosticLogStore()
        )
        defer { coordinator.tearDown() }

        #expect(coordinator.progressPersistIntervalSeconds == 4.0)
        #expect(coordinator.preferredTimeObserverInterval(current: 10, duration: 300) == 0.5)

        coordinator.setBackgroundPowerSaving(true)
        #expect(coordinator.progressPersistIntervalSeconds == 20.0)
        #expect(coordinator.preferredTimeObserverInterval(current: 10, duration: 300) == 2.0)

        coordinator.setBackgroundPowerSaving(false)
        #expect(coordinator.progressPersistIntervalSeconds == 4.0)
        #expect(coordinator.preferredTimeObserverInterval(current: 10, duration: 300) == 0.5)
    }
}

private struct Audit7StubAudioResolver: AudioResolving {
    func resolveAudio(
        sourceID: String,
        bookID: String,
        chapter: ChapterDTO,
        preferredQuality: AudioQualityTier,
        forDownload: Bool
    ) async throws -> AudioStreamDTO {
        AudioStreamDTO(url: URL(string: "https://example.com/audio.mp3")!, qualityTier: preferredQuality)
    }
}

private actor Audit7StubProgressStore: PlaybackProgressPersisting {
    func saveProgress(
        book: BookSummaryDTO,
        chapter: ChapterDTO,
        positionMs: Int,
        durationMs: Int,
        isFinished: Bool,
        overrideFinished: Bool
    ) async {}

    func loadChapterProgress(bookID: String, chapterID: String) async -> (positionMs: Int, durationMs: Int, isFinished: Bool)? {
        nil
    }

    func loadBookSkipConfig(bookID: String) async -> SkipConfigDTO {
        SkipConfigDTO()
    }

    func saveBookSkipConfig(bookID: String, config: SkipConfigDTO) async {}
}
