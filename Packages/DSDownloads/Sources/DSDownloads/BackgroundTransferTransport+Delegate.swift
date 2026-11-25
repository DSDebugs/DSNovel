import DSCore
import Foundation

/// BackgroundTransferTransport URLSessionDownloadDelegate 回调与断点续传落盘扩展（拆分保持单文件 <= 385 行）
extension BackgroundTransferTransport {
    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let rawDesc = downloadTask.taskDescription else { return }
        let taskID = Self.parseTaskDescription(rawDesc).taskID
        let now = Date()
        let isComplete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        let handler = lock.withLock { () -> (@Sendable (BackgroundTransferEvent) -> Void)? in
            if let current = activeTasks[taskID], current !== downloadTask { return nil }
            if !isComplete, let last = lastProgressEmitAtByID[taskID], now.timeIntervalSince(last) < 0.2 { return nil }
            lastProgressEmitAtByID[taskID] = now
            return eventHandler
        }
        handler?(.progress(taskID: taskID, written: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let rawDesc = downloadTask.taskDescription else { return }
        let parsed = Self.parseTaskDescription(rawDesc)
        let taskID = parsed.taskID
        let (shouldHandle, ext) = lock.withLock { () -> (Bool, String) in
            let wasCancelled = locallyCancelledTaskIDs.remove(downloadTask.taskIdentifier) != nil
            if let current = activeTasks[taskID] {
                guard current === downloadTask else { return (false, parsed.ext) }
                activeTasks.removeValue(forKey: taskID)
                lastProgressEmitAtByID.removeValue(forKey: taskID)
                let meta = taskMetaByID.removeValue(forKey: taskID)
                return (true, meta?.ext ?? parsed.ext)
            }
            if wasCancelled {
                return (false, parsed.ext)
            }
            lastProgressEmitAtByID.removeValue(forKey: taskID)
            let meta = taskMetaByID.removeValue(forKey: taskID)
            return (true, meta?.ext ?? parsed.ext)
        }
        guard shouldHandle else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: http.statusCode) {
                invalidateResumeData(for: taskID)
            }
            lock.withLock { eventHandler }?(.failed(taskID: taskID, httpStatus: http.statusCode, message: "HTTP \(http.statusCode)", resumeData: nil))
            return
        }

