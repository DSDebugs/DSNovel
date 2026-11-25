import Foundation
import os

/// 块级流式有界 HTTP 下载错误（在传输中实时断流，杜绝先完整进内存再判断导致的 OOM）
public enum DSCappedHTTPError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case responseTooLarge(limitBytes: Int)
}

/// 基于 URLSessionDataTask 每任务 delegate 的块级流式有界读取器（兼顾高性能、禁止自动重定向与 URLProtocol 单测兼容）
public enum DSCappedHTTPTransfer {
    public static func fetch(
        request: URLRequest,
        session: URLSession,
        maxBytes: Int,
        blockRedirects: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let cap = max(1, maxBytes)
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                let delegate = CappedDataTaskDelegate(
                    maxBytes: cap,
                    blockRedirects: blockRedirects,
                    continuation: cont
                )
                let task = session.dataTask(with: request)
                task.delegate = delegate
                box.setTask(task)
                if Task.isCancelled {
                    task.cancel()
                    delegate.cancelWithCancellationError()
                    return
                }
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)

    func setTask(_ task: URLSessionDataTask) {
        lock.withLock { $0 = task }
    }

    func cancel() {
        let task = lock.withLock { $0 }
        task?.cancel()
    }
}

private final class CappedDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var response: HTTPURLResponse?
        var buffer = Data()
        var exceededLimit = false
    }

    private let maxBytes: Int
    private let blockRedirects: Bool
    private let stateLock: OSAllocatedUnfairLock<State>

    init(
        maxBytes: Int,
        blockRedirects: Bool,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        self.maxBytes = maxBytes
        self.blockRedirects = blockRedirects
        self.stateLock = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
    }

    func cancelWithCancellationError() {
        let cont = stateLock.withLock { state -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
            let c = state.continuation
            state.continuation = nil
            state.buffer.removeAll(keepingCapacity: false)
            return c
        }
        cont?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if blockRedirects {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            let cont = takeContinuationClearingBuffer()
            completionHandler(.cancel)
            cont?.resume(throwing: DSCappedHTTPError.nonHTTPResponse)
            return
        }
        if http.expectedContentLength > Int64(maxBytes) {
            let cont = stateLock.withLock { state -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
                state.exceededLimit = true
                let c = state.continuation
                state.continuation = nil
                state.buffer.removeAll(keepingCapacity: false)
                return c
            }
            completionHandler(.cancel)
            cont?.resume(throwing: DSCappedHTTPError.responseTooLarge(limitBytes: maxBytes))
            return
        }
        stateLock.withLock { state in
            state.response = http
            if http.expectedContentLength > 0 {
                state.buffer.reserveCapacity(min(Int(http.expectedContentLength), maxBytes))
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceededCont = stateLock.withLock { state -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
            guard state.continuation != nil else { return nil }
            if state.buffer.count + data.count > maxBytes {
                state.exceededLimit = true
                state.buffer.removeAll(keepingCapacity: false)
                let c = state.continuation
                state.continuation = nil
                return c
            }
            state.buffer.append(data)
            return nil
        }
        if let cont = exceededCont {
            dataTask.cancel()
            cont.resume(throwing: DSCappedHTTPError.responseTooLarge(limitBytes: maxBytes))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: (
            cont: CheckedContinuation<(Data, HTTPURLResponse), Error>?,
            data: Data,
            response: HTTPURLResponse?,
            exceeded: Bool
        ) = stateLock.withLock { state in
            let c = state.continuation
            state.continuation = nil
            let d = state.buffer
            state.buffer = Data()
            return (c, d, state.response, state.exceededLimit)
        }
        guard let cont = outcome.cont else { return }
        if outcome.exceeded {
            cont.resume(throwing: DSCappedHTTPError.responseTooLarge(limitBytes: maxBytes))
        } else if let error {
            cont.resume(throwing: error)
        } else if let http = outcome.response {
            cont.resume(returning: (outcome.data, http))
        } else {
            cont.resume(throwing: DSCappedHTTPError.nonHTTPResponse)
        }
    }

    private func takeContinuationClearingBuffer() -> CheckedContinuation<(Data, HTTPURLResponse), Error>? {
        stateLock.withLock { state in
            let c = state.continuation
            state.continuation = nil
            state.buffer.removeAll(keepingCapacity: false)
            return c
        }
    }
}
