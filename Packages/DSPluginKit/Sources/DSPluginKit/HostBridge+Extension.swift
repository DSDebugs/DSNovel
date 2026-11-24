import DSCore
import Foundation

private final class SyncBridgeResultBox<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var value: T?
}

extension HostHandleJS {
    private static let restrictedRequestHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding"
    ]

    private static func isSafeHeaderComponent(_ text: String) -> Bool {
        !text.contains("\r") && !text.contains("\n") && !text.contains("\0")
    }

    internal func performRequestAll(urlsJSON: String, optionsJSON: String?, concurrency: Int) -> String {
        guard !cancellationToken.isCancelled else {
            return Self.encodeError("请求已取消", cancelled: true)
        }
        guard let data = urlsJSON.data(using: .utf8),
              let urls = try? JSONDecoder().decode([String].self, from: data) else {
            return Self.encodeError("Invalid urls JSON")
        }
        guard !urls.isEmpty else {
            return Self.encodeValue([String]())
        }
        let (method, headers, body, encoding) = Self.parseRequestOptions(optionsJSON)
        let maxConcurrent = max(1, min(concurrency, 6))
        let client = httpClient
        let pol = policy
        let token = cancellationToken
        return syncBridge(fallback: Self.encodeError("请求已取消或超时", cancelled: token.isCancelled)) {
            await withTaskGroup(of: (Int, String).self) { group in
                var results = Array(repeating: "", count: urls.count)
                var nextIndex = 0
                var active = 0

                func enqueueAvailable() {
                    while active < maxConcurrent && nextIndex < urls.count && !Task.isCancelled && !token.isCancelled {
                        let idx = nextIndex
                        let rawURL = urls[idx]
                        nextIndex += 1
                        active += 1
                        group.addTask {
                            guard !Task.isCancelled, !token.isCancelled, let parsedURL = URL(string: rawURL) else {
                                return (idx, "")
                            }
                            do {
                                let resp = try await client.send(
                                    url: parsedURL,
                                    method: method,
                                    headers: headers,
                                    body: body,
                                    policy: pol,
                                    encoding: encoding
                                )
                                return (idx, resp.statusCode >= 400 ? "" : resp.bodyString)
                            } catch {
                                return (idx, "")
                            }
                        }
                    }
                }

                enqueueAvailable()
                for await (idx, bodyText) in group {
                    active -= 1
                    if idx >= 0 && idx < results.count {
                        results[idx] = bodyText
                    }
                    if Task.isCancelled || token.isCancelled {
                        group.cancelAll()
                        break
                    }
                    enqueueAvailable()
                }
                if Task.isCancelled || token.isCancelled {
                    return Self.encodeError("请求已取消", cancelled: true)
                }
                return Self.encodeValue(results)
            }
        }
    }

    internal func performHTTP(
        url: String,
        optionsJSON: String?,
        transform: @escaping @Sendable (HostHTTPResponse) -> String
    ) -> String {
        guard !cancellationToken.isCancelled else {
            return Self.encodeError("请求已取消", cancelled: true)
        }
        guard let parsedURL = URL(string: url) else {
            return Self.encodeError("Invalid URL: \(url)")
        }
        let (method, headers, body, encoding) = Self.parseRequestOptions(optionsJSON)
        let client = httpClient
        let pol = policy
        let token = cancellationToken
        return syncBridge(fallback: Self.encodeError(token.isCancelled ? "请求已取消" : "请求超时", cancelled: token.isCancelled)) {
            do {
                let resp = try await client.send(
                    url: parsedURL,
                    method: method,
                    headers: headers,
                    body: body,
                    policy: pol,
                    encoding: encoding
                )
                return transform(resp)
            } catch is CancellationError {
                return Self.encodeError("请求已取消", cancelled: true)
            } catch {
                return Self.encodeError(error.localizedDescription)
            }
        }
    }

    internal func syncBridge<T: Sendable>(
        fallback: @autoclosure () -> T,
        timeoutSeconds: TimeInterval = 18.0,
        _ operation: @escaping @Sendable () async -> T
    ) -> T {
        if cancellationToken.isCancelled { return fallback() }
        let box = SyncBridgeResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let result = await operation()
            box.lock.withLock { box.value = result }
            sem.signal()
        }
        let tokenID = cancellationToken.onCancel {
            task.cancel()
            sem.signal()
        }
        defer { cancellationToken.removeCancelHandler(tokenID) }
        let waited = sem.wait(timeout: .now() + timeoutSeconds)
        if waited != .success || cancellationToken.isCancelled {
            task.cancel()
            return fallback()
        }
        return box.lock.withLock { box.value } ?? fallback()
    }

    internal static func parseRequestOptions(
        _ optionsJSON: String?
    ) -> (method: String, headers: [String: String], body: Data?, encoding: String?) {
        var method = "GET"
        var headers: [String: String] = [:]
        var body: Data?
        var encoding: String?
        if let raw = optionsJSON,
           let d = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let m = dict["method"] as? String { method = m }
            if let rawHeaders = dict["headers"] as? [String: Any] {
                for (k, v) in rawHeaders {
                    let cleanKey = k.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanKey.isEmpty,
                          isSafeHeaderComponent(cleanKey),
                          !restrictedRequestHeaders.contains(cleanKey.lowercased()) else {
                        continue
                    }
                    let strVal: String?
                    if let s = v as? String {
                        strVal = s
                    } else if let n = v as? NSNumber {
                        strVal = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
                    } else if !(v is NSNull) {
                        strVal = "\(v)"
                    } else {
                        strVal = nil
                    }
                    if let strVal, isSafeHeaderComponent(strVal) {
                        headers[cleanKey] = strVal
                    }
                }
            }
            if let ct = (dict["contentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ct.isEmpty,
               isSafeHeaderComponent(ct),
               !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                headers["Content-Type"] = ct
            }
            if (dict["desktop"] as? Bool) == true,
               !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
                headers["User-Agent"] = HostHTTPClient.desktopUserAgent
            }
            if let b = dict["body"] as? String { body = Data(b.utf8) }
            if let enc = (dict["encoding"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !enc.isEmpty {
                encoding = enc
            }
        }
        return (method, headers, body, encoding)
    }

    internal static func encodeValue(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"e":"Encoding failed"}"#
        }
        return str
    }

    internal static func encodeError(_ message: String, cancelled: Bool = false) -> String {
        let obj: [String: Any] = ["e": message, "c": cancelled]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"e":"Unknown error"}"#
        }
        return str
    }
}