        // 立刻原子移入 .pending_staging 并编码原扩展名，先清理同任务旧扩展名暂存文件
        let safeName = taskID.replacingOccurrences(of: "/", with: "_")
        let stagedURL = stagingDir.appendingPathComponent("\(safeName).\(Self.sanitizedExtension(ext)).staged")
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) {
            let prefix = "\(safeName)."
            for item in existing where item.lastPathComponent.hasPrefix(prefix) && item.lastPathComponent.hasSuffix(".staged") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        do {
            try FileManager.default.moveItem(at: location, to: stagedURL)
            lock.withLock { eventHandler }?(.completed(taskID: taskID, stagedFileURL: stagedURL))
        } catch {
            let outOfSpace = Self.isOutOfSpaceError(error)
            lock.withLock { eventHandler }?(
                .failed(taskID: taskID, httpStatus: nil, message: error.localizedDescription, resumeData: nil, isOutOfSpace: outOfSpace)
            )
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let rawDesc = task.taskDescription else { return }
        let taskID = Self.parseTaskDescription(rawDesc).taskID
        let (shouldHandle, wasLocallyCancelled, meta) = lock.withLock { () -> (Bool, Bool, TaskMeta?) in
            let cancelled = locallyCancelledTaskIDs.remove(task.taskIdentifier) != nil
            if let current = activeTasks[taskID] {
                guard current === task else { return (false, cancelled, nil) }
                activeTasks.removeValue(forKey: taskID)
                lastProgressEmitAtByID.removeValue(forKey: taskID)
                let m = taskMetaByID.removeValue(forKey: taskID)
                return (true, cancelled, m)
            }
            if cancelled {
                return (false, true, nil)
            }
            lastProgressEmitAtByID.removeValue(forKey: taskID)
            let m = taskMetaByID.removeValue(forKey: taskID)
            return (true, false, m)
        }
        guard shouldHandle else { return }
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled && wasLocallyCancelled { return }
        let resume = nsErr.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        if let r = resume, let meta, !DownloadRetryPolicy.shouldInvalidateResumeData(httpStatus: httpStatus) {
            let payload = PersistedResumePayload(urlString: meta.url.absoluteString, wifiOnly: meta.wifiOnly, headersHash: meta.headersHash, data: r)
            lock.withLock { resumePayloadByID[taskID] = payload }
            writeResumePayloadToDisk(payload, taskID: taskID)
        }
        let outOfSpace = Self.isOutOfSpaceError(error)
        lock.withLock { eventHandler }?(
            .failed(taskID: taskID, httpStatus: httpStatus, message: error.localizedDescription, resumeData: resume, isOutOfSpace: outOfSpace)
        )
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let (completions, drainHandler) = lock.withLock { () -> ([@Sendable () -> Void], (@Sendable (@escaping @Sendable () -> Void) -> Void)?) in
            let cbs = backgroundCompletionHandlers
            backgroundCompletionHandlers.removeAll()
            if cbs.isEmpty {
                hasFinishedBackgroundEvents = true
            } else {
                hasFinishedBackgroundEvents = false
            }
            return (cbs, backgroundDrainHandler)
        }
        guard !completions.isEmpty else { return }
        if let drainHandler {
            for cb in completions { drainHandler(cb) }
        } else {
            DispatchQueue.main.async {
                for cb in completions { cb() }
            }
        }
    }

    // MARK: - Resume Data Persistence & Helpers

    func resumeFileURL(for taskID: String) -> URL {
        resumeDataDir.appendingPathComponent("\(taskID.replacingOccurrences(of: "/", with: "_")).resume")
    }

    func writeResumePayloadToDisk(_ payload: PersistedResumePayload, taskID: String) {
        try? FileManager.default.createDirectory(at: resumeDataDir, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(payload) {
            try? encoded.write(to: resumeFileURL(for: taskID), options: .atomic)
        }
    }

    func removeResumePayloadFromDisk(taskID: String) {
        try? FileManager.default.removeItem(at: resumeFileURL(for: taskID))
    }

    func consumeValidResumeData(for taskID: String, url: URL, wifiOnly: Bool, currentHeadersHash: String) -> Data? {
        let memPayload = lock.withLock { resumePayloadByID.removeValue(forKey: taskID) }
        let diskURL = resumeFileURL(for: taskID)
        let payload: PersistedResumePayload?
        if let memPayload {
            payload = memPayload
        } else if let raw = try? Data(contentsOf: diskURL) {
            payload = try? JSONDecoder().decode(PersistedResumePayload.self, from: raw)
        } else {
            payload = nil
        }
        try? FileManager.default.removeItem(at: diskURL)
        guard let payload,
              payload.urlString == url.absoluteString,
              payload.wifiOnly == wifiOnly,
              payload.headersHash == nil || payload.headersHash == currentHeadersHash else {
            return nil
        }
        return payload.data
    }

    static func computeHeadersHash(_ headers: [String: String]) -> String {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            normalized[k.lowercased()] = v
        }
        let canonical = normalized
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")
        return DSCrypto.sha256Hex(canonical)
    }

    static func parseTaskDescription(_ raw: String) -> (taskID: String, ext: String) {
        if let sep = raw.lastIndex(of: "|") {
            return (String(raw[..<sep]), sanitizedExtension(String(raw[raw.index(after: sep)...])))
        }
        return (raw, "m4a")
    }

    static func sanitizedExtension(_ ext: String) -> String {
        let lower = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return knownAudioExtensions.contains(lower) ? lower : "m4a"
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
}
