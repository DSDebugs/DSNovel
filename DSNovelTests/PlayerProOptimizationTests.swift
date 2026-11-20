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

    // MARK: - 2. 验证音质档位 → 两条链的码映射（QualityPolicy）、5 段 AVAudioUnitEQ 构建与 150%–200% 响度增强计算（ISS-03）

    /// `AudioQualityTier` 上原有的「档位 → 单一质量码」方法已随「内置解析改造」整体删除：
    /// 档位不再自己产出「一条」码，而是由 `QualityPolicy` 按**当前链**分别换算（书源链 / 解析器链）。
    func testAudioQualityTierAndEQPipelineConfiguration() {
        // 书源链（喜马书源 common.js 官方 playUrlList 的 type 名）：M4A_24 / M4A_64 / M4A_128
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .bookSource, isOnWiFi: false), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .bookSource, isOnWiFi: true), "M4A_24")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .bookSource, isOnWiFi: true), "M4A_64")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .bookSource, isOnWiFi: false), "M4A_128")
        // 书源链不支持「无损·最高音质」→ 回落 `.high`，因此两个网络类型都得到高清码
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .bookSource, isOnWiFi: true), "M4A_128")
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .bookSource, isOnWiFi: false), "M4A_128")

        // 解析器链（内置解析脚本 v1.2 的语义档位码）
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .auto, chain: .builtinParser, isOnWiFi: false), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .dataSaver, chain: .builtinParser, isOnWiFi: true), "saver")
        XCTAssertEqual(QualityPolicy.code(for: .standard, chain: .builtinParser, isOnWiFi: false), "standard")
        XCTAssertEqual(QualityPolicy.code(for: .high, chain: .builtinParser, isOnWiFi: true), "high")
        XCTAssertEqual(QualityPolicy.code(for: .losslessHQ, chain: .builtinParser, isOnWiFi: false), "lossless")

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

    // MARK: - 2b. 验证「无损 · 最高音质」的展示语义与旧存档值 lossless 的折叠（内置解析改造）

    /// `losslessHQ` 是本次改造新增的第 5 档（仅解析器参与时可见）；
    /// `lossless` 保留为旧存档兼容值，继续折叠到 `.high`（选择/展示/缓冲三处口径一致）。
    func testLosslessHQPresentationAndLegacyLosslessFolding() {
        XCTAssertEqual(AudioQualityTier.losslessHQ.rawValue, "losslessHQ")
        XCTAssertEqual(AudioQualityTier.losslessHQ.title, "无损 · 最高音质")
        XCTAssertEqual(AudioQualityTier.losslessHQ.badgeText, "无损·最高")
        XCTAssertEqual(AudioQualityTier.losslessHQ.effectiveBadgeText(isOnWiFi: true), "无损·最高")
        XCTAssertEqual(AudioQualityTier.losslessHQ.effectiveBadgeText(isOnWiFi: false), "无损·最高")
        XCTAssertEqual(AudioQualityTier.losslessHQ.preferredForwardBufferDuration, 24.0, accuracy: 0.001)
        XCTAssertTrue(AudioQualityTier.losslessHQ.subtitle.contains("权限"),
                      "无损档说明应提示需要账号权限，实际：\(AudioQualityTier.losslessHQ.subtitle)")

        // 旧存档值 lossless：仍折叠为 .high，不出现在可选档位里
        XCTAssertEqual(AudioQualityTier.lossless.normalizedForSelection, .high)
        XCTAssertEqual(AudioQualityTier.lossless.rawValue, "lossless")
        XCTAssertEqual(AudioQualityTier.lossless.title, AudioQualityTier.high.title)
        XCTAssertEqual(AudioQualityTier.lossless.badgeText, AudioQualityTier.high.badgeText)
        XCTAssertEqual(AudioQualityTier.lossless.preferredForwardBufferDuration, 24.0, accuracy: 0.001)
        XCTAssertFalse(AudioQualityTier.visibleTiers.contains(.lossless))
        XCTAssertFalse(AudioQualityTier.visibleTiers.contains(.losslessHQ),
                       "无损档只在解析器参与解析时才可见，不进全局默认档位表")

        // 无损档在两条链上的原生/回落口径
        XCTAssertFalse(QualityPolicy.isNative(.losslessHQ, chain: .bookSource))
        XCTAssertTrue(QualityPolicy.isNative(.losslessHQ, chain: .builtinParser))
        XCTAssertTrue(QualityPolicy.didFallback(.losslessHQ, chain: .bookSource))
        XCTAssertFalse(QualityPolicy.didFallback(.losslessHQ, chain: .builtinParser))
    }

    // MARK: - 3. 验证“本章结束 / N 章后”睡眠定时按当前倍速动态折算预计剩余时间（ISS-12）

    @MainActor
    func testEstimatedSleepRemainingSecForEndOfChapterAndSpeed() {
        let player = PlayerEngine.shared
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/b1", title: "十日终焉")
        let ch1 = ChapterDTO(index: 0, title: "010 结束了？", url: "https://e.com/c1", durationSec: 600)
        let ch2 = ChapterDTO(index: 1, title: "011 新的开始", url: "https://e.com/c2", durationSec: 600)

        player.prepare(book: book, chapters: [ch1, ch2], chapter: ch1, positionMs: 120_000)
        player.setSpeed(2.0, persist: false)
        player.setSleepTimer(.endOfChapter)

        // 章节总长 600s，已播 120s，剩余 480s；在 2.0x 倍速下预计剩余 240s
        XCTAssertEqual(player.estimatedSleepRemainingSec, 240)
        player.setSleepTimer(.off)
        player.setSpeed(1.0, persist: false)
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
        store.modelContext = ctx
        let bookRef = BookRef(sourceID: "xm", bookURL: "https://e.com/fanren", title: "凡人修仙传")

        for i in 0..<10 {
            let expectedInShelf = (i % 2 == 0)
            let actual = store.toggleShelfImmediate(for: bookRef, totalChapters: 2115, context: ctx)
            XCTAssertEqual(actual, expectedInShelf, "第 \(i + 1) 次点击爱心后收藏状态应为 \(expectedInShelf)")
            XCTAssertEqual(store.isBookInShelf(bookRef.id, fallbackContext: ctx), expectedInShelf)
        }
    }

    /// 徽标与实测码率文案：语义不随「内置解析改造」变化（仍是名义档位 + 实测码率归一）
    func testAudioQualityBadgeFormattingAndBitrateDetection() {
        XCTAssertEqual(AudioQualityTier.auto.effectiveBadgeText(isOnWiFi: true), "自适应·128k")
        XCTAssertEqual(AudioQualityTier.auto.effectiveBadgeText(isOnWiFi: false), "自适应·64k")
        XCTAssertEqual(AudioQualityTier.dataSaver.effectiveBadgeText(isOnWiFi: true), "省流·32k")
        XCTAssertEqual(AudioQualityTier.standard.effectiveBadgeText(isOnWiFi: true), "标准·64k")
        XCTAssertEqual(AudioQualityTier.high.effectiveBadgeText(isOnWiFi: true), "高清·128k")
        // 旧值 lossless 与新增 losslessHQ 的徽标口径
        XCTAssertEqual(AudioQualityTier.lossless.effectiveBadgeText(isOnWiFi: true), "高清·128k")
        XCTAssertEqual(AudioQualityTier.losslessHQ.effectiveBadgeText(isOnWiFi: true), "无损·最高")

        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 31), "省流·32k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 63), "标准·64k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 127), "高清·128k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 192), "高清·192k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 320), "无损·320k")
        XCTAssertEqual(AudioQualityTier.badgeText(forDetectedBitrateKbps: 900), "无损·900k")
    }

    /// A-4：PlayerEngine 新增集合属性 `currentChapterParserQualities` 与兼容只读属性 `currentChapterParserDeclaresLossless` 保持一致
    @MainActor
    func testA4PlayerEngineParserQualitiesCompatProperty() {
        let engine = PlayerEngine.shared
        XCTAssertEqual(
            engine.currentChapterParserDeclaresLossless,
            QualityPolicy.parserDeclaresLossless(engine.currentChapterParserQualities)
        )
    }
}
