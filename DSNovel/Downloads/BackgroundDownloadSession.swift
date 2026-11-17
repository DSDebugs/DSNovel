import Foundation
import UIKit

@MainActor
final class BackgroundDownloadSession: NSObject, DownloadTransport {
    static let shared = BackgroundDownloadSession()
    static let sessionIdentifier = "com.dsnovel.downloads"

    var onEvent: ((DownloadTransportEvent) -> Void)?
    var systemCompletionHandler: (() -> Void)?

    private var tasksByItemID: [String: URLSessionDownloadTask] = [:]
    private var lastProgressEmitTime: [String: TimeInterval] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
    }

    func start(request: URLRequest, descriptor: DownloadTaskDescriptor, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        if let jsonData = try? JSONEncoder().encode(descriptor),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            task.taskDescription = jsonStr
        }
        tasksByItemID[descriptor.itemID] = task
        task.resume()
    }

    func pause(itemID: String) async -> Data? {
        guard let task = tasksByItemID.removeValue(forKey: itemID) else { return nil }
        return await withCheckedContinuation { continuation in
            task.cancel { data in
                continuation.resume(returning: data)
            }
        }
    }

    func cancel(itemID: String) {
        if let task = tasksByItemID.removeValue(forKey: itemID) {
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
            let taskAllows = t.originalRequest?.allowsCellularAccess ?? true
            if taskAllows != allowsCellular,
               let descStr = t.taskDescription,
               let data = descStr.data(using: .utf8),
               let desc = try? JSONDecoder().decode(DownloadTaskDescriptor.self, from: data) {
                t.cancel()
                tasksByItemID.removeValue(forKey: desc.itemID)
                cancelledIDs.append(desc.itemID)
            }
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
        guard totalBytesExpectedToWrite > 0,
              let desc = Self.decodeDescriptor(from: downloadTask) else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let now = Date().timeIntervalSince1970
        Task { @MainActor [weak self] in
            guard let self else { return }
            let last = self.lastProgressEmitTime[desc.itemID] ?? 0
            guard (now - last) >= 0.25 || fraction >= 1.0 else { return }
            self.lastProgressEmitTime[desc.itemID] = now
            self.onEvent?(.progress(itemID: desc.itemID, fraction: fraction))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let desc = Self.decodeDescriptor(from: downloadTask) else { return }
        // 同步移动临时文件到 App 自己的临时目录（系统回调返回后即删除 location）
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("DSNovelDownloadStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appendingPathComponent("\(UUID().uuidString).tmp")
        do {
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: location, to: stagedURL)
        } catch {
            Task { @MainActor [weak self] in
                self?.tasksByItemID.removeValue(forKey: desc.itemID)
                self?.onEvent?(.failed(descriptor: desc, statusCode: nil, errorDescription: error.localizedDescription))
            }
            return
        }
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        let mime = http?.mimeType
        Task { @MainActor [weak self] in
            self?.tasksByItemID.removeValue(forKey: desc.itemID)
            self?.onEvent?(.finished(descriptor: desc, tempFileURL: stagedURL, statusCode: code, mimeType: mime))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        guard let desc = Self.decodeDescriptor(from: task) else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor [weak self] in
            self?.tasksByItemID.removeValue(forKey: desc.itemID)
            self?.onEvent?(.failed(descriptor: desc, statusCode: code, errorDescription: error.localizedDescription))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let handler = self?.systemCompletionHandler
            self?.systemCompletionHandler = nil
            handler?()
        }
    }
}
