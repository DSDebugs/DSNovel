import Foundation
import os
import UIKit

@MainActor
final class BackgroundDownloadSession: NSObject, DownloadTransport {
    static let shared = BackgroundDownloadSession()
    static let sessionIdentifier = "com.dsnovel.downloads"
    static let systemCompletionFallbackTimeoutSeconds: TimeInterval = 20

    nonisolated static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelDownloadStaging", isDirectory: true)
    }

    var onEvent: ((DownloadTransportEvent) -> Void)?
    var onEventCompleted: (() -> Void)?
    var systemCompletionHandler: (() -> Void)?

    private var tasksByItemID: [String: URLSessionDownloadTask] = [:]
    /// P1：在 URLSession 回调线程通过锁完成 0.25s 节流并缓存 itemID，避免每分片解码 JSON 及无效切回 MainActor
    nonisolated private let progressThrottleState = OSAllocatedUnfairLock<[ObjectIdentifier: (itemID: String, lastEmit: TimeInterval)]>(initialState: [:])
    /// R3-2：在途事件计数（跨 delegate 队列与 MainActor 同步保护），防止 urlSessionDidFinishEvents 过早挂起后台进程
    nonisolated private let inFlightEventState = OSAllocatedUnfairLock<Int>(initialState: 0)
    private var waitingForSystemCompletion = false
    private var systemCompletionTimeoutTask: Task<Void, Never>?
    private var session: URLSession!

    var inFlightEventCount: Int {
        inFlightEventState.withLock { $0 }
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 供 AppDelegate 后台唤醒时显式触发单例与底层 URLSession 就绪
    func ensureSessionInitialized() {
        _ = session
    }

    /// R3-2：由 DownloadManager 在 handleTransportEvent 完成后调用，递减在途事件计数并在归零时释放系统后台回调
    func notifyEventCompleted() {
        let remaining = inFlightEventState.withLock { count -> Int in
            count = max(0, count - 1)
            return count
        }
        onEventCompleted?()
        if remaining == 0 && waitingForSystemCompletion {
            flushSystemCompletionHandler()
        }
    }

    nonisolated private func beginInFlightEvent() {
        inFlightEventState.withLock { count in
            count += 1
        }
    }

    nonisolated private func dispatchEventToMain(_ event: DownloadTransportEvent, removeTaskItemID: String? = nil) {
        beginInFlightEvent()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let removeTaskItemID {
                self.tasksByItemID.removeValue(forKey: removeTaskItemID)
            }
            // M-P0-2：后台冷启若事件先于 DownloadManager.shared 初始化到达，主动唤醒单例完成事件钩子挂载
            if self.onEvent == nil && self === BackgroundDownloadSession.shared {
                _ = DownloadManager.shared
            }
            if let handler = self.onEvent {
                handler(event)
            } else {
                self.notifyEventCompleted()
            }
        }
    }

    private func handleDidFinishBackgroundEvents() {
        waitingForSystemCompletion = true
        if inFlightEventCount <= 0 {
            flushSystemCompletionHandler()
            return
        }
        systemCompletionTimeoutTask?.cancel()
        let timeoutSeconds = Self.systemCompletionFallbackTimeoutSeconds
        systemCompletionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.flushSystemCompletionHandler()
        }
    }

    private func flushSystemCompletionHandler() {
        waitingForSystemCompletion = false
        systemCompletionTimeoutTask?.cancel()
        systemCompletionTimeoutTask = nil
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        handler?()
    }

    /// 7-3：校验由 `resumeData` 创建的任务是否与最新 `URLRequest`（网络策略、主机、Cookie/Authorization）一致
    private static func resumedTaskMatchesPolicy(_ task: URLSessionDownloadTask, latestRequest: URLRequest) -> Bool {
        guard let embedded = task.currentRequest ?? task.originalRequest else {
            return true
        }
        if embedded.allowsCellularAccess != latestRequest.allowsCellularAccess {
            return false
        }
        if let embeddedHost = embedded.url?.host?.lowercased(),
           let latestHost = latestRequest.url?.host?.lowercased(),
           embeddedHost != latestHost {
            return false
        }
        let latestCookie = latestRequest.value(forHTTPHeaderField: "Cookie") ?? ""
        let embeddedCookie = embedded.value(forHTTPHeaderField: "Cookie") ?? ""
        if !latestCookie.isEmpty && latestCookie != embeddedCookie {
            return false
        }
        let latestAuth = latestRequest.value(forHTTPHeaderField: "Authorization") ?? ""
        let embeddedAuth = embedded.value(forHTTPHeaderField: "Authorization") ?? ""
        if !latestAuth.isEmpty && latestAuth != embeddedAuth {
            return false
        }
        return true
    }

    func start(request: URLRequest, descriptor: DownloadTaskDescriptor, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            let candidate = session.downloadTask(withResumeData: resumeData)
            if Self.resumedTaskMatchesPolicy(candidate, latestRequest: request) {
                task = candidate
            } else {
                // 7-3：resumeData 内嵌旧网络策略或过期鉴权头，放弃旧断点并用最新 URLRequest 重建任务
                candidate.cancel()
                task = session.downloadTask(with: request)
            }
        } else {
            task = session.downloadTask(with: request)
        }
        if let jsonData = try? JSONEncoder().encode(descriptor),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            task.taskDescription = jsonStr
        }
        let taskKey = ObjectIdentifier(task)
        progressThrottleState.withLock { state in
            state[taskKey] = (itemID: descriptor.itemID, lastEmit: 0)
        }
        tasksByItemID[descriptor.itemID] = task
        task.resume()
    }

    func pause(itemID: String) async -> Data? {
        guard let task = tasksByItemID.removeValue(forKey: itemID) else { return nil }
        let taskKey = ObjectIdentifier(task)
        progressThrottleState.withLock { state in
            _ = state.removeValue(forKey: taskKey)
        }
        return await withCheckedContinuation { continuation in
            task.cancel { data in
                continuation.resume(returning: data)
            }
        }
    }

    func cancel(itemID: String) {
        if let task = tasksByItemID.removeValue(forKey: itemID) {
            let taskKey = ObjectIdentifier(task)
            progressThrottleState.withLock { state in
                _ = state.removeValue(forKey: taskKey)
            }
            task.cancel()
        }
    }

    func activeTaskItemIDs() async -> Set<String> {
        let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { list in
                continuation.resume(returning: list)
            }
        }
        var ids = Set<String>()
        for t in tasks where t.state == .running || t.state == .suspended {
            if let descStr = t.taskDescription,
               let data = descStr.data(using: .utf8),
               let desc = try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data) {
                ids.insert(desc.itemID)
                if let dlTask = t as? URLSessionDownloadTask {
                    tasksByItemID[desc.itemID] = dlTask
                    let taskKey = ObjectIdentifier(dlTask)
                    progressThrottleState.withLock { state in
                        if state[taskKey] == nil {
                            state[taskKey] = (itemID: desc.itemID, lastEmit: 0)
                        }
                    }
                }
            }
        }
        return ids
    }

    func cancelTasksDisallowingMismatch(allowsCellular: Bool) async -> [String] {
        let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { list in
                continuation.resume(returning: list)
            }
        }
        var cancelledIDs: [String] = []
        for t in tasks {
            let taskAllows = t.currentRequest?.allowsCellularAccess ?? t.originalRequest?.allowsCellularAccess ?? true
            if taskAllows != allowsCellular,
               let descStr = t.taskDescription,
               let data = descStr.data(using: .utf8),
               let desc = try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data) {
                let taskKey = ObjectIdentifier(t)
                progressThrottleState.withLock { state in
                    _ = state.removeValue(forKey: taskKey)
                }
                t.cancel()
                tasksByItemID.removeValue(forKey: desc.itemID)
                cancelledIDs.append(desc.itemID)
            }
        }
        return cancelledIDs
    }

    /// 7-3：鉴权/Cookie 刷新时按条件取消在途后台任务，供 DownloadManager 清除旧 resumeData 并用最新请求重建
    func cancelTasksMatching(_ predicate: (DownloadTaskDescriptor) -> Bool) async -> [String] {
        let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { list in
                continuation.resume(returning: list)
            }
        }
        var cancelledIDs: [String] = []
        for t in tasks {
            guard let descStr = t.taskDescription,
                  let data = descStr.data(using: .utf8),
                  let desc = try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data),
                  predicate(desc) else {
                continue
            }
            let taskKey = ObjectIdentifier(t)
            progressThrottleState.withLock { state in
                _ = state.removeValue(forKey: taskKey)
            }
            t.cancel()
            tasksByItemID.removeValue(forKey: desc.itemID)
            cancelledIDs.append(desc.itemID)
        }
        return cancelledIDs
    }

    nonisolated private static func decodeDescriptor(from task: URLSessionTask) -> DownloadTaskDescriptor? {
        guard let descStr = task.taskDescription,
              let data = descStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data)
    }
}

