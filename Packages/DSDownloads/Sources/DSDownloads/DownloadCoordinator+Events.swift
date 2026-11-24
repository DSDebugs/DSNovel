import DSCore
import Foundation

/// 后台下载传输事件、在途 drain 与 staging 认领扩展（SYS3-03：拆分自 DownloadCoordinator 留足 400 行维护裕度）
extension DownloadCoordinator {
    private static let maxPendingEventsBeforeBootstrap = 256

    func handleTransferEvent(_ event: BackgroundTransferEvent) {
        if !isBootstrapped {
            if case .progress = event { return }
            if pendingTransferEvents.count < Self.maxPendingEventsBeforeBootstrap {
                pendingTransferEvents.append(event)
            }
            return
        }
        switch event {
        case .progress(let taskID, let written, let total):
            guard var rec = allRecordsByID[taskID], rec.state == .downloading else { return }
            let now = Date()
            let speed: Int64
            if let prev = progressSampleByTaskID[taskID] {
                let dt = now.timeIntervalSince(prev.timestamp)
                let deltaBytes = max(0, written - prev.bytes)
                speed = dt > 0.001 ? Int64(Double(deltaBytes) / dt) : 0
            } else {
                speed = 0
            }
            progressSampleByTaskID[taskID] = (now, written)
            progressFeed.update(id: taskID, downloaded: written, total: total, speed: speed)
            rec.downloadedBytes = written
            rec.totalBytes = total
            allRecordsByID[taskID] = rec
        case .completed(let taskID, let stagedURL):
            trackInFlightEventTask { [weak self] in
                await self?.finalizeCompletedDownload(taskID: taskID, stagedURL: stagedURL)
            }
        case .failed(let taskID, let status, let message, _, let isOutOfSpace):
            trackInFlightEventTask { [weak self] in
                guard let self else { return }
                if isOutOfSpace {
                    self.scheduler.markFinished(id: taskID)
                    self.resolveTasks.removeValue(forKey: taskID)
                    self.progressSampleByTaskID.removeValue(forKey: taskID)
                    await self.markFailedWithoutRetry(taskID: taskID, message: "磁盘空间不足，已暂停全部下载")
                    await self.pauseAll()
                } else {
                    await self.handleFailure(taskID: taskID, httpStatus: status, message: message)
                }
            }
        }
    }

