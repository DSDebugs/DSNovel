import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto

@objc protocol JsHostBridgeExports: JSExport {
    func getSourceId() -> String
    @objc(userAgent:) func userAgent(_ desktop: Bool) -> String
    func webViewUA() -> String
    @objc(request::) func request(_ url: String, _ optionsJson: String?) -> String
    @objc(requestAll:::) func requestAll(_ urlsJson: String, _ optionsJson: String?, _ concurrency: Int) -> String
    @objc(finalUrl::) func finalUrl(_ url: String, _ optionsJson: String?) -> String
    @objc(fetch::) func fetch(_ url: String, _ optionsJson: String?) -> String
    @objc(status::) func status(_ url: String, _ optionsJson: String?) -> String
    @objc(parseHtml::) func parseHtml(_ html: String, _ baseUrl: String?) -> JsElement
    @objc(render:::) func render(_ url: String, _ optionsJson: String?, _ parseFn: JSValue?) -> String
    @objc(sniff:::) func sniff(_ url: String, _ optionsJson: String?, _ validateFn: JSValue?) -> String
    @objc(cookies:) func cookies(_ url: String) -> String
    @objc(getPref:) func getPref(_ key: String) -> String?
    @objc(setPref::) func setPref(_ key: String, _ value: String?)
    @objc(toast:) func toast(_ message: String)
    @objc(log:) func log(_ message: String)
    @objc(progress:) func progress(_ info: String?)
    @objc(sleep:) func sleep(_ ms: Int)
    @objc(readCache:) func readCache(_ name: String) -> String?
    @objc(writeCache::) func writeCache(_ name: String, _ text: String)
    @objc(cacheAge:) func cacheAge(_ name: String) -> Double
    @objc(base64Decode:) func base64Decode(_ input: String) -> String
    @objc(base64Encode:) func base64Encode(_ input: String) -> String
    @objc(md5:) func md5(_ input: String) -> String
    @objc(sha256:) func sha256(_ input: String) -> String
    @objc(aesEcbDecrypt::) func aesEcbDecrypt(_ base64Data: String, _ keyHex: String) -> String
    func uuid() -> String
    @objc(htmlDecode:) func htmlDecode(_ input: String) -> String
}

@objc protocol JsRootBridgeExports: JSExport {
    @objc(host::) func host(_ sourceId: String, _ sourceName: String) -> JsHostBridge
}

@objc final class JsRootBridge: NSObject, JsRootBridgeExports {
    let packageID: String

    init(packageID: String) {
        self.packageID = packageID
        super.init()
    }

    func host(_ sourceId: String, _ sourceName: String) -> JsHostBridge {
        JsHostBridge(packageID: packageID, sourceId: sourceId, sourceName: sourceName)
    }
}

/// 插件宿主桥接实现：支持 URLSession 同步桥接、UTF-8/GBK 编码自动识别、CommonCrypto AES-ECB/MD5、隔离存储与 Cookie 共享
@objc final class JsHostBridge: NSObject, JsHostBridgeExports {
    let packageID: String
    let sourceId: String
    let sourceName: String

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    init(packageID: String, sourceId: String, sourceName: String) {
        self.packageID = packageID
        self.sourceId = sourceId
        self.sourceName = sourceName
        super.init()
    }

    func getSourceId() -> String { sourceId }

    func userAgent(_ desktop: Bool) -> String {
        desktop ? Self.desktopUA : Self.mobileUA
    }

    func webViewUA() -> String {
        Self.mobileUA
    }

