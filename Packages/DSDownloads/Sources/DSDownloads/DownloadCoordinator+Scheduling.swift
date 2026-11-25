import AVFoundation
import DSCore
import DSPluginKit
import Foundation

/// 下载入队、磁盘空间预检与任务启动调度扩展（拆分自 DownloadCoordinator 保持单文件 <= 385 行）
extension DownloadCoordinator {
    func enqueue(book: BookSummaryDTO, chapters: [ChapterDTO], kind: DownloadKind, quality: AudioQualityTier) async {
        var batch: [DownloadRecordSnapshot] = []
        batch.reserveCapacity(chapters.count)
        var didPromoteCompletedPrecache = false
        for ch in chapters {
            let id = Self.makeRecordID(bookID: book.id, chapterID: ch.id)
            if var existing = allRecordsByID[id] {
                if existing.state == .completed {
                    if existing.kind == .precache && kind == .manual {
                        existing.kind = .manual
                        let fileExists: Bool = {
                            guard let rel = existing.localRelPath, !rel.isEmpty else { return false }
                            return FileManager.default.fileExists(atPath: downloadsRoot.appendingPathComponent(rel).path)
                        }()
                        if !fileExists {
                            existing.state = .queued
                            existing.localRelPath = nil
                            existing.downloadedBytes = 0
                            existing.qualityTier = quality
                            existing.retryCount = 0
                            existing.retryNotBefore = nil
                            existing.errorMessage = nil
                        } else {
                            didPromoteCompletedPrecache = true
                        }
                        allRecordsByID[id] = existing
                        batch.append(existing)
                    }
                    continue
                }
                var changed = false
                if existing.kind == .precache && kind == .manual {
                    existing.kind = .manual
                    scheduler.migrateKind(id: id, to: .manual)
                    changed = true
                }
                if existing.state == .failed || existing.state == .paused || existing.state == .cancelled {
                    existing.state = .queued
                    existing.qualityTier = quality
                    existing.retryCount = 0
                    existing.retryNotBefore = nil
                    existing.errorMessage = nil
                    changed = true
                }
                if changed {
                    allRecordsByID[id] = existing
                    batch.append(existing)
                }
                continue
            }
            let snap = DownloadRecordSnapshot(
                id: id,
                bookID: book.id,
                bookTitle: book.title,
                coverURL: book.coverURL,
                sourceID: book.sourceID,
                chapterID: ch.id,
                chapterIndex: ch.index,
                chapterTitle: ch.title,
                chapterURL: ch.url,
                kind: kind,
                state: .queued,
                qualityTier: quality
            )
            allRecordsByID[id] = snap
            batch.append(snap)
        }
        if !batch.isEmpty {
            await persistBatchWithLogging(batch, context: "入队下载")
        }
        if didPromoteCompletedPrecache {
            recomputeTotalDiskBytes()
            completedRevision &+= 1
        }
        refreshManualRecords()
        scheduleNextIfPossible()
    }

    func hasSufficientFreeDiskSpace() -> Bool {
        guard minimumFreeDiskBytes > 0 else { return true }
        let available: Int64?
        if let provider = freeDiskBytesProvider {
            available = provider()
        } else {
            let values = try? downloadsRoot.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let important = values?.volumeAvailableCapacityForImportantUsage {
                available = important
            } else if let standard = values?.volumeAvailableCapacity {
                available = Int64(standard)
            } else {
                available = nil
            }
        }
        guard let available else { return true }
        return available >= minimumFreeDiskBytes
    }

    private static let wifiBlockedReason = "等待 Wi-Fi 连接"
    private static let diskBlockedReason = "磁盘空间不足，等待释放"

    private func annotateQueuedReason(_ reason: String) {
        var changed = false
        for (id, var rec) in allRecordsByID where rec.state == .queued && (rec.errorMessage == nil || rec.errorMessage == Self.wifiBlockedReason || rec.errorMessage == Self.diskBlockedReason) {
            rec.errorMessage = reason
            allRecordsByID[id] = rec
            changed = true
        }
        if changed { refreshManualRecords() }
    }

    private func clearQueuedBlockReasons() {
        var changed = false
        for (id, var rec) in allRecordsByID where rec.state == .queued && (rec.errorMessage == Self.wifiBlockedReason || rec.errorMessage == Self.diskBlockedReason) {
            rec.errorMessage = nil
            allRecordsByID[id] = rec
            changed = true
        }
        if changed { refreshManualRecords() }
    }

