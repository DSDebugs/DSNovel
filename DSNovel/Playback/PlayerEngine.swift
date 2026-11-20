import Foundation
import Observation
import AVFoundation
import SwiftData

/// 独立播放时钟 Observable（4.3 节）：仅进度条与时间文字订阅，避免整个播放页每秒重绘
@MainActor
@Observable
final class PlaybackClock {
    var currentTimeSec: Double = 0
    var durationSec: Double = 0

    var progressFraction: Double {
        guard durationSec > 0 else { return 0 }
        return min(max(currentTimeSec / durationSec, 0), 1)
    }

    var formattedCurrent: String {
        Self.formatSeconds(currentTimeSec)
    }

    var formattedRemaining: String {
        let rem = max(0, durationSec - currentTimeSec)
        return "-" + Self.formatSeconds(rem)
    }

    nonisolated static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

enum NextChapterAvailability: Equatable, Sendable {
    case none
    case availableOnline(ChapterDTO)
    case availableDownloaded(ChapterDTO)
}

enum PlaybackState: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case failed(String)
}

struct PlayerInlineFeedback: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    let canUndoIntroSkip: Bool

    init(id: UUID = UUID(), message: String, canUndoIntroSkip: Bool = false) {
        self.id = id
        self.message = message
        self.canUndoIntroSkip = canUndoIntroSkip
    }
}

