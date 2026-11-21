import AVFoundation
import DSCore
import DSPluginKit
import Foundation

/// 播放章节加载与音轨解析流水线扩展（拆分自 PlaybackCoordinator 保持单文件 <= 385 行）
extension PlaybackCoordinator {
    func loadCurrentChapter(autoPlay: Bool, resumePositionOverrideMs: Int? = nil) {
        let shouldBypassCache: Bool = { if case .failed = state { return true }; return false }()
        loadTask?.cancel()
        loadTask = nil
        audioMixTask?.cancel()
        audioMixTask = nil
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
                self.activeStream = stream

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
                if autoPlay {
                    self.remoteController.configureAudioSession()
                }
                self.activePlayerItem = item
                self.player.replaceCurrentItem(with: item)
                self.attachItemObservers(item: item, generation: gen, savedPositionMs: savedPositionMs, savedFinished: savedFinished)
                self.audioMixTask?.cancel()
                self.audioMixTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled, gen == self.generationCounter, let currentItem = self.activePlayerItem else { return }
                    let audioMix = await self.dsp.buildAudioMix(for: currentItem.asset)
                    guard !Task.isCancelled, gen == self.generationCounter, self.activePlayerItem === currentItem else { return }
                    guard let audioMix else {
                        if !self.dsp.isUsingNativeVolumeFallback {
                            self.dsp.activateFallback(reason: "音轨混音不可用，降级原生音量")
                            self.dsp.syncFadeVolume(to: self.player)
                        }
                        return
                    }
                    currentItem.audioMix = audioMix
                    self.hasAttachedAudioMix = true
                    self.triggerWatchdogIfReady()
                }

                let nextStart = self.currentChapterIndex + 1
                if nextStart < self.chapters.count {
                    self.onRequestPrecache?(book, Array(self.chapters[nextStart...]))
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
}
