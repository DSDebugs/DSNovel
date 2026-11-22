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

/// 播放章节加载与音轨解析流水线扩展（拆分自 PlaybackCoordinator 保持单文件 <= 385 行）
extension PlaybackCoordinator {
    private func buildAudioMixWithTimeout(
        for asset: AVAsset,
        timeoutNanoseconds: UInt64 = 1_500_000_000
    ) async -> AVMutableAudioMix? {
        let dsp = self.dsp
        let assetBox = SendableAssetBox(asset: asset)
        let box = await withTaskGroup(of: SendableAudioMixBox?.self) { group in
            group.addTask { @MainActor in
                let mix = await dsp.buildAudioMix(for: assetBox.asset)
                return SendableAudioMixBox(mix: mix)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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

                // 非 HLS 流先构建并挂载 audioMix（1.5s 超时兜底不阻塞主起播），避免起播后中途替换引发瞬断或 Tap 丢帧
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
                }

                if autoPlay {
                    self.remoteController.configureAudioSession()
                }
                self.activePlayerItem = item
                // 先挂观测再 replaceCurrentItem，配合 [.initial, .new] 确保本地 file:// 极速就绪 100% 触发起播
                self.attachItemObservers(item: item, generation: gen, savedPositionMs: savedPositionMs, savedFinished: savedFinished)
                self.player.replaceCurrentItem(with: item)

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