extension BackgroundDownloadSession: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let now = Date().timeIntervalSince1970
        let taskKey = ObjectIdentifier(downloadTask)

        let itemIDToEmit: String? = progressThrottleState.withLock { state in
            let itemID: String
            let lastEmit: TimeInterval
            if let cached = state[taskKey] {
                itemID = cached.itemID
                lastEmit = cached.lastEmit
            } else if let desc = Self.decodeDescriptor(from: downloadTask) {
                itemID = desc.itemID
                lastEmit = 0
                state[taskKey] = (itemID: itemID, lastEmit: 0)
            } else {
                return nil
            }
            guard (now - lastEmit) >= 0.25 || fraction >= 1.0 else {
                return nil
            }
            state[taskKey] = (itemID: itemID, lastEmit: now)
            return itemID
        }

        guard let itemID = itemIDToEmit else { return }
        dispatchEventToMain(.progress(itemID: itemID, fraction: fraction))
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskKey = ObjectIdentifier(downloadTask)
        progressThrottleState.withLock { state in
            _ = state.removeValue(forKey: taskKey)
        }
        guard let desc = Self.decodeDescriptor(from: downloadTask) else { return }
        // 同步移动临时文件到 App 自己的临时目录（系统回调返回后即删除 location）
        let stagingDir = Self.stagingDirectory
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appendingPathComponent("\(UUID().uuidString).tmp")
        do {
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: location, to: stagedURL)
        } catch {
            dispatchEventToMain(
                .failed(descriptor: desc, statusCode: nil, errorDescription: error.localizedDescription),
                removeTaskItemID: desc.itemID
            )
            return
        }
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        let mime = http?.mimeType
        let originalURL = downloadTask.originalRequest?.url
        let suggestedFilename = downloadTask.response?.suggestedFilename
        let rawExpectedLength = downloadTask.response?.expectedContentLength ?? -1
        let expectedLength: Int64? = rawExpectedLength > 0 ? rawExpectedLength : nil

        dispatchEventToMain(
            .finished(
                descriptor: desc,
                tempFileURL: stagedURL,
                statusCode: code,
                mimeType: mime,
                originalURL: originalURL,
                suggestedFilename: suggestedFilename,
                expectedContentLength: expectedLength
            ),
            removeTaskItemID: desc.itemID
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskKey = ObjectIdentifier(task)
        progressThrottleState.withLock { state in
            _ = state.removeValue(forKey: taskKey)
        }
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        guard let desc = Self.decodeDescriptor(from: task) else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode
        dispatchEventToMain(
            .failed(descriptor: desc, statusCode: code, errorDescription: error.localizedDescription),
            removeTaskItemID: desc.itemID
        )
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.handleDidFinishBackgroundEvents()
        }
    }
}