    func enqueueBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
        pendingBackgroundCompletions.append(completion)
        drainBackgroundCompletionsIfIdle()
    }

    func drainBackgroundCompletionsIfIdle() {
        guard isBootstrapFinished, inFlightEventTasks.isEmpty, !pendingBackgroundCompletions.isEmpty else { return }
        let callbacks = pendingBackgroundCompletions
        pendingBackgroundCompletions.removeAll()
        for cb in callbacks { cb() }
    }

    private func trackInFlightEventTask(_ work: @escaping @MainActor () async -> Void) {
        let token = UUID()
        inFlightEventTasks[token] = Task { @MainActor [weak self] in
            defer {
                self?.inFlightEventTasks.removeValue(forKey: token)
                self?.drainBackgroundCompletionsIfIdle()
            }
            await work()
        }
    }

    func finalizeCompletedDownload(taskID: String, stagedURL: URL) async {
        guard inFlightFinalizingIDs.insert(taskID).inserted else { return }
        defer { inFlightFinalizingIDs.remove(taskID) }

        scheduler.markFinished(id: taskID)
        resolveTasks.removeValue(forKey: taskID)
        retryTasks[taskID]?.cancel()
        retryTasks.removeValue(forKey: taskID)
        progressSampleByTaskID.removeValue(forKey: taskID)
        let resolvedQuality = resolvedQualityByTaskID.removeValue(forKey: taskID)
        guard var rec = allRecordsByID[taskID], rec.state.canTransition(to: .completed) else {
            try? FileManager.default.removeItem(at: stagedURL)
            scheduleNextIfPossible()
            return
        }
        guard Self.validateDownloadedAudioFile(at: stagedURL) else {
            try? FileManager.default.removeItem(at: stagedURL)
            await handleFailure(taskID: taskID, httpStatus: nil, message: "下载内容非有效音频（可能触发防盗链）")
            return
        }
        let ext = expectedExtByTaskID.removeValue(forKey: taskID)
            ?? Self.extractExtension(fromStagedURL: stagedURL)
            ?? "m4a"
        let relPath = DownloadRecordSnapshot.canonicalRelativePath(bookID: rec.bookID, chapterID: rec.chapterID, ext: ext)
        let finalURL = downloadsRoot.appendingPathComponent(relPath)
        try? FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL, backupItemName: nil, options: [])
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            rec.state = .completed
            if let resolvedQuality {
                rec.qualityTier = resolvedQuality
            }
            rec.localRelPath = relPath
            rec.totalBytes = size
            rec.downloadedBytes = size
            rec.errorMessage = nil
            allRecordsByID[taskID] = rec
            try? await persistence.upsertDownload(rec)
            progressFeed.remove(id: taskID)
            recomputeTotalDiskBytes()
            completedRevision &+= 1
            refreshManualRecords()
            if rec.kind == .precache {
                await enforceGlobalPrecacheCapIfNeeded(protectingTaskID: taskID)
            }
            await reconcileDisk(force: false)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            if Self.isOutOfSpaceError(error) {
                await markFailedWithoutRetry(taskID: taskID, message: "磁盘空间不足，无法保存离线音频")
                await pauseAll()
                return
            } else {
                await handleFailure(taskID: taskID, httpStatus: nil, message: error.localizedDescription)
            }
        }
        scheduleNextIfPossible()
    }

    func handleFailure(taskID: String, httpStatus: Int?, message: String) async {
        scheduler.markFinished(id: taskID)
        resolveTasks.removeValue(forKey: taskID)
        resolvedQualityByTaskID.removeValue(forKey: taskID)
        progressSampleByTaskID.removeValue(forKey: taskID)
        progressFeed.clearSpeed(for: taskID)
        guard var rec = allRecordsByID[taskID], !rec.state.isTerminal else {
            scheduleNextIfPossible()
            return
        }
        if let delay = DownloadRetryPolicy.delaySeconds(retryCount: rec.retryCount, httpStatus: httpStatus) {
            rec.retryCount += 1
            rec.retryNotBefore = Date().addingTimeInterval(delay)
            rec.state = .queued
            rec.errorMessage = "等待重试（\(Int(delay))s）：\(message)"
            allRecordsByID[taskID] = rec
            try? await persistence.upsertDownload(rec)
            refreshManualRecords()
            retryTasks[taskID]?.cancel()
            retryTasks[taskID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay + 0.1))
                guard !Task.isCancelled, let self else { return }
                self.retryTasks.removeValue(forKey: taskID)
                self.scheduleNextIfPossible()
            }
            scheduleNextIfPossible()
        } else {
            await markFailedWithoutRetry(taskID: taskID, message: message)
        }
    }

    internal func markFailedWithoutRetry(taskID: String, message: String) async {
        resolvedQualityByTaskID.removeValue(forKey: taskID)
        progressFeed.clearSpeed(for: taskID)
        guard var rec = allRecordsByID[taskID], !rec.state.isTerminal else { return }
        rec.state = .failed
        rec.retryNotBefore = nil
        rec.errorMessage = message
        allRecordsByID[taskID] = rec
        try? await persistence.upsertDownload(rec)
        refreshManualRecords()
        scheduleNextIfPossible()
    }

    func claimPendingStagingFiles() async {
        for item in transport.listPendingStagingFiles() {
            if allRecordsByID[item.taskID] != nil {
                await finalizeCompletedDownload(taskID: item.taskID, stagedURL: item.url)
            } else {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
    }

    static func inferredAudioExtension(url: URL, mimeType: String?) -> String {
        let lowerMime = mimeType?.lowercased() ?? ""
        if lowerMime.contains("mpeg") || lowerMime.contains("mp3") { return "mp3" }
        if lowerMime.contains("flac") { return "flac" }
        if lowerMime.contains("aac") { return "aac" }
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(ext) { return ext }
        return "m4a"
    }

    static func extractExtension(fromStagedURL url: URL) -> String? {
        let withoutStaged = url.deletingPathExtension()
        let candidate = withoutStaged.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(candidate) {
            return candidate
        }
        return nil
    }

    static func isOutOfSpaceError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpaceError(underlying)
        }
        return false
    }

    static func validateDownloadedAudioFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 1024,
              let fh = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 64), !head.isEmpty else {
            return false
        }
        let prefix = String(decoding: head.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if prefix.hasPrefix("<!doctype")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("#extm3u")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
            || prefix.hasPrefix("error")
            || prefix.hasPrefix("403 ")
            || prefix.hasPrefix("404 ") {
            return false
        }
        return true
    }

    public func reconcileDisk(force: Bool) async {
        guard didLoadPersistenceSuccessfully else { return }
        let rev = completedRevision
        let completed = allRecordsByID.values.filter { $0.state == .completed }
        guard let report = await reconciler.reconcileIfNeeded(completedRecords: completed, force: force) else { return }
        if completedRevision == rev {
            totalDiskBytes = report.totalAudioBytes
        } else {
            recomputeTotalDiskBytes()
        }
        var missingBatch: [DownloadRecordSnapshot] = []
        for missingID in report.missingRecordIDs {
            if var rec = allRecordsByID[missingID], rec.state == .completed {
                rec.state = .failed
                rec.localRelPath = nil
                rec.errorMessage = "本地文件已丢失，可重新下载"
                allRecordsByID[missingID] = rec
                missingBatch.append(rec)
            }
        }
        if !missingBatch.isEmpty {
            try? await persistence.upsertDownloadsBatch(missingBatch)
            completedRevision &+= 1
            recomputeTotalDiskBytes()
            refreshManualRecords()
        }
    }
}
