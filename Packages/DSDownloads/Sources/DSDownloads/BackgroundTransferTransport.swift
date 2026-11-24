import DSCore
import Foundation

/// 后台下载传输事件回调
public enum BackgroundTransferEvent: Sendable {
    case progress(taskID: String, written: Int64, total: Int64)
    case completed(taskID: String, stagedFileURL: URL)
    case failed(taskID: String, httpStatus: Int?, message: String, resumeData: Data?, isOutOfSpace: Bool = false)
}

/// 后台 URLSession 传输层（L-IOS-2：支持 AppDelegate 冷启接管、.pending_staging 落盘兜底与登录/网络切换作废 resumeData）
public final class BackgroundTransferTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let sessionIdentifier = "com.dsnovel.v3.background.downloads"
    static let knownAudioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg"]

    struct PersistedResumePayload: Codable, Sendable {
        let urlString: String
        let wifiOnly: Bool
        let headersHash: String?
        let data: Data
    }

    struct TaskMeta: Sendable {
        let url: URL
        let wifiOnly: Bool
        let headersHash: String
        let ext: String
    }

    public let sessionIdentifier: String

    let lock = NSLock()
    let stagingDir: URL
    let resumeDataDir: URL
    var session: URLSession?
    var resumePayloadByID: [String: PersistedResumePayload] = [:]
    var activeTasks: [String: URLSessionDownloadTask] = [:]
    var attemptTokens: [String: UInt64] = [:]
    var pausedTaskIDs: Set<String> = []
    var locallyCancelledTaskIDs: Set<Int> = []
    var taskMetaByID: [String: TaskMeta] = [:]
    var lastProgressEmitAtByID: [String: Date] = [:]
    var eventHandler: (@Sendable (BackgroundTransferEvent) -> Void)?
    var backgroundCompletionHandlers: [@Sendable () -> Void] = []
    var backgroundDrainHandler: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    var hasFinishedBackgroundEvents = false

    public init(baseDirectory: URL, sessionIdentifier: String = BackgroundTransferTransport.sessionIdentifier) {
        self.sessionIdentifier = sessionIdentifier
        self.stagingDir = baseDirectory.appendingPathComponent(".pending_staging", isDirectory: true)
        self.resumeDataDir = baseDirectory.appendingPathComponent(".resume_data", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: self.stagingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.resumeDataDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func invalidate() {
        let current = lock.withLock { () -> URLSession? in
            let s = session; session = nil; return s
        }
        current?.finishTasksAndInvalidate()
    }

    public func setEventHandler(_ handler: @escaping @Sendable (BackgroundTransferEvent) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    /// 注册后台事件收尾 drain 钩子，待协调器异步落盘完成后再回调系统 completionHandler
    public func setBackgroundDrainHandler(_ handler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        lock.withLock { backgroundDrainHandler = handler }
    }

    /// AppDelegate 后台唤醒直连入口（队列化绑定，避免多次唤醒相互覆盖丢失）
    public func handleBackgroundEvents(completionHandler: @escaping @Sendable () -> Void) {
        let (alreadyFinished, drain) = lock.withLock { () -> (Bool, (@Sendable (@escaping @Sendable () -> Void) -> Void)?) in
            if hasFinishedBackgroundEvents {
                hasFinishedBackgroundEvents = false
                return (true, backgroundDrainHandler)
            }
            backgroundCompletionHandlers.append(completionHandler)
            return (false, nil)
        }
        guard alreadyFinished else { return }
        if let drain {
            drain(completionHandler)
        } else {
            DispatchQueue.main.async { completionHandler() }
        }
    }

    public func startDownload(
        taskID: String,
        url: URL,
        headers: [String: String],
        wifiOnly: Bool = false,
        preferredExtension: String = "m4a"
    ) {
        let safeExt = Self.sanitizedExtension(preferredExtension)
        let currentHeadersHash = Self.computeHeadersHash(headers)
        let existingResume = consumeValidResumeData(for: taskID, url: url, wifiOnly: wifiOnly, currentHeadersHash: currentHeadersHash)

        let s: URLSession? = lock.withLock {
            attemptTokens[taskID, default: 0] &+= 1
            pausedTaskIDs.remove(taskID)
            lastProgressEmitAtByID.removeValue(forKey: taskID)
            taskMetaByID[taskID] = TaskMeta(url: url, wifiOnly: wifiOnly, headersHash: currentHeadersHash, ext: safeExt)
            return session
        }
        guard let s else { return }

        let task: URLSessionDownloadTask
        if let resumeData = existingResume {
            task = s.downloadTask(withResumeData: resumeData)
        } else {
            var req = URLRequest(url: url)
            req.allowsCellularAccess = !wifiOnly
            req.allowsExpensiveNetworkAccess = !wifiOnly
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            task = s.downloadTask(with: req)
        }
        task.taskDescription = "\(taskID)|\(safeExt)"
        lock.withLock { activeTasks[taskID] = task }
        task.resume()
    }

    /// P0-4：冷启动时重新挂接系统后台会话中仍在运行的下载任务，并从 originalRequest 恢复 TaskMeta
    public func reattachActiveTasks() async -> Set<String> {
        guard let s = lock.withLock({ session }) else { return [] }
        let tasks = await s.allTasks
        var activeIDs: Set<String> = []
        lock.withLock {
            for t in tasks {
                if let dl = t as? URLSessionDownloadTask,
                   let rawDesc = dl.taskDescription,
                   dl.state == .running || dl.state == .suspended {
                    let parsed = Self.parseTaskDescription(rawDesc)
                    activeTasks[parsed.taskID] = dl
                    if let req = dl.originalRequest, let url = req.url {
                        let headersHash = Self.computeHeadersHash(req.allHTTPHeaderFields ?? [:])
                        taskMetaByID[parsed.taskID] = TaskMeta(
                            url: url,
                            wifiOnly: !req.allowsCellularAccess,
                            headersHash: headersHash,
                            ext: parsed.ext
                        )
                    }
                    activeIDs.insert(parsed.taskID)
                }
            }
        }
        return activeIDs
    }

    public func pauseDownload(taskID: String) async {
        let captured = lock.withLock { () -> (URLSessionDownloadTask?, UInt64, TaskMeta?) in
            pausedTaskIDs.insert(taskID)
            lastProgressEmitAtByID.removeValue(forKey: taskID)
            let removed = activeTasks.removeValue(forKey: taskID)
            if let removed {
                locallyCancelledTaskIDs.insert(removed.taskIdentifier)
            }
            return (removed, attemptTokens[taskID] ?? 0, taskMetaByID[taskID])
        }
        guard let task = captured.0 else { return }
        let data = await task.cancelByProducingResumeData()
        guard let data, let meta = captured.2 else { return }
        let payload = PersistedResumePayload(urlString: meta.url.absoluteString, wifiOnly: meta.wifiOnly, headersHash: meta.headersHash, data: data)
        let shouldPersist = lock.withLock { () -> Bool in
            guard attemptTokens[taskID] == captured.1, pausedTaskIDs.contains(taskID) else { return false }
            resumePayloadByID[taskID] = payload
            return true
        }
        if shouldPersist { writeResumePayloadToDisk(payload, taskID: taskID) }
    }

    public func cancelDownload(taskID: String) {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            attemptTokens[taskID, default: 0] &+= 1
            pausedTaskIDs.remove(taskID)
            resumePayloadByID.removeValue(forKey: taskID)
            taskMetaByID.removeValue(forKey: taskID)
            lastProgressEmitAtByID.removeValue(forKey: taskID)
            let removed = activeTasks.removeValue(forKey: taskID)
            if let removed {
                locallyCancelledTaskIDs.insert(removed.taskIdentifier)
            }
            return removed
        }
        removeResumePayloadFromDisk(taskID: taskID)
        task?.cancel()
    }

    /// 登录态刷新或网络环境切换时作废全部旧 resumeData，防止 401/403/410 死循环
    public func invalidateAllResumeData() {
        lock.withLock { resumePayloadByID.removeAll() }
        if let files = try? FileManager.default.contentsOfDirectory(at: resumeDataDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    public func invalidateResumeData(for taskID: String) {
        lock.withLock { _ = resumePayloadByID.removeValue(forKey: taskID) }
        removeResumePayloadFromDisk(taskID: taskID)
    }

    /// 列出尚未被存储层认领的 .pending_staging 暂存音频文件（兼容 <taskID>.<ext>.staged 与旧 <taskID>.staged）
    public func listPendingStagingFiles() -> [(taskID: String, url: URL)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: stagingDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.map { url in
            let withoutStaged = url.deletingPathExtension()
            let possibleExt = withoutStaged.pathExtension.lowercased()
            let taskID = Self.knownAudioExtensions.contains(possibleExt)
                ? withoutStaged.deletingPathExtension().lastPathComponent
                : withoutStaged.lastPathComponent
            return (taskID, url)
        }
    }
}
