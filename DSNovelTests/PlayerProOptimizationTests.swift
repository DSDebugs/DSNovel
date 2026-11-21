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

    // MARK: - 9. P2：无堆分配 DF2T 双二阶滤波连续性、超长帧分块与实时参数切换回归测试

    func testAudioTapDSPDF2TContinuityAcrossBlocksAndLiveUpdate() {
        let sampleRate = 44100.0
        let dsp = AudioTapDSPContext(
            bandsDb: [0.0, 0.0, 6.0, 0.0, 0.0], // 1kHz +6dB
            balance: 0.0,
            mixGain: 1.0
        )
        // 故意设置较小 maxFrames=64，随后喂入 256 帧超长块，验证分块处理无崩溃且无状态断层
        dsp.prepareForTesting(sampleRate: sampleRate, channels: 1, maxFrames: 64, isNonInterleaved: true)

        func makeSine(startIndex: Int, count: Int, freq: Double = 1000.0, amp: Float = 0.25) -> [Float] {
            (0..<count).map { i in
                let t = Double(startIndex + i) / sampleRate
                return amp * Float(sin(2.0 * Double.pi * freq * t))
            }
        }

        func runBlock(_ samples: inout [Float]) {
            let count = samples.count
            samples.withUnsafeMutableBufferPointer { bufPtr in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                        mData: bufPtr.baseAddress
                    )
                )
                withUnsafeMutablePointer(to: &abl) { ablPtr in
                    dsp.processBufferListForTesting(frameCount: count, bufferList: ablPtr)
                }
            }
        }

        var block1 = makeSine(startIndex: 0, count: 256)
        let inputPeak = block1.map { abs($0) }.max() ?? 0
        runBlock(&block1)

        // 1) 输出有限且受软限幅约束，且 1kHz +6dB 显著高于原振幅
        XCTAssertTrue(block1.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        let steadyPeak1 = block1.suffix(128).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(steadyPeak1, inputPeak * 1.4, "1kHz +6dB 峰值应明显放大")

        // 2) 控制线程实时平滑切换系数（不重置延迟状态），检查块边界连续无剧烈跳变
        dsp.update(bandsDb: [0.0, 0.0, 4.5, 1.5, 0.0], balance: 0.0, mixGain: 1.0)
        var block2 = makeSine(startIndex: 256, count: 128)
        runBlock(&block2)

        XCTAssertTrue(block2.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        let boundaryJump = abs((block2.first ?? 0) - (block1.last ?? 0))
        XCTAssertLessThan(boundaryJump, 0.35, "块边界与系数切换后滤波状态应连续，无清零爆音跳变")
    }

    // MARK: - 10. P12：音频偏好单一数据源（AppSettingsStore.shared SSOT）双向同步测试

    @MainActor
    func testAudioPreferencesSSOTSyncWithAppSettingsStore() {
        let settings = AppSettingsStore.shared
        let engine = PlayerEngine.shared

        let prevTier = settings.audioQualityTier
        let prevPreset = settings.audioEffectPreset
        let prevBands = settings.customEQBandsDb
        let prevBoost = settings.audioBoostDB
        let prevBalance = settings.audioBalance
        defer {
            settings.audioQualityTier = prevTier
            settings.audioEffectPreset = prevPreset
            settings.customEQBandsDb = prevBands
            settings.audioBoostDB = prevBoost
            settings.audioBalance = prevBalance
            engine.syncGlobalAudioPreferencesFromSettings()
        }

        // 1) 直接修改 AppSettingsStore.shared → PlayerEngine 立即反映，无需额外镜像拷贝
        settings.audioEffectPreset = .clearVoice
        settings.customEQBandsDb = [2.0, -1.0, 3.0, 4.0, -2.0]
        settings.audioBoostDB = 4.5
        settings.audioBalance = -0.35

        XCTAssertEqual(engine.audioEffectPreset, .clearVoice)
        XCTAssertEqual(engine.customEQBandsDb, [2.0, -1.0, 3.0, 4.0, -2.0])
        XCTAssertEqual(engine.audioBoostDB, 4.5, accuracy: 0.001)
        XCTAssertEqual(engine.audioBalance, -0.35, accuracy: 0.001)

        // 2) 通过 PlayerEngine 接口写入 → 直接落入 AppSettingsStore.shared 并自动边界裁剪
        engine.setAudioEffectPreset(.nightSoft)
        XCTAssertEqual(settings.audioEffectPreset, .nightSoft)

        engine.updateCustomEQBand(index: 2, gainDb: 18.0) // 超上限应裁到 12.0 并切至 .custom
        XCTAssertEqual(settings.audioEffectPreset, .custom)
        XCTAssertEqual(settings.customEQBandsDb[2], 12.0, accuracy: 0.001)
        XCTAssertEqual(engine.customEQBandsDb[2], 12.0, accuracy: 0.001)

        engine.audioBoostDB = 20.0 // 裁至 12.0
        engine.audioBalance = 2.5  // 裁至 1.0
        XCTAssertEqual(settings.audioBoostDB, 12.0, accuracy: 0.001)
        XCTAssertEqual(settings.audioBalance, 1.0, accuracy: 0.001)

        engine.resetEQToOriginal()
        XCTAssertEqual(settings.audioEffectPreset, .original)
        XCTAssertEqual(settings.customEQBandsDb, [0.0, 0.0, 0.0, 0.0, 0.0])
        XCTAssertEqual(settings.audioBoostDB, 0.0, accuracy: 0.001)
    }

    // MARK: - 11. P11：PlaybackQueueIndex O(1) 下标查询与边界导航测试

    func testPlaybackQueueIndexO1LookupAndNavigation() {
        let chapters = (0..<2000).map { idx in
            ChapterDTO(index: idx, title: "第 \(idx + 1) 章", url: "https://e.com/q/\(idx)")
        }
        var queue = PlaybackQueueIndex(chapters: chapters)

        XCTAssertEqual(queue.count, 2000)
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.index(of: chapters[0].id), 0)
        XCTAssertEqual(queue.index(of: chapters[1234].id), 1234)
        XCTAssertEqual(queue.index(of: chapters[1999].id), 1999)
        XCTAssertNil(queue.index(of: "nonexistent"))

        XCTAssertEqual(queue.oneBasedIndex(of: chapters[0].id), 1)
        XCTAssertEqual(queue.oneBasedIndex(of: chapters[1999].id), 2000)
        XCTAssertEqual(queue.oneBasedIndex(of: nil), 0)

        XCTAssertNil(queue.previousChapter(before: chapters[0].id))
        XCTAssertEqual(queue.previousChapter(before: chapters[500].id)?.id, chapters[499].id)
        XCTAssertEqual(queue.nextChapter(after: chapters[500].id)?.id, chapters[501].id)
        XCTAssertNil(queue.nextChapter(after: chapters[1999].id))

        let upcoming = queue.upcomingChapters(after: chapters[1997].id, limit: 5)
        XCTAssertEqual(upcoming.map(\.id), [chapters[1998].id, chapters[1999].id])

        queue.replace(with: Array(chapters.prefix(3)))
        XCTAssertEqual(queue.count, 3)
        XCTAssertNil(queue.index(of: chapters[500].id))
        XCTAssertEqual(queue.index(of: chapters[2].id), 2)
    }

    // MARK: - 12. P4：ChapterProgressCache 播放期 1Hz 内存更新不触发全字典广播

    @MainActor
    func testChapterProgressCacheThrottlesObservableBroadcastDuring1HzUpdates() {
        let cache = ChapterProgressCache()
        cache.resetMemoryForTesting()

        let bookID = "test_book_p4"
        let ch1 = "ch_1"
        let ch2 = "ch_2"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 首次写入新章节触发 1 次发布
        cache.update(bookID: bookID, chapterID: ch1, positionMs: 1_000, durationMs: 1_000_000, forceFlush: false, now: baseDate)
        let versionAfterFirst = cache.changeVersion
        XCTAssertEqual(versionAfterFirst, 1)

        // 后续连续 10 秒 1Hz 更新（未跨 30s 阈值、未跨 5% 分桶、未切换章节）不递增 changeVersion，但内存读到最新值
        for sec in 2...11 {
            cache.update(
                bookID: bookID,
                chapterID: ch1,
                positionMs: sec * 1_000,
                durationMs: 1_000_000,
                forceFlush: false,
                now: baseDate.addingTimeInterval(Double(sec))
            )
        }
        XCTAssertEqual(cache.changeVersion, versionAfterFirst, "1Hz 常规进度更新不应触发全字典 @Observable 广播")
        XCTAssertEqual(cache.progress(bookID: bookID, chapterID: ch1)?.positionMs, 11_000)

        // 跨越 30s 显著阈值后递增一次
        cache.update(
            bookID: bookID,
            chapterID: ch1,
            positionMs: 35_000,
            durationMs: 1_000_000,
            forceFlush: false,
            now: baseDate.addingTimeInterval(35)
        )
        XCTAssertEqual(cache.changeVersion, versionAfterFirst + 1)

        // 切换章节立即递增
        cache.update(
            bookID: bookID,
            chapterID: ch2,
            positionMs: 1_000,
            durationMs: 1_000_000,
            forceFlush: false,
            now: baseDate.addingTimeInterval(36)
        )
        XCTAssertEqual(cache.changeVersion, versionAfterFirst + 2)
    }

    // MARK: - 13. S5：BookQualityOverrideState 避免未覆写书籍热路径重复同步查库

    @MainActor
    func testBookQualityOverrideStateAvoidsRepeatedDatabaseLookup() throws {
        let container = try TestContainer.make()
        let ctx = container.mainContext
        let engine = PlayerEngine.shared
        let prevContext = engine.modelContext
        let prevGlobal = AppSettingsStore.shared.audioQualityTier
        defer {
            AppSettingsStore.shared.audioQualityTier = prevGlobal
            engine.modelContext = prevContext
            engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .idle)
        }

        engine.modelContext = ctx
        AppSettingsStore.shared.audioQualityTier = .hd

        let unoverriddenBook = BookRef(
            sourceID: "xm",
            bookURL: "https://e.com/s5-follow-global",
            title: "未覆写测试书"
        )
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/s5-follow-global/1", durationSec: 300)

        engine.qualityOverrideDBFetchCountForTesting = 0
        engine.prepare(book: unoverriddenBook, chapters: [ch], chapter: ch)

        XCTAssertEqual(engine.bookQualityOverrideState, .followGlobal)
        XCTAssertEqual(engine.qualityOverrideDBFetchCountForTesting, 1, "prepare 加载书籍配置时仅应查询一次 SQLite")

        // 连续 20 次热路径读取 currentBookAudioQualityTier，不应再触发任何同步查库
        for _ in 0..<20 {
            XCTAssertEqual(engine.currentBookAudioQualityTier, .hd)
        }
        XCTAssertEqual(engine.qualityOverrideDBFetchCountForTesting, 1, "未覆写书籍读取音质档位不得重复查库")

        // 修改全局默认后，.followGlobal 状态无需查库即可实时跟随
        AppSettingsStore.shared.audioQualityTier = .uhd
        XCTAssertEqual(engine.currentBookAudioQualityTier, .uhd)
        XCTAssertEqual(engine.qualityOverrideDBFetchCountForTesting, 1)

        // 设置单书覆写后切为 .custom，读取同样不触发查库
        engine.setAudioQualityTier(.std, reloadCurrent: false, applyToCurrentBookOnly: true)
        XCTAssertEqual(engine.bookQualityOverrideState, .custom(AudioQualityTier.std.rawValue))
        XCTAssertEqual(engine.currentBookAudioQualityTier, .std)
        XCTAssertEqual(engine.qualityOverrideDBFetchCountForTesting, 1)
    }

    // MARK: - 14. S3：AVAudioSession 中断 .began（含 .buffering）与 .ended 复位及恢复回归测试

    @MainActor
    func testAudioInterruptionBeganAndEndedRecoveryAndFlagReset() {
        let engine = PlayerEngine.shared
        let prevFake = engine.useFakeBackend
        defer {
            engine.useFakeBackend = prevFake
            engine.wasPlayingBeforeInterruption = false
            engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .idle)
        }

        engine.useFakeBackend = true
        let book = BookRef(sourceID: "xm", bookURL: "https://e.com/s3-interrupt", title: "中断恢复测试书")
        let ch = ChapterDTO(index: 0, title: "第 1 章", url: "https://e.com/s3-interrupt/1", durationSec: 300)

        // 场景 A：.buffering 态收到中断 .began，应记录 wasPlayingBeforeInterruption 并暂停
        engine.prepare(book: book, chapters: [ch], chapter: ch)
        engine.setDetectedStreamMetricsForTesting(bitrateKbps: nil, sizeBytes: 0, playbackState: .buffering)
        engine.handleAudioInterruption(type: .began, options: [])
        XCTAssertTrue(engine.wasPlayingBeforeInterruption, ".buffering 态中断应记录需恢复标记")
        XCTAssertEqual(engine.state, .paused)

        // 中断 .ended 但不含 .shouldResume：必须复位 wasPlayingBeforeInterruption 且保持暂停
        engine.handleAudioInterruption(type: .ended, options: [])
        XCTAssertFalse(engine.wasPlayingBeforeInterruption, ".ended 必须始终复位 wasPlayingBeforeInterruption")
        XCTAssertEqual(engine.state, .paused)

        // 场景 B：.playing 态收到中断 .began，随后 .ended 含 .shouldResume 应自动恢复播放并复位标记
        engine.startPlayback(book: book, chapters: [ch], startChapter: ch)
        XCTAssertEqual(engine.state, .playing)
        engine.handleAudioInterruption(type: .began, options: [])
        XCTAssertTrue(engine.wasPlayingBeforeInterruption)
        XCTAssertEqual(engine.state, .paused)

        engine.handleAudioInterruption(type: .ended, options: [.shouldResume])
        XCTAssertFalse(engine.wasPlayingBeforeInterruption)
        XCTAssertEqual(engine.state, .playing, "带 .shouldResume 的中断结束应通过 resumeOrReloadCurrentChapter 恢复播放")
    }
}
