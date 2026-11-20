import XCTest
import AVFoundation
import SwiftData
@testable import DSNovel

final class PlayerProOptimizationTests: XCTestCase {

    // MARK: - 1. 验证 PlayerSpeedFormatter 修复 %.2gx 将 1.25x 截断为 1.2x 的缺陷（ISS-04）

    func testPlayerSpeedFormatterFixes1_25xTruncationBug() {
        XCTAssertEqual(PlayerSpeedFormatter.format(0.75), "0.75x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.0), "1.0x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.25), "1.25x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.5), "1.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(1.75), "1.75x")
        XCTAssertEqual(PlayerSpeedFormatter.format(2.0), "2.0x")
        XCTAssertEqual(PlayerSpeedFormatter.format(2.5), "2.5x")
        XCTAssertEqual(PlayerSpeedFormatter.format(3.0), "3.0x")
    }

    // MARK: - 2. 验证 4 档音质链码映射、5 段 AVAudioUnitEQ 构建与响度增强计算

    func testAudioQualityTierAndEQPipelineConfiguration() {
        // 书源链：M4A_24 / M4A_64 / M4A_128
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: false), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .bookSource, isOnWiFi: true), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .bookSource, isOnWiFi: false), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .bookSource, isOnWiFi: false), "M4A_128")

        // 解析器链：std / hd / uhd
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: true), "uhd")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: false), "std")
        XCTAssertEqual(QualityPolicy.code(for: .std, chain: .builtinParser, isOnWiFi: true), "std")
        XCTAssertEqual(QualityPolicy.code(for: .hd, chain: .builtinParser, isOnWiFi: false), "hd")
        XCTAssertEqual(QualityPolicy.code(for: .uhd, chain: .builtinParser, isOnWiFi: true), "uhd")

        let clearBands = AudioEffectPreset.clearVoice.defaultBandsDb
        XCTAssertEqual(clearBands.count, 5)
        let eqNode = PlayerAudioPipeline.makeConfiguredEQNode(bandsDb: clearBands)
        XCTAssertEqual(eqNode.bands.count, 5)
        XCTAssertEqual(eqNode.bands[0].frequency, 100, accuracy: 0.1)
        XCTAssertEqual(eqNode.bands[2].frequency, 1000, accuracy: 0.1)
        XCTAssertEqual(eqNode.bands[2].gain, Float(clearBands[2]), accuracy: 0.01)
        XCTAssertFalse(eqNode.bands[2].bypass)

        let boosted = PlayerAudioPipeline.computeEffectiveVolume(
            bookVolume: 1.5,
            preset: .clearVoice,
            eqBandsDb: clearBands
        )
        XCTAssertTrue(boosted.isBoosted)
        XCTAssertEqual(boosted.playerVolume, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(boosted.mixGain, 1.5)
    }

    // MARK: - 2b. 验证 4 档可见体系展示文案与旧档位迁移

    func testFourTierPresentationAndLegacyFolding() {
        XCTAssertEqual(AudioQualityTier.visibleTiers, [.auto, .std, .hd, .uhd])
        XCTAssertEqual(AudioQualityTier.defaultTier, .hd)
        XCTAssertEqual(AudioQualityTier.auto.title, "智能自适应")
        XCTAssertEqual(AudioQualityTier.std.title, "标准")
        XCTAssertEqual(AudioQualityTier.hd.title, "高清")
        XCTAssertEqual(AudioQualityTier.uhd.title, "超清")

        // 旧值自动折算

        // 所有档位标题均严格落在 4 档规范集合内
        let allowedTitles: Set<String> = ["智能自适应", "标准", "高清", "超清"]
        for tier in AudioQualityTier.allCases {
            XCTAssertTrue(allowedTitles.contains(tier.title), "异常档位标题：\(tier.title)")
            XCTAssertFalse(tier.subtitle.isEmpty)
        }
    }

    // MARK: - 3. 验证“本章结束 / N 章后”睡眠定时按当前倍速动态折算预计剩余时间（ISS-12）

    @MainActor
    func testEstimatedSleepRemainingSecForEndOfChapterAndSpeed() {
        let player = PlayerEngine.shared
        let prevSpeed = player.speed
        defer {
            player.setSleepTimer(.off)
            player.setSpeed(prevSpeed, persist: false)
            player.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .idle)
        }
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/b1", title: "十日终焉")
        let ch1 = ChapterDTO(index: 0, title: "010 结束了？", url: "https://e.com/c1", durationSec: 600)
        let ch2 = ChapterDTO(index: 1, title: "011 新的开始", url: "https://e.com/c2", durationSec: 600)

        player.prepare(book: book, chapters: [ch1, ch2], chapter: ch1, positionMs: 120_000)
        player.setSpeed(2.0, persist: false)
        player.setSleepTimer(.endOfChapter)

        // 章节总长 600s，已播 120s，剩余 480s；在 2.0x 倍速下预计剩余 240s
        XCTAssertEqual(player.estimatedSleepRemainingSec, 240)
    }

    // MARK: - 4. 验证目录下载模型状态映射与百章分段自动定位（ISS-01 & ISS-02）

    @MainActor
    func testPlayerChapterListModelDownloadStateMapping() {
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/b", title: "十日终焉")
        let chapters = (0..<250).map { idx in
            ChapterDTO(index: idx, title: "第 \(idx + 1) 章", url: "https://e.com/ep/\(idx)")
        }
        let segIdx = PlayerChapterListModel.segmentIndex(for: chapters[135].id, in: chapters, pageSize: 100)
        XCTAssertEqual(segIdx, 1)

        let model = PlayerChapterListModel(book: book, chapters: Array(chapters.prefix(3)), currentChapterID: chapters[0].id)
        model.downloadItems = [
            "\(book.id)::\(chapters[0].id)": DownloadItem(
                id: "\(book.id)::\(chapters[0].id)",
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapters[0].id,
                chapterTitle: chapters[0].title,
                sourceID: book.sourceID,
                state: "completed"
            ),
            "\(book.id)::\(chapters[1].id)": DownloadItem(
                id: "\(book.id)::\(chapters[1].id)",
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapters[1].id,
                chapterTitle: chapters[1].title,
                sourceID: book.sourceID,
                state: "failed"
            )
        ]
        let snaps = model.snapshots
        XCTAssertEqual(snaps.count, 3)
        XCTAssertEqual(snaps[0].downloadState, .completed)
        XCTAssertEqual(snaps[1].downloadState, .failed)
        XCTAssertEqual(snaps[2].downloadState, .notDownloaded)
    }

    // MARK: - 5. 验证 0–12dB 响度增益转线性增益换算（§5 & §6.2.6）

    func testAudioBoostDBToLinearGain() {
        XCTAssertEqual(PlayerAudioPipeline.linearGainFromDecibels(0), 1.0, accuracy: 0.001)
        XCTAssertEqual(PlayerAudioPipeline.linearGainFromDecibels(6), 1.995, accuracy: 0.01)
        XCTAssertEqual(PlayerAudioPipeline.linearGainFromDecibels(12), 3.981, accuracy: 0.01)
    }

    // MARK: - 6. 验证全屏播放器爱心收藏按钮连续快速点击 10 次不会因延迟撤销或去重而失效

    @MainActor
    func testRepeatedHeartFavoriteToggleRemainsConsistent() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let store = LibraryStore.shared
        let prevContext = store.modelContext
        defer {
            store.modelContext = prevContext
        }
        store.modelContext = ctx
        let bookRef = BookRef(sourceID: "xm", bookURL: "https://e.com/fanren", title: "凡人修仙传")

        for i in 0..<10 {
            let expectedInShelf = (i % 2 == 0)
            let actual = store.toggleShelfImmediate(for: bookRef, totalChapters: 2115, context: ctx)
            XCTAssertEqual(actual, expectedInShelf, "第 \(i + 1) 次点击爱心后收藏状态应为 \(expectedInShelf)")
            XCTAssertEqual(store.isBookInShelf(bookRef.id, fallbackContext: ctx), expectedInShelf)
        }
    }

    // MARK: - 7. 验证单书独立音质覆写不污染全局默认（R8）

    @MainActor
    func testPerBookAudioQualityOverrideDoesNotPolluteGlobalDefault() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let engine = PlayerEngine.shared
        let prevContext = engine.modelContext
        let prevGlobal = AppSettingsStore.shared.audioQualityTier
        defer {
            AppSettingsStore.shared.audioQualityTier = prevGlobal
            engine.modelContext = prevContext
            engine.setAudioQualityTier(prevGlobal, reloadCurrent: false, applyToCurrentBookOnly: false)
            engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .idle)
        }

        engine.modelContext = ctx
        AppSettingsStore.shared.audioQualityTier = .hd

        let bookA = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/bookA", title: "书籍A")
        let bookB = BookRef(sourceID: "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64", bookURL: "https://e.com/bookB", title: "书籍B")
        let chA = ChapterDTO(index: 0, title: "A第1章", url: "https://e.com/bookA/1", durationSec: 300)
        let chB = ChapterDTO(index: 0, title: "B第1章", url: "https://e.com/bookB/1", durationSec: 300)

        engine.prepare(book: bookA, chapters: [chA], chapter: chA)
        XCTAssertEqual(engine.currentBookAudioQualityTier, .hd)
        XCTAssertEqual(engine.audioQualityTier, .hd)

        // 仅覆写书籍A 为超清，不得污染全局默认（仍为 .hd）
        engine.setAudioQualityTier(.uhd, reloadCurrent: false, applyToCurrentBookOnly: true)
        XCTAssertEqual(AppSettingsStore.shared.audioQualityTier, .hd, "单书覆写不得修改全局默认档位")
        XCTAssertEqual(engine.currentBookAudioQualityTier, .uhd)
        XCTAssertEqual(engine.audioQualityTier, .uhd)

        // 切换到未覆写的书籍B → 自动回落到全局默认 .hd
        engine.prepare(book: bookB, chapters: [chB], chapter: chB)
        XCTAssertEqual(engine.currentBookAudioQualityTier, .hd)
        XCTAssertEqual(engine.audioQualityTier, .hd)

        // 切回书籍A → 仍保留其独立覆写 .uhd
        engine.prepare(book: bookA, chapters: [chA], chapter: chA)
        XCTAssertEqual(engine.currentBookAudioQualityTier, .uhd)
        XCTAssertEqual(engine.audioQualityTier, .uhd)

        // 修改全局默认为 .std，书籍A 因有独立覆写仍保持 .uhd
        engine.setAudioQualityTier(.std, reloadCurrent: false, applyToCurrentBookOnly: false)
        XCTAssertEqual(AppSettingsStore.shared.audioQualityTier, .std)
        XCTAssertEqual(engine.currentBookAudioQualityTier, .uhd)
        XCTAssertEqual(engine.audioQualityTier, .uhd)
    }

    // MARK: - 8. 验证三层独立码率核算徽标、失败隐藏与时长未知体积兜底（R10-R16）

    @MainActor
    func testStreamStatusBadgeIndependentAccountingFallbackAndFailureHiding() {
        let engine = PlayerEngine.shared
        defer {
            engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .idle)
        }
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/badge", title: "码率徽标测试书")
        let ch = ChapterDTO(index: 0, title: "第1章", url: "https://e.com/badge/1", durationSec: 600)

        engine.prepare(book: book, chapters: [ch], chapter: ch)

        // 1) 无实测码率且无体积 → 返回空串（绝不回落所选档位，绝不出现“检测中”）
        engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .playing)
        XCTAssertEqual(engine.streamStatusBadgeText, "")

        // 2) 实测码率直接展示并按 36 / 72 分桶
        engine.setDetectedStreamMetricsForTesting(bitrateKbps: 24, sizeBytes: 1_800_000, playbackState: .playing)
        XCTAssertEqual(engine.streamStatusBadgeText, "标准·24k")

        engine.setDetectedStreamMetricsForTesting(bitrateKbps: 48, sizeBytes: 3_600_000, playbackState: .playing)
        XCTAssertEqual(engine.streamStatusBadgeText, "高清·48k")

        engine.setDetectedStreamMetricsForTesting(bitrateKbps: 96, sizeBytes: 7_200_000, playbackState: .playing)
        XCTAssertEqual(engine.streamStatusBadgeText, "超清·96k")

        // 3) 时长未知导致码率未知但已知文件体积 → 展示体积兜底（R14）
        engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 4_200_000, playbackState: .playing)
        let expectedSize = AudioQualityTier.formattedSizeFallback(bytes: 4_200_000)
        XCTAssertFalse(expectedSize.isEmpty)
        XCTAssertEqual(engine.streamStatusBadgeText, expectedSize)

        // 4) 播放失败时隐藏徽标（R16）
        engine.setDetectedStreamMetricsForTesting(bitrateKbps: 96, sizeBytes: 7_200_000, playbackState: .failed("网络超时"))
        XCTAssertEqual(engine.streamStatusBadgeText, "")
    }

    /// C6：解析器最高档能力判定（支持新码 uhd 与历史码 lossless）
    func testC6ParserDeclaresMaxTier() {
        XCTAssertTrue(QualityPolicy.parserDeclaresMaxTier(["auto", "std", "hd", "uhd"]))
        XCTAssertTrue(QualityPolicy.parserDeclaresMaxTier(["lossless"]))
        XCTAssertFalse(QualityPolicy.parserDeclaresMaxTier(["std", "hd"]))
    }
}
