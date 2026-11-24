import AVFoundation
import DSCore
import DSPluginKit
import Foundation

private struct SendableAudioMixBox: @unchecked Sendable {
    let mix: AVMutableAudioMix?
}

private struct SendableAssetBox: @unchecked Sendable {
    let asset: AVAsset
}

/// 一次性超时竞速器（避开 Swift 6.0 withTaskGroup + @MainActor RBI 编译器缺陷，同时保证单次 resume 与取消清理）
private final class AudioMixTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SendableAudioMixBox?, Never>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var pendingResult: SendableAudioMixBox??

    func bindContinuation(_ continuation: CheckedContinuation<SendableAudioMixBox?, Never>) {
        let immediate: SendableAudioMixBox?? = lock.withLock {
            if finished {
                return pendingResult ?? .some(nil)
            }
            self.continuation = continuation
            return nil
        }
        if let immediate {
            continuation.resume(returning: immediate)
        }
    }

    func attachTasks(work: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel: Bool = lock.withLock {
            if finished { return true }
            self.workTask = work
            self.timeoutTask = timeout
            return false
        }
        if shouldCancel {
            work.cancel()
            timeout.cancel()
        }
    }

    func finish(_ value: SendableAudioMixBox?) {
        let snapshot: (CheckedContinuation<SendableAudioMixBox?, Never>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            guard !finished else { return (nil, nil, nil) }
            finished = true
            pendingResult = value
            let c = continuation
            let w = workTask
            let t = timeoutTask
            continuation = nil
            workTask = nil
            timeoutTask = nil
            return (c, w, t)
        }
        snapshot.1?.cancel()
        snapshot.2?.cancel()
        snapshot.0?.resume(returning: value)
    }
}