    func request(_ url: String, _ optionsJson: String?) -> String {
        do {
            let (statusCode, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            guard (200..<300).contains(statusCode) else {
                return wrapError("HTTP \(statusCode)")
            }
            return wrapValue(body)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func requestAll(_ urlsJson: String, _ optionsJson: String?, _ concurrency: Int) -> String {
        guard let data = urlsJson.data(using: .utf8),
              let urls = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return wrapValue([String?]())
        }
        let results: [String?] = urls.map { u in
            guard let (code, body, _) = try? performSyncHTTP(url: u, optionsJson: optionsJson, headOnly: false),
                  (200..<300).contains(code) else {
                return nil
            }
            return body
        }
        return wrapValue(results)
    }

    func finalUrl(_ url: String, _ optionsJson: String?) -> String {
        do {
            let (_, _, resolved) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: true)
            return wrapValue(resolved)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func fetch(_ url: String, _ optionsJson: String?) -> String {
        do {
            let (statusCode, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            return wrapValue(["status": statusCode, "body": body])
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func status(_ url: String, _ optionsJson: String?) -> String {
        do {
            let (statusCode, _, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: true)
            return wrapValue(statusCode)
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func parseHtml(_ html: String, _ baseUrl: String?) -> JsElement {
        JsElement.parse(html: html, baseURL: baseUrl ?? "")
    }

    func render(_ url: String, _ optionsJson: String?, _ parseFn: JSValue?) -> String {
        let htmlResult = request(url, optionsJson)
        if let parseFn, !parseFn.isUndefined, !parseFn.isNull,
           let rawData = htmlResult.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
           let html = obj["v"] as? String {
            let doc = parseHtml(html, url)
            if let parsed = parseFn.call(withArguments: [doc, html, url]), !parsed.isUndefined {
                return wrapValue(parsed.toObject() ?? "")
            }
        }
        return htmlResult
    }

    func sniff(_ url: String, _ optionsJson: String?, _ validateFn: JSValue?) -> String {
        do {
            let (_, body, _) = try performSyncHTTP(url: url, optionsJson: optionsJson, headOnly: false)
            let pattern = "https?://[^\\s\"'<>]+\\.(?:m4a|mp3|m3u8|aac|flac|ogg|wav)(?:\\?[^\\s\"'<>]*)?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let ns = body as NSString
                if let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                    return wrapValue(ns.substring(with: match.range))
                }
            }
            return wrapError("未嗅探到有效音频流地址")
        } catch {
            return wrapError(error.localizedDescription)
        }
    }

    func cookies(_ url: String) -> String {
        guard let targetURL = URL(string: url),
              let items = HTTPCookieStorage.shared.cookies(for: targetURL) else {
            return ""
        }
        return items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func getPref(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: "plugin_pref_\(sourceId)_\(key)")
    }

    func setPref(_ key: String, _ value: String?) {
        let storageKey = "plugin_pref_\(sourceId)_\(key)"
        if let value {
            UserDefaults.standard.set(value, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    func toast(_ message: String) {
        Task { @MainActor in
            ToastManager.shared.show(message)
        }
    }

    func log(_ message: String) {
        #if DEBUG
        print("[Plugin:\(sourceName)] \(message)")
        #endif
    }

    func progress(_ info: String?) {}

    func sleep(_ ms: Int) {
        let clamped = min(max(ms, 0), 5000)
        Thread.sleep(forTimeInterval: Double(clamped) / 1000.0)
    }

    func readCache(_ name: String) -> String? {
        let url = cacheFileURL(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func writeCache(_ name: String, _ text: String) {
        let url = cacheFileURL(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cacheAge(_ name: String) -> Double {
        let url = cacheFileURL(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return -1
        }
        return Date().timeIntervalSince(modDate) * 1000.0
    }

    func base64Decode(_ input: String) -> String {
        guard let data = Data(base64Encoded: input) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    func md5(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func aesEcbDecrypt(_ base64Data: String, _ keyHex: String) -> String {
        guard let cipherData = Data(base64Encoded: base64Data),
              let keyData = Self.dataFromHex(keyHex),
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(keyData.count) else {
            return ""
        }
        let outLength = cipherData.count + kCCBlockSizeAES128
        var outBuffer = [UInt8](repeating: 0, count: outLength)
        var numBytesDecrypted: size_t = 0

        let status = cipherData.withUnsafeBytes { cipherPtr in
            keyData.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyPtr.baseAddress,
                    keyData.count,
                    nil,
                    cipherPtr.baseAddress,
                    cipherData.count,
                    &outBuffer,
                    outLength,
                    &numBytesDecrypted
                )
            }
        }
        guard status == kCCSuccess else { return "" }
        let plainData = Data(outBuffer.prefix(numBytesDecrypted))
        return String(data: plainData, encoding: .utf8) ?? ""
    }

    func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    func htmlDecode(_ input: String) -> String {
        HTMLTokenizer.decodeHTMLEntities(input)
    }

    // MARK: - 内部辅助方法

    private func cacheFileURL(_ name: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("PluginCache/\(sourceId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = md5(name)
        return dir.appendingPathComponent(safeName + ".txt")
    }

    private func performSyncHTTP(url: String, optionsJson: String?, headOnly: Bool) throws -> (Int, String, String) {
        guard let requestURL = URL(string: url) else {
            throw URLError(.badURL)
        }
        var opts: [String: Any] = [:]
        if let optionsJson, let d = optionsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            opts = parsed
        }

        var req = URLRequest(url: requestURL, timeoutInterval: 15)
        let desktop = (opts["desktop"] as? Bool) ?? false
        req.setValue(userAgent(desktop), forHTTPHeaderField: "User-Agent")

        if headOnly {
            req.httpMethod = "HEAD"
        } else if let method = opts["method"] as? String {
            req.httpMethod = method.uppercased()
        }

        if let headers = opts["headers"] as? [String: String] {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let contentType = opts["contentType"] as? String {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let bodyStr = opts["body"] as? String {
            req.httpBody = bodyStr.data(using: .utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            responseData = data
            httpResponse = resp as? HTTPURLResponse
            requestError = err
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        if let requestError {
            throw requestError
        }
        let statusCode = httpResponse?.statusCode ?? 200
        let finalURL = httpResponse?.url?.absoluteString ?? url
        let rawData = responseData ?? Data()
        let explicitEncoding = opts["encoding"] as? String
        let text = Self.decodeText(data: rawData, response: httpResponse, explicitEncoding: explicitEncoding)
        return (statusCode, text, finalURL)
    }

    static func decodeText(data: Data, response: HTTPURLResponse?, explicitEncoding: String?) -> String {
        guard !data.isEmpty else { return "" }
        if let exp = explicitEncoding?.lowercased(), exp.contains("gb") {
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let str = String(data: data, encoding: String.Encoding(rawValue: gbk)) {
                return str
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gbkStr = String(data: data, encoding: String.Encoding(rawValue: gbk)) {
            return gbkStr
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func wrapValue(_ value: Any) -> String {
        let payload: [String: Any] = ["v": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"v\":null}"
        }
        return str
    }

    private func wrapError(_ message: String) -> String {
        let payload: [String: Any] = ["e": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"e\":\"Error\"}"
        }
        return str
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}
