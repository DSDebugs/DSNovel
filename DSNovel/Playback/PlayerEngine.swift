import Foundation
import Observation
import AVFoundation
import MediaPlayer
import SwiftData
import UIKit

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

enum SleepTimerOption: Equatable {
    case off
    case minutes(Int)
    case endOfChapter
    case chaptersRemaining(Int)

    var label: String {
        switch self {
        case .off: return "定时关闭"
        case .minutes(let m): return "\(m) 分钟"
        case .endOfChapter: return "本章结束"
        case .chaptersRemaining(let c): return "\(c) 章后"
        }
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

/// 播放引擎：
/// - 原生 AVURLAsset 自定义请求头 + HLS/MP3/M4A 播放
/// - KVO 实时监听 status / timeControlStatus / loadedTimeRanges（缓冲进度）
/// - 五档音质切换（联动 BuiltinParserRuntime）、六种音效预设、5 段人声 EQ 与 0–200% 响度增强
/// - 动态倍速折算睡眠定时、锁屏封面与章节序号、音频中断自动续播与耳机拔出保护
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

@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    let clock = PlaybackClock()
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

    private(set) var bookSkip: BookSkipConfig = .unset
    var skipIntroSec: Int { bookSkip.effectiveIntroSec }
    var skipOutroSec: Int { bookSkip.effectiveOutroSec }
    private(set) var inlineFeedback: PlayerInlineFeedback?
    @ObservationIgnored private var inlineFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var outroTriggeredForCurrentChapter: Bool = false
    @ObservationIgnored private var outroSuppressedForCurrentChapter: Bool = false

    // 音质与音效状态（§3.2）
    private(set) var audioQualityTier: AudioQualityTier = AppSettingsStore.shared.audioQualityTier
    private(set) var audioEffectPreset: AudioEffectPreset = AppSettingsStore.shared.audioEffectPreset
    private(set) var customEQBandsDb: [Double] = AppSettingsStore.shared.customEQBandsDb
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
        }
    }

    var activeEQBandsDb: [Double] {
        audioEffectPreset == .custom ? customEQBandsDb : audioEffectPreset.defaultBandsDb
    }

    // 睡眠定时器状态
    var sleepOption: SleepTimerOption = .off
    private(set) var sleepRemainingSec: Int = 0
    private var sleepChaptersLeft: Int = 0
    private var sleepTimerTask: Task<Void, Never>?

    var isMiniPlayerVisible: Bool {
        currentBook != nil && currentChapter != nil
    }

    var currentBookID: String? {
        currentBook?.id
    }

    private(set) var bufferedRange: Double = 0
    private(set) var isPlayingLocalFile: Bool = false
    private(set) var detectedAudioBitrateKbps: Int?
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
        if book.sourceID == "6e2b9c4d8a1f4d37b5c0e73a9f1d2b64" {
            return .multiBitrate
        }
        if book.sourceID == "fanqie_changting_pro_v56",
           let url = currentChapter?.url,
           url.hasPrefix("fq://xmly_track/") || url.hasPrefix("fq://free_xmly/") {
            return .multiBitrate
        }
        return .fixedSingleBitrate
    }

    /// 顶栏音质徽标文案（统一展示当前播放音频的实际音质，不再显示「音源原画」或「本地离线」）
    var streamStatusBadgeText: String {
        switch currentAudioQualitySupportMode {
        case .multiBitrate:
            return audioQualityTier.effectiveBadgeText(isOnWiFi: DownloadManager.shared.isOnWiFi)
        case .fixedSingleBitrate, .localOffline:
            if let kbps = detectedAudioBitrateKbps, kbps > 0 {
                return AudioQualityTier.badgeText(forDetectedBitrateKbps: kbps)
            }
            return audioQualityTier.effectiveBadgeText(isOnWiFi: DownloadManager.shared.isOnWiFi)
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
           DownloadManager.shared.localFileURL(bookID: book.id, chapterID: nextCh.id) != nil {
            return .availableDownloaded(nextCh)
        }
        return .availableOnline(nextCh)
    }

    /// 动态预估睡眠定时剩余秒数（修复 ISS-12：在选择“本章结束”或“N 章后”时按当前倍速动态折算）
    var estimatedSleepRemainingSec: Int {
        Self.estimateSleepSeconds(
            option: sleepOption,
            countdownSec: sleepRemainingSec,
            currentTimeSec: clock.currentTimeSec,
            durationSec: clock.durationSec,
            chapterQueue: chapterQueue,
            currentChapterID: currentChapter?.id,
            chaptersLeft: sleepChaptersLeft,
            speed: speed
        )
    }

    nonisolated static func estimateSleepSeconds(
        option: SleepTimerOption,
        countdownSec: Int,
        currentTimeSec: Double,
        durationSec: Double,
        chapterQueue: [ChapterDTO] = [],
        currentChapterID: String? = nil,
        chaptersLeft: Int = 1,
        speed: Double
    ) -> Int {
        let safeSpeed = max(0.5, speed)
        switch option {
        case .off:
            return 0
        case .minutes(let mins):
            return countdownSec > 0 ? countdownSec : mins * 60
        case .endOfChapter:
            let effDur = durationSec > 0 ? durationSec : 600.0
            let remRaw = max(0.0, effDur - max(0.0, currentTimeSec))
            return Int((remRaw / safeSpeed).rounded())
        case .chaptersRemaining(let configuredCount):
            let effDur = durationSec > 0 ? durationSec : 600.0
            var totalRawSec = max(0.0, effDur - max(0.0, currentTimeSec))
            let extraChapters = max(0, (chaptersLeft > 0 ? chaptersLeft : configuredCount) - 1)
            if extraChapters > 0 {
                if let currentChapterID,
                   let curIdx = chapterQueue.firstIndex(where: { $0.id == currentChapterID }) {
                    let endIdx = min(chapterQueue.count, curIdx + 1 + extraChapters)
                    if curIdx + 1 < endIdx {
                        for i in (curIdx + 1)..<endIdx {
                            let hint = chapterQueue[i].hintDurationSec
                            totalRawSec += (hint > 0 ? hint : 600.0)
                        }
                    } else {
                        totalRawSec += Double(extraChapters) * (effDur > 0 ? effDur : 600.0)
                    }
                } else {
                    totalRawSec += Double(extraChapters) * (effDur > 0 ? effDur : 600.0)
                }
            }
            return Int((totalRawSec / safeSpeed).rounded())
        }
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

    func setAudioQualityTier(_ tier: AudioQualityTier, reloadCurrent: Bool = false) {
        let normalized = tier.normalizedForSelection
        audioQualityTier = normalized
        AppSettingsStore.shared.audioQualityTier = normalized
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = normalized.preferredForwardBufferDuration
        }
        let shouldReload = reloadCurrent && currentAudioQualitySupportMode == .multiBitrate
        let code = normalized.parserQualityCode(isOnWiFi: DownloadManager.shared.isOnWiFi)
        Task {
            let parsers = await BuiltinParserRuntime.shared.installedParsers()
            for p in parsers {
                await BuiltinParserRuntime.shared.setConfigValue(parserID: p.id, key: "quality", value: code)
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

    func syncGlobalAudioPreferencesFromSettings() {
        let settings = AppSettingsStore.shared
        audioQualityTier = settings.audioQualityTier.normalizedForSelection
        audioEffectPreset = settings.audioEffectPreset
        customEQBandsDb = settings.customEQBandsDb
        audioBoostDB = settings.audioBoostDB
        audioBalance = settings.audioBalance
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = audioQualityTier.preferredForwardBufferDuration
        }
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

    func undoIntroSkipForCurrentChapter() {
        inlineFeedbackTask?.cancel()
        inlineFeedback = nil
        seek(to: 0)
    }

    @discardableResult
    func updateBookSkip(_ newConfig: BookSkipConfig) -> Bool {
        let normalized = newConfig.normalized
        let previous = bookSkip
        bookSkip = normalized

        // 若当前播放位置已落入新设片尾区间，对当前章抑制自动跳过，避免刚调大就立刻切章（B7④）
        let dur = clock.durationSec
        let pos = clock.currentTimeSec
        let outro = Double(normalized.effectiveOutroSec)
        if outro > 0, dur.isFinite, dur > 0, pos >= dur - outro {
            outroSuppressedForCurrentChapter = true
        }

        guard let ctx = modelContext, let book = currentBook else {
            return true
        }
        do {
            let saved = ensureBookRow(for: book, in: ctx)
            saved.skipEnabled = normalized.enabled
            saved.skipIntroSec = normalized.introSec
            saved.skipOutroSec = normalized.outroSec
            try ctx.save()
            return true
        } catch {
            bookSkip = previous
            showInlineToast("保存失败", durationSec: 3.0)
            return false
        }
    }

    func updateCustomEQBand(index: Int, gainDb: Double) {
        guard (0..<5).contains(index) else { return }
        var bands = customEQBandsDb.count == 5 ? customEQBandsDb : [0.0, 0.0, 0.0, 0.0, 0.0]
        bands[index] = min(max(gainDb, -12.0), 12.0)
        customEQBandsDb = bands
        AppSettingsStore.shared.customEQBandsDb = bands
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

    private func applyEffectiveAudioSettings() {
        let effective = PlayerAudioPipeline.computeEffectiveVolume(
            bookVolume: bookVolume,
            preset: audioEffectPreset,
            eqBandsDb: activeEQBandsDb,
            boostDB: audioBoostDB
        )
        player.volume = effective.playerVolume
        guard let item = player.currentItem else { return }
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
        if effective.isBoosted {
            let asset = item.asset
            let targetGain = effective.mixGain
            Task { @MainActor [weak item] in
                if let mix = await PlayerAudioPipeline.makeAudioMixIfNeeded(for: asset, mixGain: targetGain) {
                    item?.audioMix = mix
                }
            }
        } else {
            item.audioMix = nil
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
        loadBookPreferences(for: book.id)
        let startSec = max(0, Double(positionMs) / 1000.0)
        detachCurrentItem(startSec: startSec)
        state = .paused
        clock.currentTimeSec = startSec
        clock.durationSec = max(chapter.hintDurationSec, startSec > 0 ? startSec + 60 : 600)
        updateRemoteCommandStates()
        updateNowPlayingInfo()
    }

    private let player = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var failedEndObserverToken: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0
    private var pendingSeekSec: Double?
    private var lastPersistedTime: TimeInterval = 0
    private var hasRetriedCurrentChapter = false
    private var wasPlayingBeforeInterruption = false
    /// 当前 AVPlayerItem 是否已 readyToPlay 且属于「当前章节」。
    private var isCurrentItemReady = false
    /// 当前章节对应的 AVPlayerItem，用于周期观察者校验时间来源
    private var loadedItem: AVPlayerItem?
    /// 章节列表缓存签名：同一本书、同一份章节队列只落盘一次
    private var savedQueueSignature: String?
    private var precacheTask: Task<Void, Never>?
    /// 当前章节正在播放本地文件但文件损坏时，强制改走在线流
    private var bypassLocalChapterID: String?
    /// 当前章节地址是否由「内置解析」给出（用于直链过期后的强制重解析）
    private var builtinParserResolved = false
    var modelContext: ModelContext?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configureRemoteCommands()
        observePeriodicTime()
        observeNotifications()
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

        loadBookPreferences(for: book.id)
        let startSec = BookSkipConfig.startPositionSec(
            initialPositionMs: initialPositionMs,
            duration: startChapter.hintDurationSec,
            config: bookSkip
        )
        detachCurrentItem(startSec: startSec)
        if initialPositionMs <= 0 && startSec > 0 {
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
            await loadAndPlay(chapter: startChapter, initialPositionMs: initialPositionMs, generation: gen)
        }
    }

    /// 摘除当前播放项并重置所有与「旧音频」相关的状态
    private func detachCurrentItem(startSec: Double) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedItem = nil
        isCurrentItemReady = false
        isPlayingLocalFile = false
        detectedAudioBitrateKbps = nil
        outroTriggeredForCurrentChapter = false
        outroSuppressedForCurrentChapter = false
        bufferedRange = 0
        pendingSeekSec = startSec > 0.5 ? startSec : nil
        lastPersistedTime = startSec
        state = .buffering
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused, .idle:
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
        case .failed:
            retryCurrentChapter()
        case .buffering:
            pause()
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
        detachCurrentItem(startSec: Double(resumeMs) / 1000.0)
        loadTask = Task {
            await loadAndPlay(chapter: ch, initialPositionMs: resumeMs, generation: gen)
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
        player.playImmediately(atRate: Float(speed))
        state = .playing
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        let dur = clock.durationSec
        let outro = Double(bookSkip.effectiveOutroSec)
        if outro > 0, dur.isFinite, dur > 0, clamped >= dur - outro {
            outroSuppressedForCurrentChapter = true
        }
        clock.currentTimeSec = clamped
        guard isCurrentItemReady, let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeekSec = clamped
            persistProgressNow(positionMsOverride: Int(clamped * 1000))
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
        let startSec = BookSkipConfig.startPositionSec(
            initialPositionMs: 0,
            duration: nextCh.hintDurationSec,
            config: bookSkip
        )
        detachCurrentItem(startSec: startSec)
        if startSec > 0 {
            showInlineToast("已跳过片头 \(Int(startSec.rounded())) 秒", canUndoIntroSkip: true, durationSec: 4.0)
        }
        clock.currentTimeSec = startSec
        clock.durationSec = nextCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, Int(startSec * 1000)))
        updateRemoteCommandStates()

        loadTask = Task {
            await loadAndPlay(chapter: nextCh, initialPositionMs: 0, generation: gen)
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
        let startSec = BookSkipConfig.startPositionSec(
            initialPositionMs: 0,
            duration: prevCh.hintDurationSec,
            config: bookSkip
        )
        detachCurrentItem(startSec: startSec)
        if startSec > 0 {
            showInlineToast("已跳过片头 \(Int(startSec.rounded())) 秒", canUndoIntroSkip: true, durationSec: 4.0)
        }
        clock.currentTimeSec = startSec
        clock.durationSec = prevCh.hintDurationSec
        persistProgressNow(positionMsOverride: max(0, Int(startSec * 1000)))
        updateRemoteCommandStates()

        loadTask = Task {
            await loadAndPlay(chapter: prevCh, initialPositionMs: 0, generation: gen)
        }
    }

    // MARK: - 睡眠定时器与最后 30 秒线性音量渐弱（4.3 节）

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimerTask?.cancel()
        sleepOption = option
        applyEffectiveAudioSettings()

        switch option {
        case .off:
            sleepRemainingSec = 0
            sleepChaptersLeft = 0
        case .minutes(let mins):
            sleepRemainingSec = mins * 60
            startCountdownTimer()
        case .endOfChapter:
            sleepRemainingSec = 0
            sleepChaptersLeft = 1
        case .chaptersRemaining(let count):
            sleepRemainingSec = 0
            sleepChaptersLeft = max(1, count)
        }
    }

    /// 快捷延长睡眠定时（修复 ISS-12：一键 +15 分钟续时）
    func extendSleepTimer(byMinutes extraMinutes: Int = 15) {
        let addSec = max(1, extraMinutes) * 60
        switch sleepOption {
        case .off:
            setSleepTimer(.minutes(extraMinutes))
        case .minutes:
            sleepRemainingSec += addSec
        case .endOfChapter, .chaptersRemaining:
            let baseSec = estimatedSleepRemainingSec
            sleepTimerTask?.cancel()
            sleepChaptersLeft = 0
            sleepRemainingSec = baseSec + addSec
            let totalMins = max(1, Int((Double(sleepRemainingSec) / 60.0).rounded()))
            sleepOption = .minutes(totalMins)
            startCountdownTimer()
        }
    }

    /// 计算最后 30 秒线性渐弱音量（供单元测试与定时器共用）
    nonisolated static func computeFadeVolume(baseVolume: Double, remainingSeconds: Int, fadeEnabled: Bool) -> Float {
        guard fadeEnabled, remainingSeconds > 0, remainingSeconds <= 30 else {
            return Float(min(max(baseVolume, 0), 1.0))
        }
        let ratio = Double(remainingSeconds) / 30.0
        return Float(min(max(baseVolume * ratio, 0), 1.0))
    }

    private func startCountdownTimer() {
        sleepTimerTask = Task {
            while !Task.isCancelled && sleepRemainingSec > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if state == .playing {
                    sleepRemainingSec -= 1
                    let fadeOn = AppSettingsStore.shared.sleepFadeOutEnabled
                    let effective = PlayerAudioPipeline.computeEffectiveVolume(
                        bookVolume: bookVolume,
                        preset: audioEffectPreset,
                        eqBandsDb: activeEQBandsDb,
                        boostDB: audioBoostDB
                    )
                    player.volume = Self.computeFadeVolume(
                        baseVolume: Double(effective.playerVolume),
                        remainingSeconds: sleepRemainingSec,
                        fadeEnabled: fadeOn
                    )
                    if sleepRemainingSec <= 0 {
                        pause()
                        applyEffectiveAudioSettings()
                        sleepOption = .off
                        break
                    }
                }
            }
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

    private func loadAndPlay(chapter: ChapterDTO, initialPositionMs: Int, generation: UInt64) async {
        guard let book = currentBook, generation == playbackGeneration else { return }
        let startSec = BookSkipConfig.startPositionSec(
            initialPositionMs: initialPositionMs,
            duration: chapter.hintDurationSec,
            config: bookSkip
        )
        detachCurrentItem(startSec: startSec)

        state = .buffering
        lastPluginError = nil
        clock.currentTimeSec = startSec
        clock.durationSec = chapter.hintDurationSec
        configureAudioSession()

        do {
            let playURL: URL
            var headers: [String: String] = [:]
            var streamKind: StreamKind = .onDemand

            var usingLocal = false
            if bypassLocalChapterID != chapter.id,
               let localURL = DownloadManager.shared.localFileURL(bookID: book.id, chapterID: chapter.id) {
                playURL = localURL
                usingLocal = true
                bufferedRange = 1.0
            } else {
                let qualityCode = audioQualityTier.parserQualityCode(isOnWiFi: DownloadManager.shared.isOnWiFi)
                let parsers = await BuiltinParserRuntime.shared.installedParsers()
                for p in parsers {
                    await BuiltinParserRuntime.shared.setConfigValue(parserID: p.id, key: "quality", value: qualityCode)
                }
                let stream = try await PluginRuntime.shared.resolvePlayStream(sourceID: book.sourceID, episodeURL: chapter.url)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                guard let remote = JsHostBridge.makeRequestURL(from: stream.url, relativeTo: chapter.url) else {
                    throw PluginError.parseFailed("无效的音频 URL")
                }
                playURL = remote
                headers = stream.headers
                streamKind = stream.kind
                builtinParserResolved = stream.resolvedBy == BuiltinParserRuntime.resolverTag
            }

            guard !Task.isCancelled, generation == playbackGeneration else { return }

            let asset = Self.makeStreamAsset(url: playURL, headers: headers, kind: streamKind)
            let item = AVPlayerItem(asset: asset)

            loadedItem = item
            isPlayingLocalFile = usingLocal
            detectedAudioBitrateKbps = nil
            observePlayerItem(item, chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            player.replaceCurrentItem(with: item)
            applyEffectiveAudioSettings()

            if pendingSeekSec == nil {
                player.playImmediately(atRate: Float(speed))
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
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            } else {
                state = .failed(pErr.localizedDescription)
            }
        } catch {
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            if !hasRetriedCurrentChapter {
                hasRetriedCurrentChapter = true
                await loadAndPlay(chapter: chapter, initialPositionMs: initialPositionMs, generation: generation)
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 异步读取当前 AVPlayerItem 音轨实际码率（支持固定单码率流与本地离线音频）
    private func inspectActualAudioBitrate(for item: AVPlayerItem, generation: UInt64) {
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
                } else if lastEvent.observedBitrate.isFinite && lastEvent.observedBitrate > 0 {
                    measuredBps = lastEvent.observedBitrate
                }
            }
            let kbps = Int((measuredBps / 1000.0).rounded())
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
                    }
                    self.applyEffectiveAudioSettings()
                    self.inspectActualAudioBitrate(for: loaded, generation: generation)
                    self.schedulePrecache(generation: generation)
                    if let seekSec = self.pendingSeekSec, seekSec > 0 {
                        self.clock.currentTimeSec = seekSec
                        let target = CMTime(seconds: seekSec, preferredTimescale: 600)
                        self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self, generation == self.playbackGeneration else { return }
                                self.pendingSeekSec = nil
                                self.lastPersistedTime = seekSec
                                self.configureAudioSession()
                                self.applyEffectiveAudioSettings()
                                self.player.playImmediately(atRate: Float(self.speed))
                                self.state = .playing
                                self.persistProgressNow(positionMsOverride: Int(seekSec * 1000))
                                self.updateNowPlayingInfo()
                            }
                        }
                    } else {
                        self.pendingSeekSec = nil
                        self.configureAudioSession()
                        self.applyEffectiveAudioSettings()
                        self.player.playImmediately(atRate: Float(self.speed))
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
                            generation: generation
                        )
                    } else if !self.hasRetriedCurrentChapter {
                        self.hasRetriedCurrentChapter = true
                        if self.builtinParserResolved {
                            await BuiltinParserRuntime.shared.invalidateCache(parserID: nil, episodeURL: chapter.url)
                        }
                        await self.loadAndPlay(
                            chapter: chapter,
                            initialPositionMs: initialPositionMs,
                            generation: generation
                        )
                    } else {
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
                    if case .playing = self.state {
                        self.state = .paused
                        self.updateNowPlayingInfo()
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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = AppSettingsStore.shared.audioChannel == .spokenAudio ? .spokenAudio : .default
        try? session.setCategory(.playback, mode: mode, options: [])
        try? session.setActive(true)
    }

    private func observePeriodicTime() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentItemReady, self.pendingSeekSec == nil,
                      let item = self.player.currentItem, item === self.loadedItem else { return }
                let sec = time.seconds
                guard sec.isFinite && sec >= 0 else { return }
                self.clock.currentTimeSec = sec

                let dur = item.duration.seconds
                if dur.isFinite && dur > 0 {
                    self.clock.durationSec = dur
                    if BookSkipConfig.shouldTriggerOutroSkip(
                        positionSec: sec,
                        durationSec: dur,
                        config: self.bookSkip,
                        hasTriggered: self.outroTriggeredForCurrentChapter,
                        isSuppressed: self.outroSuppressedForCurrentChapter
                    ) {
                        self.outroTriggeredForCurrentChapter = true
                        if self.nextChapterAvailability == .none {
                            self.showInlineToast("已是最后一章", durationSec: 3.0)
                        } else {
                            self.showInlineToast("已跳过片尾，正在播放下一章", durationSec: 3.0)
                        }
                        self.handleChapterFinished()
                        return
                    }
                }

                // 1s 节流刷新锁屏、灵动岛与内存章节进度缓存
                self.updateNowPlayingInfo()
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

    private func observeNotifications() {
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let finishedID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      finishedID == ObjectIdentifier(currentItem) else { return }
                self.handleChapterFinished()
            }
        }

        failedEndObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let failedID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断"
            Task { @MainActor [weak self] in
                guard let self,
                      let currentItem = self.player.currentItem,
                      failedID == ObjectIdentifier(currentItem) else { return }
                self.state = .failed(err)
            }
        }

        // 修复 ISS-10：处理音频中断开始与结束（支持来电/闹钟结束后根据 shouldResume 自动续播）
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            let optionsVal = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsVal)
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = (self.state == .playing)
                    self.pause()
                case .ended:
                    if self.wasPlayingBeforeInterruption && options.contains(.shouldResume) {
                        self.wasPlayingBeforeInterruption = false
                        self.resume()
                    }
                @unknown default:
                    break
                }
            }
        }

        // 修复 ISS-10：监听耳机/蓝牙外设断开（oldDeviceUnavailable），自动暂停并落盘进度防止外放惊扰
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing else { return }
                self.pause()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistProgressNow()
            }
        }
    }

    private func handleChapterFinished() {
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
        if sleepOption == .endOfChapter {
            pause()
            sleepOption = .off
            return
        }
        if case .chaptersRemaining = sleepOption {
            sleepChaptersLeft -= 1
            if sleepChaptersLeft <= 0 {
                pause()
                sleepOption = .off
                return
            }
        }
        playNextChapter()
    }

    // MARK: - SwiftData 进度与单书配置读写

    private func loadBookPreferences(for bookID: String) {
        let settings = AppSettingsStore.shared
        audioQualityTier = settings.audioQualityTier.normalizedForSelection
        audioEffectPreset = settings.audioEffectPreset
        customEQBandsDb = settings.customEQBandsDb
        audioBoostDB = settings.audioBoostDB
        audioBalance = settings.audioBalance

        guard let ctx = modelContext else {
            speed = settings.defaultSpeed
            bookSkip = .unset
            bookVolume = 1.0
            return
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        if let saved = try? ctx.fetch(descriptor).first {
            speed = saved.speed > 0 ? saved.speed : settings.defaultSpeed
            bookSkip = BookSkipConfig(
                enabled: saved.skipEnabled,
                introSec: saved.skipIntroSec,
                outroSec: saved.skipOutroSec
            ).normalized
            bookVolume = settings.rememberBookVolume ? min(max(saved.volume, 0.0), 2.0) : 1.0
        } else {
            speed = settings.defaultSpeed
            bookSkip = .unset
            bookVolume = 1.0
        }
    }

    private func ensureBookRow(for book: BookRef, in ctx: ModelContext) -> Book {
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

    // MARK: - 锁屏与控制中心（MPNowPlayingInfoCenter & MPRemoteCommandCenter）

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPreviousChapter() }
            return .success
        }
        // 禁用快进/快退 15s/30s 命令，确保灵动岛、锁屏界面与控制中心优先展示「上一章 / 下一章」切换按钮
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let targetTime = posEvent.positionTime
            Task { @MainActor in self?.seek(to: targetTime) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let targetRate = Double(rateEvent.playbackRate)
            Task { @MainActor in self?.setSpeed(targetRate, persist: true) }
            return .success
        }
    }

    private func updateRemoteCommandStates() {
        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = canPlayPreviousChapter
        center.nextTrackCommand.isEnabled = (nextChapterAvailability != .none)
    }

    private func updateNowPlayingInfo() {
        NowPlayingController.shared.update(
            book: currentBook,
            chapter: currentChapter,
            chapterIndexOneBased: currentChapterOneBasedIndex,
            totalChapters: chapterQueue.count,
            elapsedSec: clock.currentTimeSec,
            durationSec: clock.durationSec,
            isPlaying: state == .playing,
            speed: speed
        )
    }
}