/// 播放章节加载与音轨解析流水线扩展（拆分自 PlaybackCoordinator 保持单文件 <= 385 行）
extension PlaybackCoordinator {
    private func buildAudioMixWithTimeout(
        for asset: AVAsset,
        timeoutNanoseconds: UInt64 = 1_500_000_000
    ) async -> AVMutableAudioMix? {
        let dsp = self.dsp
        let assetBox = SendableAssetBox(asset: asset)
        let race = AudioMixTimeoutRace()
        let box: SendableAudioMixBox? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.bindContinuation(continuation)
                let workTask = Task { @MainActor in
                    let mix = await dsp.buildAudioMix(for: assetBox.asset)
                    race.finish(SendableAudioMixBox(mix: mix))
                }
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    race.finish(nil)
                }
                race.attachTasks(work: workTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.finish(nil)
        }
        return box?.mix
    }

    func loadCurrentChapter(autoPlay: Bool, resumePositionOverrideMs: Int? = nil) {
        let shouldBypassCache: Bool = { if case .failed = state { return true }; return false }()
        loadTask?.cancel()
        loadTask = nil
        dsp.resetWatchdog()
        player.pause()
        activePlayerItem = nil
        player.replaceCurrentItem(with: nil)
        isSeeking = false
        seekGeneration &+= 1
        hasAttachedAudioMix = false
        observerBag.tearDownAll()

        guard let book = currentBook, let chapter = currentChapter else {
            pendingResumePositionMs = nil
            state = .idle
            return
        }

        pendingResumePositionMs = resumePositionOverrideMs.map { max(0, $0) }
        generationCounter &+= 1
        let gen = generationCounter
        state = .buffering(generation: gen, shouldPlayWhenReady: autoPlay)
        clock.reset()
        syncNowPlaying()

        loadTask = Task { [weak self] in
            guard let self else { return }
            self.bookSkipConfig = await self.progressStore.loadBookSkipConfig(bookID: book.id)
            let savedPositionMs: Int
            let savedFinished: Bool
            if let overrideMs = resumePositionOverrideMs {
                savedPositionMs = max(0, overrideMs)
                savedFinished = false
            } else {
                let saved = await self.progressStore.loadChapterProgress(bookID: book.id, chapterID: chapter.id)
                savedPositionMs = saved?.positionMs ?? 0
                savedFinished = saved?.isFinished ?? false
                self.pendingResumePositionMs = savedFinished ? 0 : savedPositionMs
            }
            guard !Task.isCancelled, gen == self.generationCounter else { return }

            do {
                let resolvedQuality = self.preferredQuality.resolved(isOnWiFi: self.isOnWiFi, allowUltraHigh: self.allowUltraHighQuality)
                let stream: AudioStreamDTO
                if let localURL = await self.offlineLocator?.localAudioURL(bookID: book.id, chapterID: chapter.id) {
                    stream = AudioStreamDTO(url: localURL, qualityTier: resolvedQuality, isHLS: false)
                } else {
                    stream = try await self.audioResolver.resolveAudio(
                        sourceID: book.sourceID,
                        bookID: book.id,
                        chapter: chapter,
                        preferredQuality: resolvedQuality,
                        forDownload: false,
                        bypassCache: shouldBypassCache
                    )
                }
                guard !Task.isCancelled, gen == self.generationCounter else { return }
                if stream.bitrateKbps == nil, let cachedTier = self.cachedProbedQuality(bookID: book.id, sourceID: book.sourceID) {
                    self.activeStream = AudioStreamDTO(
                        url: stream.url,
                        headers: stream.headers,
                        qualityTier: cachedTier,
                        bitrateKbps: nil,
                        isHLS: stream.isHLS,
                        isTrial: stream.isTrial,
                        isCappedFallback: stream.isCappedFallback,
                        mimeType: stream.mimeType,
                        resolvedAt: stream.resolvedAt
                    )
                } else {
                    self.activeStream = stream
                }

                let asset = AVURLAsset(url: stream.url, options: stream.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                let item = AVPlayerItem(asset: asset)
                let bufferTier = stream.qualityTier == .auto ? resolvedQuality : stream.qualityTier
                item.preferredForwardBufferDuration = Self.forwardBufferDuration(for: bufferTier, isOnWiFi: self.isOnWiFi)
                self.dsp.prepareForStream(
                    isHLS: stream.isHLS,
                    mimeType: stream.mimeType,
                    assetURL: stream.url,
                    deferWatchdogUntilPlaying: true,
                    onSyncVolume: { [weak self] in
                        guard let self else { return }
                        self.dsp.syncFadeVolume(to: self.player)
                    }
                ) { [weak self] in
                    guard let self else { return }
                    self.dsp.syncFadeVolume(to: self.player)
                }

                // 非 HLS 起播前直接挂载 MTAudioProcessingTap（原声态在音频回调内一行短路零开销），彻底避免中途挂 audioMix 静默不生效
                if !self.dsp.isUsingNativeVolumeFallback {
                    let audioMix = await self.buildAudioMixWithTimeout(for: asset)
                    guard !Task.isCancelled, gen == self.generationCounter else { return }
                    if let audioMix {
                        item.audioMix = audioMix
                        self.hasAttachedAudioMix = true
                    } else if !self.dsp.isUsingNativeVolumeFallback {
                        self.dsp.activateFallback(reason: "音轨混音不可用，降级原生音量")
                        self.dsp.syncFadeVolume(to: self.player)
                    }
                } else {
                    self.dsp.syncFadeVolume(to: self.player)
                }

                if self.state.shouldPlayWhenReady {
                    self.remoteController.configureAudioSession()
                }
                self.activePlayerItem = item
                // 先挂观测再 replaceCurrentItem，配合 [.initial, .new] 确保本地 file:// 极速就绪 100% 触发起播
                self.attachItemObservers(item: item, generation: gen, savedPositionMs: savedPositionMs, savedFinished: savedFinished)
                self.player.replaceCurrentItem(with: item)
                if stream.bitrateKbps == nil || stream.url.isFileURL || stream.qualityTier == .auto {
                    self.probeActualAudioQualityIfNeeded(asset: asset, stream: stream, generation: gen)
                }

                let nextStart = self.currentChapterIndex + 1
                var upcoming: [ChapterDTO] = []
                if !stream.url.isFileURL {
                    upcoming.append(chapter)
                }
                if nextStart < self.chapters.count {
                    upcoming.append(contentsOf: self.chapters[nextStart..<min(self.chapters.count, nextStart + 5)])
                }
                let precacheList = upcoming
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, gen == self.generationCounter, self.state.isPlaying else { return }
                    self.onRequestPrecache?(book, precacheList)
                }
            } catch {
                guard !Task.isCancelled, gen == self.generationCounter else { return }
                self.activePlayerItem = nil
                self.player.replaceCurrentItem(with: nil)
                self.state = .failed(generation: gen, message: error.localizedDescription)
                await self.logger.record(category: .playback, level: "ERROR", message: "播放解析失败：\(error.localizedDescription)")
            }
        }
    }

    /// 播放中途开启听书音效/响度增强/防爆音均衡时，立即为当前 AVPlayerItem 动态挂载 MTAudioProcessingTap，无需等到下一章
    func attachAudioMixIfNeededForActiveItem() {
        guard let item = activePlayerItem,
              !hasAttachedAudioMix,
              !dsp.isUsingNativeVolumeFallback,
              dsp.currentParameters().needsProcessing else {
            return
        }
        let gen = generationCounter
        hasAttachedAudioMix = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let audioMix = await self.buildAudioMixWithTimeout(for: item.asset)
            guard self.generationCounter == gen, self.activePlayerItem === item else { return }
            if let audioMix {
                item.audioMix = audioMix
                self.triggerWatchdogIfReady()
            } else {
                self.hasAttachedAudioMix = false
                if !self.dsp.isUsingNativeVolumeFallback {
                    self.dsp.activateFallback(reason: "音轨混音不可用，降级原生音量")
                    self.dsp.syncFadeVolume(to: self.player)
                }
            }
        }
    }

    /// 异步探测音轨真实码率，为非喜马拉雅书源与本地离线文件精准映射「超清 / 高清 / 标准」档位
    private func probeActualAudioQualityIfNeeded(asset: AVURLAsset, stream: AudioStreamDTO, generation: UInt64) {
        let assetBox = SendableAssetBox(asset: asset)
        Task { @MainActor [weak self] in
            guard let kbps = await Self.probeBitrateKbps(assetBox: assetBox), kbps > 0 else { return }
            guard let self, self.generationCounter == generation, self.activeStream?.url == stream.url else { return }
            let detectedTier = AudioQualityTier.fromBitrateKbps(kbps)
            if let activeBook = self.currentBook {
                self.probedQualityCache["b:\(activeBook.id)"] = detectedTier
                self.probedQualityCache["s:\(activeBook.sourceID)"] = detectedTier
            }
            self.activeStream = AudioStreamDTO(
                url: stream.url,
                headers: stream.headers,
                qualityTier: detectedTier,
                bitrateKbps: kbps,
                isHLS: stream.isHLS,
                isTrial: stream.isTrial,
                isCappedFallback: stream.isCappedFallback,
                mimeType: stream.mimeType,
                resolvedAt: stream.resolvedAt
            )
        }
    }

    nonisolated private static func probeBitrateKbps(assetBox: SendableAssetBox) async -> Int? {
        guard let tracks = try? await assetBox.asset.loadTracks(withMediaType: .audio),
              let firstTrack = tracks.first,
              let dataRate = try? await firstTrack.load(.estimatedDataRate),
              dataRate.isFinite, dataRate > 0 else { return nil }
        return Int((dataRate / 1000.0).rounded())
    }

    /// 冷启动恢复会话后静默预热音频直链与 AVPlayerItem（保持暂停态绝不自动出声，点按播放即刻出声）
    public func prewarmRestoredSessionIfNeeded() {
        guard case .paused = state,
              activePlayerItem == nil,
              loadTask == nil,
              currentBook != nil,
              currentChapter != nil else { return }
        loadCurrentChapter(autoPlay: false, resumePositionOverrideMs: pendingResumePositionMs)
    }

    public func cachedProbedQuality(bookID: String, sourceID: String) -> AudioQualityTier? {
        probedQualityCache["b:\(bookID)"] ?? probedQualityCache["s:\(sourceID)"]
    }

    var isFailedOrIdleState: Bool {
        switch state {
        case .idle, .failed: return true
        case .buffering, .playing, .paused, .ended: return false
        }
    }
}
