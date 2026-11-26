@testable import DSNovel
@testable import DSPlayback
import DSCore
import DSPluginKit
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
    func storeBackupRestoreFromCorruptedPrimary() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSBackupAudit7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bootstrap = try StorageContainerFactory.makePersistent(baseDirectory: dir)
        let storeURL = bootstrap.storeURL
        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 3)
        let backup = try await manager.createBackup()

        // 破坏主库内容模拟损坏
        try Data("CORRUPTED_PRIMARY_DB".utf8).write(to: storeURL)
        try await manager.restoreBackup(backup)

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

    @Test("CookieVault 沙盒降级文件持久化、1&_token 规范化与淘汰保护")
    func cookieVaultFallbackPersistenceAndTokenProtection() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSCookieVaultAudit7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vaultFile = dir.appendingPathComponent("cookies.vault")

        let mobileToken = try #require(HTTPCookie(properties: [
            .name: "1&_token",
            .value: "uid&token_abc",
            .domain: "m.ximalaya.com",
            .path: "/",
            .secure: "TRUE"
        ]))
        let vault1 = CookieVault(inMemorySecretsOnly: true, fallbackFileURL: vaultFile)
        await vault1.mergeMissingCookies([mobileToken])

        // 模拟冷启动重新初始化：从沙盒降级文件恢复并命中 www.ximalaya.com
        let vault2 = CookieVault(inMemorySecretsOnly: true, fallbackFileURL: vaultFile)
        let wwwURL = try #require(URL(string: "https://www.ximalaya.com/"))
        let header = await vault2.cookieHeader(for: wwwURL)
        #expect(header.contains("1&_token=uid&token_abc"))
    }

    @Test("BuiltinParserEngine.checkStatus 凭据有效但探测章仅试听时保持 healthy，凭据全失效才标 degraded")
    func checkStatusPreservesHealthyOnSingleTrackTrialRestriction() async throws {
        let preludeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/prelude_parser.js")
        let prelude = try String(contentsOf: preludeURL, encoding: .utf8)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSCheckStatusAudit7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: dir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )

        let trialProbeScript = """
        (function () {
          registerBuiltinParser({
            id: 'mock-trial-probe',
            name: '模拟解析器',
            version: '1.5.6',
            targets: { hosts: ['ximalaya.com'], sourceIDs: [] },
            qualities: ['hd'],
            capabilities: { playback: true, download: true, needsCookie: true },
            checkStatus: function () {
              return {
                ok: false,
                probeReason: 'trial_only',
                message: '探测章节解析失败：trial_only（该章节仅提供试听，需要会员或购买）',
                localCredential: { valid: true },
                sharedCredential: { valid: true }
              };
            },
            resolveAudio: function () { return null; }
          });
        }());
        """
        _ = try await engine.installParser(scriptBody: trialProbeScript)
        let trialStatus = try await engine.checkStatus(id: "mock-trial-probe")
        #expect(!trialStatus.ok)
        #expect(trialStatus.message.contains("凭据与解析器正常"))
        let healthyMeta = await engine.listParsers().first(where: { $0.id == "mock-trial-probe" })
        #expect(healthyMeta?.healthStatus == .healthy)

        let noCredScript = """
        (function () {
          registerBuiltinParser({
            id: 'mock-no-cred',
            name: '模拟无凭据',
            version: '1.5.6',
            targets: { hosts: ['ximalaya.com'], sourceIDs: [] },
            qualities: ['hd'],
            capabilities: { playback: true, download: true, needsCookie: true },
            checkStatus: function () {
              return {
                ok: false,
                message: '未取到可用 Cookie',
                localCredential: { valid: false },
                sharedCredential: { valid: false }
              };
            },
            resolveAudio: function () { return null; }
          });
        }());
        """
        _ = try await engine.installParser(scriptBody: noCredScript)
        let failStatus = try await engine.checkStatus(id: "mock-no-cred")
        #expect(!failStatus.ok)
        let degradedMeta = await engine.listParsers().first(where: { $0.id == "mock-no-cred" })
        #expect(degradedMeta?.healthStatus == .degraded)
    }

    @Test("ChapterRowSnapshot 紧凑体积格式化与已下载副标题无冗余拼接")
    func chapterRowSnapshotCompactBytesAndSubtitle() {
        #expect(ChapterRowSnapshot.formatCompactBytes(0) == "")
        #expect(ChapterRowSnapshot.formatCompactBytes(512 * 1024) == "0.5MB")
        #expect(ChapterRowSnapshot.formatCompactBytes(50 * 1024) == "50KB")
        #expect(ChapterRowSnapshot.formatCompactBytes(7_444_889) == "7.1MB")
        #expect(ChapterRowSnapshot.formatCompactBytes(1_288_490_188) == "1.20GB")

        let ch = ChapterDTO(id: "c1", title: "第1章", url: "xm:1", index: 0, durationMs: 437_000, isVIP: true)
        let snap = ChapterRowSnapshot(
            arrayIndex: 0,
            chapter: ch,
            displayIndex: 1,
            isCurrentPlayingChapter: true,
            isEnginePlaying: true,
            savedPositionMs: 10_000,
            durationMs: 437_000,
            isFinished: false,
            isVIP: true,
            downloadState: .completed,
            downloadedBytes: 7_444_889,
            downloadedQualityTier: .ultraHigh,
            downloadStatusNote: nil,
            displayTitle: "第1章",
            downloadRecordID: "rec-1"
        )
        let sub = snap.subtitleText
        #expect(sub.contains("7.1MB"))
        #expect(!sub.contains("已下载"))
        #expect(!sub.contains(" MB"))
    }

    @Test("BundledParserLoader.installIfNeeded 与低版本升级保留策略")
    func bundledParserUpgradePreservesNewerVersion() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let prelude = try String(contentsOf: root.appendingPathComponent("App/Resources/prelude_parser.js"), encoding: .utf8)
        let bundled = try String(contentsOf: root.appendingPathComponent("App/Resources/BundledParsers/ximalaya_parser-v1.5.6.js"), encoding: .utf8)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSBundledUpgradeAudit7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vault = CookieVault(inMemorySecretsOnly: true)
        let engine = BuiltinParserEngine(
            preludeParserScript: prelude,
            storageDir: dir,
            httpClient: HostHTTPClient(cookieVault: vault),
            cookieVault: vault,
            logger: DSDiagnosticLogStore()
        )

        // 未安装时静默升级应返回 nil，不主动激活
        let skipped = await BundledParserLoader.upgradeBundledXimalayaParserIfInstalledAndOlder(engine: engine)
        #expect(skipped == nil)

        // 安装旧版 1.5.5 后，升级到 1.5.6
        let older = bundled.replacingOccurrences(of: "version: '1.5.6',", with: "version: '1.5.5',")
        _ = try await engine.installParser(scriptBody: older)
        let outcome = try await BundledParserLoader.installIfNeeded(engine: engine, scriptBody: bundled)
        #expect(outcome == .upgraded(name: "喜马拉雅解析", fromVersion: "1.5.5", toVersion: "1.5.6"))
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