/// 播放引擎核心（NEW-08 精简后聚焦 AVPlayer 生命周期、队列调度、起播/切章/Seek 与音频 Tap 协调）：
/// - 睡眠定时由 `SleepTimerController.swift` 负责
/// - 按书跳过片头片尾由 `SkipIntroOutroCoordinator.swift` 负责
/// - 远程控制/锁屏/音频中断路由通知由 `PlayerEngine+RemoteCommands.swift` 负责
@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    let clock = PlaybackClock()
    let sleepTimer = SleepTimerController()
    let skipCoordinator = SkipIntroOutroCoordinator()

    private(set) var state: PlaybackState = .idle
    private(set) var currentBook: BookRef?
    private(set) var currentChapter: ChapterDTO?
    private(set) var chapterQueue: [ChapterDTO] = []
    /// 最近一次插件解析错误（若为 .needLogin 或 .needVerify，支持在播放页/详情页一键打开网页登录）
    private(set) var lastPluginError: PluginError?

    var speed: Double = 1.0 {
        didSet {
            if state == .playing {
                player.rate = Float(speed)
            }
            updateRemoteCommandStates()
            updateNowPlayingInfo()
        }
    }

    /// 单书音量：支持 0.0...2.0（0%–200% 人声响度增强，修复 ISS-03 & ISS-14）
    var bookVolume: Double = 1.0 {
        didSet {
            let clamped = min(max(bookVolume, 0.0), 2.0)
            if abs(clamped - bookVolume) > 0.0001 {
                bookVolume = clamped
                return
            }
            applyEffectiveAudioSettings()
        }
    }

    private(set) var inlineFeedback: PlayerInlineFeedback?
    @ObservationIgnored private var inlineFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var shownStaleLocalToastKeys: Set<String> = []

    // 音质与音效状态（§3.2）
    private(set) var audioQualityTier: AudioQualityTier = AppSettingsStore.shared.audioQualityTier
    private(set) var audioEffectPreset: AudioEffectPreset = AppSettingsStore.shared.audioEffectPreset
    private(set) var customEQBandsDb: [Double] = AppSettingsStore.shared.customEQBandsDb
    /// 当前流/音轨是否支持 MTAudioProcessingTap（HLS .m3u8 或无音轨时为 false）
    private(set) var isAudioTapSupportedForCurrentItem: Bool = true
    var audioBoostDB: Double = AppSettingsStore.shared.audioBoostDB {
        didSet {
            let clamped = min(max(audioBoostDB, 0.0), 12.0)
            if abs(clamped - audioBoostDB) > 0.001 {
                audioBoostDB = clamped
                return
            }
            AppSettingsStore.shared.audioBoostDB = clamped
            applyEffectiveAudioSettings()
        }
    }
    var audioBalance: Double = AppSettingsStore.shared.audioBalance {
        didSet {
            let clamped = min(max(audioBalance, -1.0), 1.0)
            if abs(clamped - audioBalance) > 0.001 {
                audioBalance = clamped
                return
            }
            AppSettingsStore.shared.audioBalance = clamped
            applyEffectiveAudioSettings()
        }
    }

    var activeEQBandsDb: [Double] {
        audioEffectPreset == .custom ? customEQBandsDb : audioEffectPreset.defaultBandsDb
    }

    var isMiniPlayerVisible: Bool {
        currentBook != nil && currentChapter != nil
    }

    var currentBookID: String? {
        currentBook?.id
    }

    private(set) var bufferedRange: Double = 0
    private(set) var isPlayingLocalFile: Bool = false
    private(set) var detectedAudioBitrateKbps: Int?
    private(set) var detectedAudioSizeBytes: Int64 = 0
    var useFakeBackend: Bool = false

    var isBuffering: Bool {
        if case .buffering = state { return true }
        return false
    }

    /// 当前播放章节的 1-based 序号（用于底部功能坞展示 `10/1497` 及锁屏章节号）
    var currentChapterOneBasedIndex: Int {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }) else {
            return 0
        }
        return idx + 1
    }

    /// 当前章节音质可调能力分级（区分多码率 / 固定单码率 / 本地离线）
    var currentAudioQualitySupportMode: AudioQualitySupportMode {
        if isPlayingLocalFile {
            return .localOffline
        }
        guard let book = currentBook else {
            return .fixedSingleBitrate
        }
        return QualityPolicy.sourceHasMultipleBitrates(sourceID: book.sourceID) ? .multiBitrate : .fixedSingleBitrate
    }

    /// 当前章节是否有「内置解析」参与
    var currentChapterHasBuiltinParser: Bool {
        builtinParserResolved
    }

    /// 当前播放书籍生效的音质档位（单书覆写优先，未覆写则跟随全局默认）
    var currentBookAudioQualityTier: AudioQualityTier {
        let globalDefault = AppSettingsStore.shared.audioQualityTier
        guard let bookID = currentBook?.id else {
            return globalDefault
        }
        let overrideRaw = fetchBookPreferredAudioQualityRaw(for: bookID)
        return QualityPolicy.effectiveTier(bookOverrideRaw: overrideRaw, globalDefault: globalDefault)
    }

    /// 顶栏音质徽标文案（三层独立码率核算：实测码率 → 体积兜底 → 空串；播放失败或无章节不显示，绝不回落所选档位）
    var streamStatusBadgeText: String {
        guard currentChapter != nil else { return "" }
        if case .failed = state { return "" }
        if let kbps = detectedAudioBitrateKbps, kbps > 0 {
            return AudioQualityTier.badgeText(forDetectedBitrateKbps: kbps)
        }
        if detectedAudioSizeBytes > 0 {
            return AudioQualityTier.formattedSizeFallback(bytes: detectedAudioSizeBytes)
        }
        return ""
    }

    /// 仅供单元测试注入实测码率/体积与播放状态
    func setDetectedStreamMetricsForTesting(
        bitrateKbps: Int?,
        sizeBytes: Int64 = 0,
        playbackState: PlaybackState? = nil
    ) {
        detectedAudioBitrateKbps = bitrateKbps
        detectedAudioSizeBytes = sizeBytes
        if let playbackState {
            state = playbackState
        }
    }

    var canPlayPreviousChapter: Bool {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }) else {
            return false
        }
        return idx > 0
    }

    var nextChapterAvailability: NextChapterAvailability {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }),
              idx + 1 < chapterQueue.count else {
            return .none
        }
        let nextCh = chapterQueue[idx + 1]
        if let book = currentBook,
           DownloadManager.shared.downloadState(bookID: book.id, chapterID: nextCh.id) == .completed {
            return .availableDownloaded(nextCh)
        }
        return .availableOnline(nextCh)
    }

    static func snapSpeed(_ raw: Double) -> Double {
        let clamped = min(max(raw, 0.5), 3.0)
        return (clamped * 20.0).rounded() / 20.0
    }

    func setSpeed(_ newSpeed: Double, persist: Bool = true, alsoSetDefault: Bool = false) {
        let snapped = Self.snapSpeed(newSpeed)
        self.speed = snapped
        if persist {
            saveBookAudioSettings()
            if alsoSetDefault {
                AppSettingsStore.shared.defaultSpeed = snapped
            }
        } else {
            AppSettingsStore.shared.defaultSpeed = snapped
        }
    }

    // MARK: - 音质与音效调节接口

    func setAudioQualityTier(
        _ tier: AudioQualityTier,
        reloadCurrent: Bool = false,
        applyToCurrentBookOnly: Bool = false
    ) {
        let normalized = tier
        if applyToCurrentBookOnly, let book = currentBook {
            audioQualityTier = normalized
            if let ctx = modelContext {
                let saved = ensureBookRow(for: book, in: ctx)
                saved.preferredAudioQualityRaw = normalized.rawValue
                try? ctx.save()
            } else if let saved = LibraryStore.shared.book(for: book.id) {
                saved.preferredAudioQualityRaw = normalized.rawValue
                try? LibraryStore.shared.modelContext?.save()
            }
        } else {
            AppSettingsStore.shared.audioQualityTier = normalized
            audioQualityTier = currentBookAudioQualityTier
        }
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = audioQualityTier.preferredForwardBufferDuration
        }
        let shouldReload = reloadCurrent && QualityPolicy.canReloadForTierChange(
            sourceID: currentBook?.sourceID ?? "",
            isLocalOffline: currentAudioQualitySupportMode == .localOffline
        )
        Task {
            let parsers = await BuiltinParserRuntime.shared.installedParsers()
            for p in parsers {
                await BuiltinParserRuntime.shared.invalidateCache(parserID: p.id, episodeURL: nil)
            }
            if shouldReload {
                self.retryCurrentChapter()
            }
        }
    }

    func setAudioEffectPreset(_ preset: AudioEffectPreset) {
        audioEffectPreset = preset
        AppSettingsStore.shared.audioEffectPreset = preset
        applyEffectiveAudioSettings()
    }

    /// 同步音频通道切换（如 MoreSheet 切换人声/默认通道）并立即生效
    func syncAudioChannelFromSettings() {
        configureAudioSession()
        applyEffectiveAudioSettings()
    }

    func syncGlobalAudioPreferencesFromSettings() {
        let settings = AppSettingsStore.shared
        audioQualityTier = currentBookAudioQualityTier
        audioEffectPreset = settings.audioEffectPreset
        customEQBandsDb = settings.customEQBandsDb
        audioBoostDB = settings.audioBoostDB
        audioBalance = settings.audioBalance
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = audioQualityTier.preferredForwardBufferDuration
        }
        configureAudioSession()
        applyEffectiveAudioSettings()
    }

    func showInlineToast(_ message: String, canUndoIntroSkip: Bool = false, durationSec: Double = 4.0) {
        inlineFeedbackTask?.cancel()
        let feedback = PlayerInlineFeedback(message: message, canUndoIntroSkip: canUndoIntroSkip)
        inlineFeedback = feedback
        inlineFeedbackTask = Task { [weak self] in
            let ns = UInt64(max(0.5, durationSec) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.inlineFeedback?.id == feedback.id else { return }
                self.inlineFeedback = nil
            }
        }
    }

    func clearInlineFeedback() {
        inlineFeedbackTask?.cancel()
        inlineFeedback = nil
    }

    func updateCustomEQBand(index: Int, gainDb: Double) {
        guard (0..<5).contains(index) else { return }
        var bands = customEQBandsDb.count == 5 ? customEQBandsDb : [0.0, 0.0, 0.0, 0.0, 0.0]
        bands[index] = min(max(gainDb, -12.0), 12.0)
        updateCustomEQBands(bands)
    }

    /// 批量更新 5 段自定义 EQ（单次落盘与管线更新，供「频段归零」等批量操作使用）
    func updateCustomEQBands(_ bands: [Double]) {
        let normalized: [Double] = (0..<5).map { idx in
            let raw = idx < bands.count ? bands[idx] : 0.0
            return min(max(raw, -12.0), 12.0)
        }
        customEQBandsDb = normalized
        AppSettingsStore.shared.customEQBandsDb = normalized
        if audioEffectPreset != .custom {
            audioEffectPreset = .custom
            AppSettingsStore.shared.audioEffectPreset = .custom
        }
        applyEffectiveAudioSettings()
    }

    func resetEQToOriginal() {
        customEQBandsDb = [0.0, 0.0, 0.0, 0.0, 0.0]
        AppSettingsStore.shared.customEQBandsDb = customEQBandsDb
        audioEffectPreset = .original
        AppSettingsStore.shared.audioEffectPreset = .original
        audioBoostDB = 0.0
        applyEffectiveAudioSettings()
    }

    func applyEffectiveAudioSettings() {
        let effective = PlayerAudioPipeline.computeEffectiveVolume(
            bookVolume: bookVolume,
            preset: audioEffectPreset,
            eqBandsDb: activeEQBandsDb,
            boostDB: audioBoostDB
        )
        let fade = min(max(sleepTimer.fadeMultiplier, 0.0), 1.0)
        let scaledPlayerVol = Float(min(max(Double(effective.playerVolume) * Double(fade), 0.0), 1.0))
        let scaledMixGain = Float(min(max(Double(effective.mixGain) * Double(fade), 0.0), 3.99))

        guard let item = player.currentItem else {
            player.volume = scaledPlayerVol
            return
        }

        PlayerAudioPipeline.applyToPlayerItem(
            item,
            preset: audioEffectPreset,
            audioChannel: AppSettingsStore.shared.audioChannel,
            bookVolume: bookVolume,
            eqBandsDb: activeEQBandsDb,
            boostDB: audioBoostDB,
            balance: audioBalance,
            qualityTier: audioQualityTier
        )

        let itemID = ObjectIdentifier(item)
        if let ctx = currentTapContext, tapAttachedItemID == itemID, isAudioTapSupportedForCurrentItem {
            // Tap 已挂载：EQ / 声道平衡 / 响度增益 / 睡眠渐弱 / 软限幅统一在 DSP 渲染回调内实时执行
            ctx.update(bandsDb: activeEQBandsDb, balance: audioBalance, mixGain: scaledMixGain)
            player.volume = 1.0
            return
        }

        // 尚未挂载或不支持 Tap（如 HLS .m3u8）
        player.volume = scaledPlayerVol
        if tapEvaluatedItemID == itemID {
            // 已评估过不支持 Tap：HLS 下不挂载 audioMix
            return
        }

        let asset = item.asset
        if PlayerAudioPipeline.isHLSAsset(asset) {
            tapEvaluatedItemID = itemID
            isAudioTapSupportedForCurrentItem = false
            item.audioMix = nil
            return
        }

        // 异步加载音轨并挂载 MTAudioProcessingTap（每条 AVPlayerItem 仅执行一次）
        tapEvaluatedItemID = itemID
        let tapContext = AudioTapDSPContext(
            bandsDb: activeEQBandsDb,
            balance: audioBalance,
            mixGain: scaledMixGain
        )
        let gen = playbackGeneration
        Task { @MainActor [weak self, weak item] in
            guard let self, let item, gen == self.playbackGeneration, self.loadedItem === item else { return }
            if let mix = await PlayerAudioPipeline.makeAudioTapMix(for: asset, context: tapContext) {
                guard gen == self.playbackGeneration, self.loadedItem === item else { return }
                self.currentTapContext = tapContext
                self.tapAttachedItemID = ObjectIdentifier(item)
                self.isAudioTapSupportedForCurrentItem = true
                // 再同步一次最新参数，防止异步挂载期间用户已拖动滑块
                let latest = PlayerAudioPipeline.computeEffectiveVolume(
                    bookVolume: self.bookVolume,
                    preset: self.audioEffectPreset,
                    eqBandsDb: self.activeEQBandsDb,
                    boostDB: self.audioBoostDB
                )
                let latestFade = min(max(self.sleepTimer.fadeMultiplier, 0.0), 1.0)
                tapContext.update(
                    bandsDb: self.activeEQBandsDb,
                    balance: self.audioBalance,
                    mixGain: Float(min(max(Double(latest.mixGain) * Double(latestFade), 0.0), 3.99))
                )
                item.audioMix = mix
                self.player.volume = 1.0
            } else {
                guard gen == self.playbackGeneration, self.loadedItem === item else { return }
                self.currentTapContext = nil
                self.tapAttachedItemID = nil
                self.isAudioTapSupportedForCurrentItem = false
                item.audioMix = nil
            }
        }
    }

    /// 当本地离线音频文件被用户在书籍页或下载管理中删除时同步更新播放源状态
    func handleLocalFileDeleted(bookID: String, chapterID: String) {
        guard currentBookID == bookID, currentChapter?.id == chapterID else { return }
        bypassLocalChapterID = chapterID
        if isPlayingLocalFile {
            isPlayingLocalFile = false
        }
    }

    /// T3-05 恢复到上次播放位置但保持暂停（不发声）
    func prepare(
        book: BookRef,
        chapters: [ChapterDTO],
        chapter: ChapterDTO,
        positionMs: Int = 0
    ) {
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        currentBook = book
        chapterQueue = chapters
        currentChapter = chapter
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        preResolvedNextChapterURL = nil
        loadBookPreferences(for: book.id)
        let startSec = max(0, Double(positionMs) / 1000.0)
        detachCurrentItem(startSec: startSec, isIntroSkip: false)
        state = .paused
        clock.currentTimeSec = startSec
        clock.durationSec = max(chapter.hintDurationSec, startSec > 0 ? startSec + 60 : 600)
        updateRemoteCommandStates()
        updateNowPlayingInfo()
    }

    // MARK: - 内部状态（跨文件 extension 需访问的成员使用 internal）

    @ObservationIgnored nonisolated(unsafe) let player = AVPlayer()
    @ObservationIgnored nonisolated(unsafe) private var timeObserverToken: Any?
    @ObservationIgnored nonisolated(unsafe) var outroBoundaryObserverToken: Any?
    @ObservationIgnored nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadedTimeRangesObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored var playbackGeneration: UInt64 = 0
    @ObservationIgnored private var pendingSeekSec: Double?
    @ObservationIgnored private var pendingSeekIsIntroSkip: Bool = false
    @ObservationIgnored var isSeeking: Bool = false
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var lastPersistedTime: TimeInterval = 0
    @ObservationIgnored private var hasRetriedCurrentChapter = false
    @ObservationIgnored var wasPlayingBeforeInterruption = false
    /// 当前 AVPlayerItem 是否已 readyToPlay 且属于「当前章节」。
    @ObservationIgnored var isCurrentItemReady = false
    /// 当前章节对应的 AVPlayerItem，用于周期观察者校验时间来源
    @ObservationIgnored private var loadedItem: AVPlayerItem?
    @ObservationIgnored private var currentTapContext: AudioTapDSPContext?
    @ObservationIgnored private var tapAttachedItemID: ObjectIdentifier?
    @ObservationIgnored private var tapEvaluatedItemID: ObjectIdentifier?
    /// 章节列表缓存签名：同一本书、同一份章节队列只落盘一次
    @ObservationIgnored private var savedQueueSignature: String?
    @ObservationIgnored private var precacheTask: Task<Void, Never>?
    /// 当前章节正在播放本地文件但文件损坏时，强制改走在线流
    @ObservationIgnored private var bypassLocalChapterID: String?
    /// 当前章节地址是否由「内置解析」给出（用于直链过期后的强制重解析）
    @ObservationIgnored private var builtinParserResolved = false
    /// ② 能力声明驱动 UI：当前书源已安装的内置解析器声明的音质集合
    private(set) var currentChapterParserQualities: Set<String> = []
    /// 兼容属性：当前书源已安装的内置解析器是否声明了 lossless 能力
    var currentChapterParserDeclaresLossless: Bool {
        QualityPolicy.parserDeclaresLossless(currentChapterParserQualities)
    }

    /// A-1(b)：书源未提供 duration 时，用「上次成功播放的实测时长」回填（>120s 才采信，避免误采信试听片段）
    static func resolveExpectedDuration(hintDurationSec: Double, observedDurationMs: Int) -> Double? {
        if hintDurationSec > 0 {
            return hintDurationSec
        }
        return observedDurationMs > 120_000 ? Double(observedDurationMs) / 1000 : nil
    }
    /// P-05：记录已触发章尾预解析的下一章 URL，避免重复请求
    @ObservationIgnored private var preResolvedNextChapterURL: String?
    var modelContext: ModelContext?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configureRemoteCommands()
        observePeriodicTime()
        observeNotifications()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let boundaryToken = outroBoundaryObserverToken {
            player.removeTimeObserver(boundaryToken)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 播放入口与章节调度

    func startPlayback(
        book: BookRef,
        chapters: [ChapterDTO],
        startChapter: ChapterDTO,
        initialPositionMs: Int = 0
    ) {
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration

        currentBook = book
        chapterQueue = chapters
        currentChapter = startChapter
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        preResolvedNextChapterURL = nil
        sleepTimer.resetFadeMultiplier()

        loadBookPreferences(for: book.id)
        let (startSec, isIntroSkip) = skipCoordinator.resolveStartPosition(
            initialPositionMs: initialPositionMs,
            hintDurationSec: startChapter.hintDurationSec
        )
        detachCurrentItem(startSec: startSec, isIntroSkip: isIntroSkip)
        if isIntroSkip {
            showInlineToast("已跳过片头 \(Int(startSec.rounded())) 秒", canUndoIntroSkip: true, durationSec: 4.0)
        }
        clock.currentTimeSec = startSec
        clock.durationSec = startChapter.hintDurationSec
        persistProgressNow(positionMsOverride: Int(startSec * 1000))
        updateRemoteCommandStates()

        if useFakeBackend {
            state = .playing
            isCurrentItemReady = true
            bufferedRange = 1.0
            if clock.durationSec <= 0 { clock.durationSec = 600 }
            updateNowPlayingInfo()
            return
        }
        loadTask = Task {
            await loadAndPlay(chapter: startChapter, initialPositionMs: initialPositionMs, generation: gen, detachFirst: false)
        }
    }

    /// 摘除当前播放项并重置所有与「旧音频」相关的状态
    private func detachCurrentItem(startSec: Double, isIntroSkip: Bool = false) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        removeOutroBoundaryObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedItem = nil
        currentTapContext = nil
        tapAttachedItemID = nil
        tapEvaluatedItemID = nil
        isAudioTapSupportedForCurrentItem = true
        isCurrentItemReady = false
        isSeeking = false
        seekGeneration &+= 1
        isPlayingLocalFile = false
        detectedAudioBitrateKbps = nil
        detectedAudioSizeBytes = 0
        skipCoordinator.resetChapterState()
        preResolvedNextChapterURL = nil
        bufferedRange = 0
        pendingSeekSec = startSec > 0.5 ? startSec : nil
        pendingSeekIsIntroSkip = (pendingSeekSec != nil) && isIntroSkip
        lastPersistedTime = startSec
        state = .buffering
    }

    private func startPlayerAtCurrentRate() {
        if isPlayingLocalFile {
            player.playImmediately(atRate: Float(speed))
        } else {
            // 在线流使用 player.rate 让系统按 automaticallyWaitsToMinimizeStalling 先完成缓冲，避免卡顿起播
            player.rate = Float(speed)
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused, .idle:
            resumeOrReloadCurrentChapter()
        case .failed:
            retryCurrentChapter()
        case .buffering:
            pause()
        }
    }

    func resumeOrReloadCurrentChapter() {
        if useFakeBackend {
            state = .playing
            updateNowPlayingInfo()
        } else if player.currentItem?.status == .readyToPlay {
            resume()
        } else if currentChapter != nil {
            retryCurrentChapter()
        } else {
            resume()
        }
    }

    func retryCurrentChapter() {
        guard let ch = currentChapter else { return }
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        hasRetriedCurrentChapter = false
        lastPluginError = nil
        let resumeMs = Int(clock.currentTimeSec * 1000)
        detachCurrentItem(startSec: Double(resumeMs) / 1000.0, isIntroSkip: false)
        loadTask = Task {
            await loadAndPlay(chapter: ch, initialPositionMs: resumeMs, generation: gen, detachFirst: false)
        }
    }

    func pause() {
        player.pause()
        state = .paused
        persistProgressNow()
        updateNowPlayingInfo()
    }

    func resume() {
        configureAudioSession()
        applyEffectiveAudioSettings()
        startPlayerAtCurrentRate()
        state = .playing
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        skipCoordinator.handleSeek(to: clamped, durationSec: clock.durationSec)
        clock.currentTimeSec = clamped
        guard isCurrentItemReady, let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeekSec = clamped
            pendingSeekIsIntroSkip = false
            persistProgressNow(positionMsOverride: Int(clamped * 1000))
            return
        }
        isSeeking = true
        seekGeneration &+= 1
        let currentSeekGen = seekGeneration
        let currentPlayGen = playbackGeneration
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance: CMTime = isPlayingLocalFile ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      currentSeekGen == self.seekGeneration,
                      currentPlayGen == self.playbackGeneration else { return }
                self.isSeeking = false
                self.clock.currentTimeSec = clamped
                self.persistProgressNow(positionMsOverride: Int(clamped * 1000))
                self.updateNowPlayingInfo()
            }
        }
    }

    func skipForward(_ deltaSec: Double = 30) {
        let next = min(clock.durationSec > 0 ? clock.durationSec : clock.currentTimeSec + deltaSec, clock.currentTimeSec + deltaSec)
        seek(to: next)
    }

    func skipBackward(_ deltaSec: Double = 15) {
        seek(to: max(0, clock.currentTimeSec - deltaSec))
    }

    func playNextChapter() {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }),
              idx + 1 < chapterQueue.count else {
            pause()
            return
        }
        let nextCh = chapterQueue[idx + 1]
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        currentChapter = nextCh
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        sleepTimer.resetFadeMultiplier()
        let (startSec, isIntroSkip) = skipCoordinator.resolveStartPosition(
            initialPositionMs: 0,
            hintDurationSec: nextCh.hintDurationSec
        )
        detachCurrentItem(startSec: startSec, isIntroSkip: isIntroSkip)
        if isIntroSkip {
            showInlineToast("已跳过片头 \(Int(startSec.rounded())) 秒", canUndoIntroSkip: true, durationSec: 4.0)
        }
        clock.currentTimeSec = startSec
        clock.durationSec = nextCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, Int(startSec * 1000)))
        updateRemoteCommandStates()
        updateNowPlayingInfo()

        loadTask = Task {
            await loadAndPlay(chapter: nextCh, initialPositionMs: 0, generation: gen, detachFirst: false)
        }
    }

    func playPreviousChapter() {
        guard let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }),
              idx > 0 else {
            seek(to: 0)
            return
        }
        let prevCh = chapterQueue[idx - 1]
        loadTask?.cancel()
        precacheTask?.cancel()
        playbackGeneration &+= 1
        let gen = playbackGeneration
        currentChapter = prevCh
        lastPluginError = nil
        hasRetriedCurrentChapter = false
        sleepTimer.resetFadeMultiplier()
        let (startSec, isIntroSkip) = skipCoordinator.resolveStartPosition(
            initialPositionMs: 0,
            hintDurationSec: prevCh.hintDurationSec
        )
        detachCurrentItem(startSec: startSec, isIntroSkip: isIntroSkip)
        if isIntroSkip {
            showInlineToast("已跳过片头 \(Int(startSec.rounded())) 秒", canUndoIntroSkip: true, durationSec: 4.0)
        }
        clock.currentTimeSec = startSec
        clock.durationSec = prevCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, Int(startSec * 1000)))
        updateRemoteCommandStates()
        updateNowPlayingInfo()

        loadTask = Task {
            await loadAndPlay(chapter: prevCh, initialPositionMs: 0, generation: gen, detachFirst: false)
        }
    }

    // MARK: - 内部流加载与原生 AVURLAsset 请求头构建（100% 对齐 ssts Player.resolveAsset）

    nonisolated static func makeStreamAsset(url playURL: URL, headers rawHeaders: [String: String], kind: StreamKind) -> AVURLAsset {
        if playURL.isFileURL {
            return AVURLAsset(url: playURL)
        }
        var wireHeaders = rawHeaders
        var mediaTypeHint: String?
        for key in Array(wireHeaders.keys) where key.lowercased() == "x-media-type" {
            mediaTypeHint = wireHeaders.removeValue(forKey: key)?.lowercased()
        }
        if !wireHeaders.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            wireHeaders["User-Agent"] = JsHostBridge.mobileUA
        }
        if !wireHeaders.keys.contains(where: { $0.lowercased() == "cookie" }) {
            let cookieStr = CookieSync.cookieHeader(for: playURL)
            if !cookieStr.isEmpty {
                wireHeaders["Cookie"] = cookieStr
            }
        }

        var options: [String: Any] = [:]
        if !wireHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = wireHeaders
        }

        let ext = playURL.pathExtension.lowercased()
        let absLower = playURL.absoluteString.lowercased()
        if kind == .hls || mediaTypeHint == "hls" || ext == "m3u8" || absLower.contains(".m3u8") {
            options["AVURLAssetOutOfBandMIMETypeKey"] = "application/x-mpegURL"
        } else if ext == "m4a" || ext == "mp4" {
            options["AVURLAssetOutOfBandMIMETypeKey"] = "audio/mp4"
        }
        return AVURLAsset(url: playURL, options: options)
    }

    private func loadAndPlay(
        chapter: ChapterDTO,
        initialPositionMs: Int,
        generation: UInt64,
        detachFirst: Bool = false
    ) async {
        guard let book = currentBook, generation == playbackGeneration else { return }
        let (startSec, isIntroSkip) = skipCoordinator.resolveStartPosition(
            initialPositionMs: initialPositionMs,
            hintDurationSec: chapter.hintDurationSec
        )
        if detachFirst {
            detachCurrentItem(startSec: startSec, isIntroSkip: isIntroSkip)
        }

        state = .buffering
        lastPluginError = nil
        clock.currentTimeSec = startSec
        clock.durationSec = chapter.hintDurationSec
        configureAudioSession()

        do {
            let playURL: URL
            var headers: [String: String] = [:]
            var streamKind: StreamKind = .onDemand

            let effectiveTier = currentBookAudioQualityTier
            audioQualityTier = effectiveTier

            var usingLocal = false
            var initialBitrateKbps: Int? = nil
            var initialSizeBytes: Int64 = 0
            if bypassLocalChapterID != chapter.id,
               let localInfo = DownloadManager.shared.localFileInfo(bookID: book.id, chapterID: chapter.id) {
                playURL = localInfo.url
                usingLocal = true
                bufferedRange = 1.0
                builtinParserResolved = false
                currentChapterParserQualities = []
                if let dlItem = fetchDownloadItem(bookID: book.id, chapterID: chapter.id) {
                    if dlItem.bytes > 0 {
                        initialSizeBytes = dlItem.bytes
                    }
                    if dlItem.actualBitrateKbps > 0 {
                        initialBitrateKbps = dlItem.actualBitrateKbps
                    } else if initialSizeBytes > 0 {
                        let knownDur = dlItem.actualDurationSec > 1 ? dlItem.actualDurationSec : chapter.hintDurationSec
                        if knownDur > 1 {
                            initialBitrateKbps = AudioQualityTier.computedBitrateKbps(
                                bytes: initialSizeBytes,
                                durationSec: knownDur
                            )
                        }
                    }
                }
                if initialSizeBytes <= 0,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: playURL.path),
                   let fileSize = attrs[.size] as? NSNumber,
                   fileSize.int64Value > 0 {
                    initialSizeBytes = fileSize.int64Value
                    if initialBitrateKbps == nil, chapter.hintDurationSec > 1 {
                        initialBitrateKbps = AudioQualityTier.computedBitrateKbps(
                            bytes: initialSizeBytes,
                            durationSec: chapter.hintDurationSec
                        )
                    }
                }
                if localInfo.isStale {
                    let dedupKey = "\(book.id)::\(chapter.id)::\(effectiveTier.rawValue)"
                    if shownStaleLocalToastKeys.insert(dedupKey).inserted {
                        let oldTitle = AudioQualityTier(rawValue: localInfo.tierRaw)?.title ?? "旧档位"
                        let curTitle = effectiveTier.title
                        showInlineToast("本条为「\(oldTitle)」离线音频，当前偏好为「\(curTitle)」；可在下载页按新音质重下")
                    }
                }
            } else {
                let observedMs = ChapterProgressCache.shared.progress(bookID: book.id, chapterID: chapter.id)?.durationMs ?? 0
                let expectedDuration = Self.resolveExpectedDuration(
                    hintDurationSec: chapter.hintDurationSec,
                    observedDurationMs: observedMs
                )
                let stream = try await PluginRuntime.shared.resolvePlayStream(
                    sourceID: book.sourceID,
                    episodeURL: chapter.url,
                    forDownload: false,
                    tier: effectiveTier,
                    expectedDurationSec: expectedDuration
                )
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                guard let remote = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: chapter.url) else {
                    throw PluginError.parseFailed("无效的音频 URL")
                }
                playURL = remote
                headers = stream.headers
                streamKind = stream.kind
                if let fileSize = stream.fileSize, fileSize > 0 {
                    initialSizeBytes = fileSize
                    let knownDuration = (stream.durationSec ?? 0) > 1 ? (stream.durationSec ?? 0) : (expectedDuration ?? 0)
                    if knownDuration > 1 {
                        initialBitrateKbps = AudioQualityTier.computedBitrateKbps(
                            bytes: fileSize,
                            durationSec: knownDuration
                        )
                    }
                }
                builtinParserResolved = stream.resolvedBy == BuiltinParserRuntime.resolverTag
                if let matchedParser = await BuiltinParserRuntime.shared.parser(forSourceID: book.sourceID, sourceURL: book.bookURL) {
                    currentChapterParserQualities = matchedParser.meta.qualities
                } else {
                    currentChapterParserQualities = []
                }
            }

            guard !Task.isCancelled, generation == playbackGeneration else { return }

            let asset = Self.makeStreamAsset(url: playURL, headers: headers, kind: streamKind)
            let item = AVPlayerItem(asset: asset)

            loadedItem = item
            isPlayingLocalFile = usingLocal
            isAudioTapSupportedForCurrentItem = !PlayerAudioPipeline.isHLSAsset(asset)
            detectedAudioSizeBytes = initialSizeBytes
            detectedAudioBitrateKbps = initialBitrateKbps
            observePlayerItem(item, chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            player.replaceCurrentItem(with: item)
            applyEffectiveAudioSettings()

            if pendingSeekSec == nil {
                startPlayerAtCurrentRate()
            }
            persistProgressNow(positionMsOverride: Int(startSec * 1000))
            updateNowPlayingInfo()
        } catch let pErr as PluginError {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            lastPluginError = pErr
            switch pErr {
            case .needLogin, .needVerify:
                SourceStore.shared.markAuthExpired(sourceID: book.sourceID)
            default:
                break
            }
            if !hasRetriedCurrentChapter, case .network = pErr {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation, detachFirst: true)
            } else {
                detectedAudioBitrateKbps = nil
                detectedAudioSizeBytes = 0
                state = .failed(pErr.localizedDescription)
            }
        } catch {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            if !hasRetriedCurrentChapter {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation, detachFirst: true)
            } else {
                detectedAudioBitrateKbps = nil
                detectedAudioSizeBytes = 0
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 异步读取当前 AVPlayerItem 音轨实际码率（三层独立核算：音轨 estimatedDataRate → accessLog → 字节数/时长）
    private func inspectActualAudioBitrate(for item: AVPlayerItem, generation: UInt64) {
        let fallbackSizeBytes = detectedAudioSizeBytes
        let fallbackClockDuration = clock.durationSec
        Task { [weak self] in
            var measuredBps: Double = 0
            if let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
               let firstTrack = tracks.first,
               let dataRate = try? await firstTrack.load(.estimatedDataRate),
               dataRate.isFinite, dataRate > 0 {
                measuredBps = Double(dataRate)
            }
            if measuredBps <= 0, let lastEvent = item.accessLog()?.events.last {
                if lastEvent.indicatedBitrate.isFinite && lastEvent.indicatedBitrate > 0 {
                    measuredBps = lastEvent.indicatedBitrate
                }
            }
            var kbps = measuredBps > 0 ? Int((measuredBps / 1000.0).rounded()) : 0
            if kbps <= 0, fallbackSizeBytes > 0 {
                let itemDur = (try? await item.asset.load(.duration).seconds) ?? 0
                let effectiveDur = (itemDur.isFinite && itemDur > 1) ? itemDur : fallbackClockDuration
                if let computed = AudioQualityTier.computedBitrateKbps(
                    bytes: fallbackSizeBytes,
                    durationSec: effectiveDur
                ) {
                    kbps = computed
                }
            }
            guard kbps > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.playbackGeneration else { return }
                self.detectedAudioBitrateKbps = kbps
            }
        }
    }

    private func observePlayerItem(
        _ item: AVPlayerItem,
        chapter: ChapterDTO,
        initialPositionMs: Int,
        generation: UInt64
    ) {
        loadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] observedItem, _ in
            let itemID = ObjectIdentifier(observedItem)
            let ranges = observedItem.loadedTimeRanges
            let rawDur = observedItem.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration,
                      let loaded = self.loadedItem, ObjectIdentifier(loaded) == itemID else { return }
                if self.isPlayingLocalFile {
                    self.bufferedRange = 1.0
                    return
                }
                let totalDur = (rawDur.isFinite && rawDur > 0) ? rawDur : self.clock.durationSec
                guard totalDur > 0, let firstVal = ranges.first?.timeRangeValue else { return }
                let bufferedEnd = CMTimeGetSeconds(CMTimeAdd(firstVal.start, firstVal.duration))
                if bufferedEnd.isFinite && bufferedEnd >= 0 {
                    self.bufferedRange = min(max(bufferedEnd / totalDur, 0.0), 1.0)
                }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let itemStatus = observedItem.status
            let itemID = ObjectIdentifier(observedItem)
            let itemDurationSec = observedItem.duration.seconds
            let itemErrorDesc = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration,
                      let loaded = self.loadedItem, ObjectIdentifier(loaded) == itemID else { return }
                switch itemStatus {
                case .readyToPlay:
                    guard !self.isCurrentItemReady else { return }
                    self.isCurrentItemReady = true
                    if itemDurationSec.isFinite && itemDurationSec > 0 {
                        self.clock.durationSec = itemDurationSec
                        self.configureOutroBoundaryObserver(durationSec: itemDurationSec)
                    }
                    self.applyEffectiveAudioSettings()
                    self.inspectActualAudioBitrate(for: loaded, generation: generation)
                    self.schedulePrecache(generation: generation)

                    // 二次短章校验：拿到真实时长后，若片头跳过超过 (duration - 5s) 则取消跳过从 0 起播
                    if self.pendingSeekIsIntroSkip,
                       let introSeek = self.pendingSeekSec,
                       self.skipCoordinator.shouldCancelPendingIntroSkip(
                           pendingIntroSeekSec: introSeek,
                           actualDurationSec: itemDurationSec
                       ) {
                        self.pendingSeekSec = nil
                        self.pendingSeekIsIntroSkip = false
                        self.clock.currentTimeSec = 0
                    }

                    if let seekSec = self.pendingSeekSec, seekSec > 0 {
                        self.clock.currentTimeSec = seekSec
                        self.isSeeking = true
                        self.seekGeneration &+= 1
                        let currentSeekGen = self.seekGeneration
                        let target = CMTime(seconds: seekSec, preferredTimescale: 600)
                        let tolerance: CMTime = self.isPlayingLocalFile ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
                        self.player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self, generation == self.playbackGeneration else { return }
                                if currentSeekGen == self.seekGeneration {
                                    self.isSeeking = false
                                }
                                self.pendingSeekSec = nil
                                self.pendingSeekIsIntroSkip = false
                                self.lastPersistedTime = seekSec
                                self.configureAudioSession()
                                self.applyEffectiveAudioSettings()
                                self.startPlayerAtCurrentRate()
                                self.state = .playing
                                self.persistProgressNow(positionMsOverride: Int(seekSec * 1000))
                                self.updateNowPlayingInfo()
                            }
                        }
                    } else {
                        self.pendingSeekSec = nil
                        self.pendingSeekIsIntroSkip = false
                        self.configureAudioSession()
                        self.applyEffectiveAudioSettings()
                        self.startPlayerAtCurrentRate()
                        self.state = .playing
                        self.persistProgressNow()
                        self.updateNowPlayingInfo()
                    }
                case .failed:
                    let errMsg = itemErrorDesc ?? "音频流加载失败"
                    if self.isPlayingLocalFile, let book = self.currentBook {
                        DownloadManager.shared.invalidateLocalFile(bookID: book.id, chapterID: chapter.id)
                        self.bypassLocalChapterID = chapter.id
                        await self.loadAndPlay(
                            chapter: chapter,
                            initialPositionMs: Int(self.clock.currentTimeSec * 1000),
                            generation: generation,
                            detachFirst: true
                        )
                    } else if !self.hasRetriedCurrentChapter {
                        self.hasRetriedCurrentChapter = true
                        if self.builtinParserResolved {
                            await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: chapter.url)
                        }
                        await self.loadAndPlay(
                            chapter: chapter,
                            initialPositionMs: initialPositionMs,
                            generation: generation,
                            detachFirst: true
                        )
                    } else {
                        self.detectedAudioBitrateKbps = nil
                        self.detectedAudioSizeBytes = 0
                        self.state = .failed(errMsg)
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            let tcStatus = avPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration else { return }
                switch tcStatus {
                case .playing:
                    self.state = .playing
                    self.updateNowPlayingInfo()
                case .waitingToPlayAtSpecifiedRate:
                    if case .playing = self.state {
                        self.state = .buffering
                    }
                case .paused:
                    switch self.state {
                    case .playing:
                        self.state = .paused
                        self.updateNowPlayingInfo()
                    case .buffering where self.isCurrentItemReady && !self.isSeeking:
                        self.state = .paused
                        self.updateNowPlayingInfo()
                    default:
                        break
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func schedulePrecache(generation: UInt64) {
        precacheTask?.cancel()
        guard AppSettingsStore.shared.precacheCount > 0 else { return }
        precacheTask = Task { [weak self] in
            var waited = 0
            while waited < 120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, generation == self.playbackGeneration else { return }
                if self.state == .playing, self.isCurrentItemReady, self.clock.currentTimeSec >= 8 { break }
                waited += 1
            }
            guard let self, !Task.isCancelled, generation == self.playbackGeneration, waited < 120 else { return }
            await self.precacheUpcomingChapters()
        }
    }

    private func precacheUpcomingChapters() async {
        let count = AppSettingsStore.shared.precacheCount
        guard count > 0, let book = currentBook, let current = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        DownloadManager.shared.dropQueuedPrecache()
        let endIdx = min(chapterQueue.count, idx + 1 + count)
        guard idx + 1 < endIdx else { return }
        let upcoming = Array(chapterQueue[(idx + 1)..<endIdx])
        DownloadManager.shared.enqueueChapters(upcoming, for: book, kind: "precache")
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = AppSettingsStore.shared.audioChannel == .spokenAudio ? .spokenAudio : .default
        try? session.setCategory(.playback, mode: mode, options: [])
        try? session.setActive(true)
    }

    /// 供通知协调扩展调用：系统媒体服务重置后重建会话与 AudioTap 状态
    func handleMediaServicesWereReset() {
        let shouldResume = (state == .playing)
        configureAudioSession()
        tapEvaluatedItemID = nil
        tapAttachedItemID = nil
        currentTapContext = nil
        applyEffectiveAudioSettings()
        if shouldResume {
            retryCurrentChapter()
        }
    }

    /// 供通知协调扩展调用：播到章尾失败时的本地回退与单次重试
    func handleItemFailedToPlayToEnd(errorMessage: String) async {
        let gen = playbackGeneration
        let resumeMs = max(0, Int(clock.currentTimeSec * 1000))
        if isPlayingLocalFile, let book = currentBook, let ch = currentChapter {
            DownloadManager.shared.invalidateLocalFile(bookID: book.id, chapterID: ch.id)
            bypassLocalChapterID = ch.id
            await loadAndPlay(chapter: ch, initialPositionMs: resumeMs, generation: gen, detachFirst: true)
        } else if !hasRetriedCurrentChapter, let ch = currentChapter {
            hasRetriedCurrentChapter = true
            if builtinParserResolved {
                await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: ch.url)
            }
            await loadAndPlay(chapter: ch, initialPositionMs: resumeMs, generation: gen, detachFirst: true)
        } else {
            detectedAudioBitrateKbps = nil
            detectedAudioSizeBytes = 0
            state = .failed(errorMessage)
        }
    }

    /// P-05：播放接近章尾时低优先级预热下一章解析缓存，切章时近零等待
    private func preResolveNextChapterIfNeeded() {
        guard let book = currentBook,
              let cur = currentChapter,
              let idx = chapterQueue.firstIndex(where: { $0.id == cur.id }),
              idx + 1 < chapterQueue.count else { return }
        let next = chapterQueue[idx + 1]
        // 下一章已有本地离线文件时跳过在线预解析
        if DownloadManager.shared.downloadState(bookID: book.id, chapterID: next.id) == .completed
            || DownloadManager.shared.localFileURL(bookID: book.id, chapterID: next.id) != nil {
            return
        }
        guard next.url != preResolvedNextChapterURL else { return }
        preResolvedNextChapterURL = next.url
        let sourceID = book.sourceID
        let nextURL = next.url
        let tier = currentBookAudioQualityTier
        let nextExpectedDuration: Double? = next.hintDurationSec > 0 ? next.hintDurationSec : nil
        Task.detached(priority: .utility) {
            _ = try? await PluginRuntime.shared.resolvePlayStream(
                sourceID: sourceID,
                episodeURL: nextURL,
                forDownload: false,
                tier: tier,
                expectedDurationSec: nextExpectedDuration
            )
        }
    }

    private func observePeriodicTime() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentItemReady,
                      self.pendingSeekSec == nil,
                      !self.isSeeking,
                      let item = self.player.currentItem,
                      item === self.loadedItem else { return }
                let sec = time.seconds
                guard sec.isFinite && sec >= 0 else { return }
                self.clock.currentTimeSec = sec

                let dur = item.duration.seconds
                if dur.isFinite && dur > 0 {
                    let durationChanged = abs(self.clock.durationSec - dur) > 1.0
                    self.clock.durationSec = dur
                    if durationChanged {
                        self.configureOutroBoundaryObserver(durationSec: dur)
                    }
                    // 按章定时最后 30 秒线性音量渐弱（同步缩放 mixGain）
                    self.updateChapterSleepFadeIfNeeded(currentSec: sec, durationSec: dur)

                    // P-05：章尾剩余 <= 60s 时后台低优先级预解析下一章直链，降低切章等待
                    if dur > 30, (dur - sec) <= 60 {
                        self.preResolveNextChapterIfNeeded()
                    }
                    // 兜底检查（精准触发由 addBoundaryTimeObserver 主导）
                    if self.skipCoordinator.shouldTriggerOutroSkip(positionSec: sec, durationSec: dur) {
                        self.triggerOutroSkip()
                        return
                    }
                }

                if let book = self.currentBook, let chapter = self.currentChapter {
                    ChapterProgressCache.shared.update(
                        bookID: book.id,
                        chapterID: chapter.id,
                        positionMs: max(0, Int(sec * 1000)),
                        durationMs: max(0, Int(self.clock.durationSec * 1000)),
                        forceFlush: false
                    )
                }

                if abs(sec - self.lastPersistedTime) >= 5.0 {
                    self.lastPersistedTime = sec
                    self.persistProgressNow()
                }
            }
        }
    }

    func handleChapterFinished() {
        sleepTimer.resetFadeMultiplier()
        if let book = currentBook, let finished = currentChapter {
            let durSec = clock.durationSec > 0 ? clock.durationSec : Double(finished.normalizedDurationSec ?? 0)
            let durMs = max(0, Int(durSec * 1000))
            ChapterProgressCache.shared.update(
                bookID: book.id,
                chapterID: finished.id,
                positionMs: durMs,
                durationMs: durMs,
                isFinished: true,
                forceFlush: true
            )
            DownloadManager.shared.cleanupPrecacheIfNeeded(bookID: book.id, chapterID: finished.id)
        }
        if handleSleepTimerChapterFinished() {
            return
        }
        playNextChapter()
    }

    // MARK: - SwiftData 进度与单书配置读写

    private func fetchBookPreferredAudioQualityRaw(for bookID: String) -> String? {
        if let ctx = modelContext {
            let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
            if let saved = try? ctx.fetch(descriptor).first {
                return saved.preferredAudioQualityRaw
            }
        }
        return LibraryStore.shared.book(for: bookID, fallbackContext: modelContext)?.preferredAudioQualityRaw
    }

    private func fetchDownloadItem(bookID: String, chapterID: String) -> DownloadItem? {
        guard let ctx = modelContext ?? DownloadManager.shared.modelContext else { return nil }
        let itemID = "\(bookID)::\(chapterID)"
        let descriptor = FetchDescriptor<DownloadItem>(predicate: #Predicate<DownloadItem> { $0.id == itemID })
        return try? ctx.fetch(descriptor).first
    }

    private func loadBookPreferences(for bookID: String) {
        let settings = AppSettingsStore.shared
        audioQualityTier = QualityPolicy.effectiveTier(
            bookOverrideRaw: fetchBookPreferredAudioQualityRaw(for: bookID),
            globalDefault: settings.audioQualityTier
        )
        audioEffectPreset = settings.audioEffectPreset
        customEQBandsDb = settings.customEQBandsDb
        audioBoostDB = settings.audioBoostDB
        audioBalance = settings.audioBalance

        guard let ctx = modelContext else {
            speed = settings.defaultSpeed
            skipCoordinator.config = .unset
            bookVolume = 1.0
            return
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            speed = saved.speed > 0 ? saved.speed : settings.defaultSpeed
            skipCoordinator.config = BookSkipConfig(
                enabled: saved.skipEnabled,
                introSec: saved.skipIntroSec,
                outroSec: saved.skipOutroSec
            ).normalized
            bookVolume = settings.rememberBookVolume ? min(max(saved.volume, 0.0), 2.0) : 1.0
        } else {
            speed = settings.defaultSpeed
            skipCoordinator.config = .unset
            bookVolume = 1.0
        }
    }

    func ensureBookRow(for book: BookRef, in ctx: ModelContext) -> Book {
        let bookID = book.id
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let existing = try? ctx.fetch(descriptor).first {
            return existing
        }
        let historyBook = Book(
            id: book.id,
            sourceID: book.sourceID,
            bookURL: book.bookURL,
            title: book.title,
            author: book.author,
            cover: book.cover,
            intro: book.intro,
            inShelf: false,
            addedAt: .now,
            totalChapters: chapterQueue.count,
            lastPlayedAt: .now,
            volume: bookVolume,
            skipEnabled: bookSkip.enabled,
            skipIntroSec: bookSkip.introSec,
            skipOutroSec: bookSkip.outroSec,
            speed: speed
        )
        ctx.insert(historyBook)
        return historyBook
    }

    func saveBookAudioSettings() {
        guard let ctx = modelContext, let book = currentBook else { return }
        let saved = ensureBookRow(for: book, in: ctx)
        saved.speed = speed
        saved.volume = bookVolume
        saved.skipEnabled = bookSkip.enabled
        saved.skipIntroSec = bookSkip.introSec
        saved.skipOutroSec = bookSkip.outroSec
        try? ctx.save()
    }

    func persistProgressNow(positionMsOverride: Int? = nil) {
        guard let ctx = modelContext, let book = currentBook, let chapter = currentChapter else { return }
        let bookID = book.id
        let posMs = positionMsOverride ?? max(0, Int(clock.currentTimeSec * 1000))
        let chapterIdx = (chapterQueue.firstIndex(where: { $0.id == chapter.id }).map { $0 + 1 }) ?? 0
        let totalChaps = chapterQueue.count
        ChapterProgressCache.shared.update(
            bookID: bookID,
            chapterID: chapter.id,
            positionMs: posMs,
            durationMs: Int(clock.durationSec * 1000),
            forceFlush: true
        )

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            saved.lastChapterID = chapter.id
            saved.lastChapterTitle = chapter.title
            if chapterIdx > 0 { saved.lastChapterIndex = chapterIdx }
            if totalChaps > 0 { saved.totalChapters = totalChaps }
            saved.lastPositionMs = posMs
            saved.lastPlayedAt = .now
            if !book.cover.isEmpty && saved.cover.isEmpty {
                saved.cover = book.cover
            }
            if !book.author.isEmpty && saved.author.isEmpty {
                saved.author = book.author
            }
            try? ctx.save()
        } else {
            let historyBook = Book(
                id: book.id,
                sourceID: book.sourceID,
                bookURL: book.bookURL,
                title: book.title,
                author: book.author,
                cover: book.cover,
                intro: book.intro,
                inShelf: false,
                addedAt: .now,
                lastChapterID: chapter.id,
                lastChapterTitle: chapter.title,
                lastChapterIndex: chapterIdx,
                totalChapters: totalChaps,
                lastPositionMs: posMs,
                lastPlayedAt: .now,
                volume: bookVolume,
                skipEnabled: bookSkip.enabled,
                skipIntroSec: bookSkip.introSec,
                skipOutroSec: bookSkip.outroSec,
                speed: speed
            )
            ctx.insert(historyBook)
            try? ctx.save()
        }
        saveChapterQueueIfNeeded(for: book.id)
    }

    private func saveChapterQueueIfNeeded(for bookID: String) {
        guard !chapterQueue.isEmpty else { return }
        let signature = "\(bookID)#\(chapterQueue.count)#\(chapterQueue.first?.id ?? "")#\(chapterQueue.last?.id ?? "")"
        guard signature != savedQueueSignature else { return }
        savedQueueSignature = signature
        let queue = chapterQueue
        Task.detached(priority: .utility) {
            ChapterCacheStore.saveChapters(queue, for: bookID)
        }
    }
}