    func scheduleNextIfPossible() {
        if wifiOnlyEnabled && !isCurrentlyOnWiFi {
            annotateQueuedReason(Self.wifiBlockedReason)
            return
        }
        guard hasSufficientFreeDiskSpace() else {
            annotateQueuedReason(Self.diskBlockedReason)
            return
        }
        clearQueuedBlockReasons()
        let queued = allRecordsByID.values.filter { $0.state == .queued }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.chapterIndex < $1.chapterIndex
        }
        let manual = queued.filter { $0.kind == .manual }
        let precache = queued.filter { $0.kind == .precache }
        let batch = scheduler.pickNextBatch(manualCandidates: manual, precacheCandidates: precache)
        for item in batch {
            startItem(item)
        }
    }

    func startItem(_ snapshot: DownloadRecordSnapshot) {
        guard hasSufficientFreeDiskSpace() else { return }
        guard var current = allRecordsByID[snapshot.id], current.state.canTransition(to: .resolving) else { return }
        scheduler.markStarted(id: current.id, kind: current.kind)
        current.state = .resolving
        if current.errorMessage == "等待 Wi-Fi 连接" || current.errorMessage == "磁盘空间不足，等待释放" {
            current.errorMessage = nil
        }
        allRecordsByID[current.id] = current
        refreshManualRecords()

        let taskID = current.id
        resolveTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { self.resolveTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled, self.allRecordsByID[taskID]?.state == .resolving else { return }
            await self.persistRecordWithDirtyRetry(current)
            do {
                let chapter = ChapterDTO(id: current.chapterID, index: current.chapterIndex, title: current.chapterTitle, url: current.chapterURL)
                let stream = try await self.audioResolver.resolveAudio(
                    sourceID: current.sourceID,
                    bookID: current.bookID,
                    chapter: chapter,
                    preferredQuality: current.qualityTier.resolved(isOnWiFi: self.isCurrentlyOnWiFi, allowUltraHigh: self.allowUltraHighQuality),
                    forDownload: true,
                    bypassCache: current.retryCount > 0
                )
                guard !Task.isCancelled, var latest = self.allRecordsByID[taskID], latest.state == .resolving else { return }
                if stream.isHLS {
                    self.scheduler.markFinished(id: taskID)
                    await self.markFailedWithoutRetry(taskID: taskID, message: "HLS 流媒体暂不支持直接离线下载")
                    return
                }
                let ext = Self.inferredAudioExtension(url: stream.url, mimeType: stream.mimeType)
                self.expectedExtByTaskID[taskID] = ext
                self.resolvedQualityByTaskID[taskID] = stream.qualityTier
                latest.state = .downloading
                latest.errorMessage = stream.isTrial ? "当前为试听音频片段" : nil
                self.allRecordsByID[taskID] = latest
                await self.persistRecordWithDirtyRetry(latest)
                guard !Task.isCancelled, self.allRecordsByID[taskID]?.state == .downloading else {
                    return
                }
                if self.wifiOnlyEnabled && !self.isCurrentlyOnWiFi {
                    latest.state = .paused
                    self.allRecordsByID[taskID] = latest
                    self.autoPausedForCellularIDs.insert(taskID)
                    self.scheduler.markFinished(id: taskID)
                    self.progressFeed.clearSpeed(for: taskID)
                    await self.persistRecordWithDirtyRetry(latest)
                    self.refreshManualRecords()
                    return
                }
                self.refreshManualRecords()
                self.transport.startDownload(
                    taskID: taskID,
                    url: stream.url,
                    headers: stream.headers,
                    wifiOnly: self.wifiOnlyEnabled,
                    preferredExtension: ext
                )
            } catch {
                guard !Task.isCancelled else { return }
                if let classified = error as? any AudioFailureClassifying, !classified.isRetryableAudioFailure {
                    self.scheduler.markFinished(id: taskID)
                    await self.markFailedWithoutRetry(taskID: taskID, message: error.localizedDescription)
                } else {
                    await self.handleFailure(taskID: taskID, httpStatus: nil, message: error.localizedDescription)
                }
            }
        }
    }

    /// 探测已落盘音频文件的真实码率并映射为标准/高清/超清，确保下载展示与播放器实测一致
    nonisolated static func probeDownloadedAudioQualityTier(at url: URL, fileSize: Int64) async -> AudioQualityTier? {
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .audio),
           let firstTrack = tracks.first,
           let dataRate = try? await firstTrack.load(.estimatedDataRate),
           dataRate.isFinite, dataRate > 0 {
            let kbps = Int((dataRate / 1000.0).rounded())
            if kbps > 0 {
                return AudioQualityTier.fromBitrateKbps(kbps)
            }
        }
        if fileSize > 0,
           let duration = try? await asset.load(.duration) {
            let sec = duration.seconds
            if sec.isFinite, sec > 1.0 {
                let kbps = Int((Double(fileSize) * 8.0 / sec / 1000.0).rounded())
                if kbps > 0 {
                    return AudioQualityTier.fromBitrateKbps(kbps)
                }
            }
        }
        return nil
    }
}
