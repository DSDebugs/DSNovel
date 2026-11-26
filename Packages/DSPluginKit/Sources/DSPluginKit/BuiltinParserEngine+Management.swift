import DSCore
import Foundation

extension BuiltinParserEngine {
    /// 冷启扫描磁盘恢复已安装解析器，并校验 script.js 的 SHA-256 完整性（ARC-04）
    public func loadPersistedParsers() -> Int {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var loaded = 0
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            let scriptURL = dir.appendingPathComponent("script.js")
            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(BuiltinParserMetaDTO.self, from: metaData),
                  let scriptText = try? String(contentsOf: scriptURL, encoding: .utf8) else { continue }
            if DSCrypto.sha256Hex(scriptText) == meta.sha256 {
                installedParsers[meta.id] = meta
                cachedScriptBodies[meta.id] = scriptText
                loaded += 1
            } else {
                appendLog("跳过完整性校验失败的解析器：\(meta.name)")
            }
        }
        return loaded
    }

    public func listParsers() -> [BuiltinParserMetaDTO] {
        installedParsers.values.sorted { $0.name < $1.name }
    }

    public func recentLogs(limit: Int = 80) -> [String] {
        Array(incrementalLogs.suffix(max(0, limit)).map(\.text))
    }


    /// 从章节地址提取纯数字 trackId（兼容 xm:123 / trackId=123）
    internal static func extractTrackID(from chapterURL: String) -> String? {
        if let range = chapterURL.range(of: #"xm:(\d+)"#, options: .regularExpression) {
            let digits = chapterURL[range].dropFirst(3)
            if !digits.isEmpty { return String(digits) }
        }
        if let range = chapterURL.range(of: #"trackId=(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let sub = String(chapterURL[range])
            if let eq = sub.firstIndex(of: "=") {
                let digits = sub[sub.index(after: eq)...]
                if !digits.isEmpty { return String(digits) }
            }
        }
        return nil
    }

    /// 调用内置解析器脚本的 checkStatus() 进行自检并刷新健康状态（复用 executeParserMethod）
    public func checkStatus(id: String) async throws -> BuiltinParserStatusDTO {
        guard let matched = installedParsers[id] else {
            throw PluginSecurityError.scriptError("未找到内置解析器：\(id)")
        }
        let rawOut = try await executeParserMethod(matched: matched, method: "checkStatus", argsJSON: "[]", timeoutSeconds: 30.0)
        guard let outData = rawOut.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            markHealth(id: matched.id, status: .failed)
            return BuiltinParserStatusDTO(ok: false, message: "自检返回格式异常")
        }
        if (envelope["c"] as? Bool) == true { throw CancellationError() }
        if let errMsg = envelope["e"] as? String {
            markHealth(id: matched.id, status: .degraded)
            appendLog("[\(matched.name)] 自检失败：\(errMsg)")
            return BuiltinParserStatusDTO(ok: false, message: errMsg)
        }
        guard let innerStr = envelope["v"] as? String,
              let innerData = innerStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            return BuiltinParserStatusDTO(ok: true, message: "该解析器未实现 checkStatus()，已跳过自检")
        }
        let ok = (inner["ok"] as? Bool) ?? false
        let message = (inner["message"] as? String) ?? (ok ? "自检通过" : "自检未通过")
        let latencyMs = (inner["latencyMs"] as? Int) ?? 0
        let nickname = (inner["nickname"] as? String) ?? ""
        let vipExpireAt = (inner["vipExpireAt"] as? String) ?? ""
        let maxLevelNote = (inner["maxLevelNote"] as? String) ?? ""
        markHealth(id: matched.id, status: ok ? .healthy : .degraded)
        appendLog("[\(matched.name)] 自检\(ok ? "通过" : "未通过")：\(message)")
        return BuiltinParserStatusDTO(
            ok: ok,
            message: message,
            latencyMs: latencyMs,
            nickname: nickname,
            vipExpireAt: vipExpireAt,
            maxLevelNote: maxLevelNote
        )
    }

    /// 判断指定书源/章节是否命中支持多档音质切换的已启用内置解析器
    public func supportsMultiQuality(sourceID: String, chapterURL: String) -> Bool {
        guard let matched = matchParser(sourceID: sourceID, chapterURL: chapterURL, forDownload: false) else {
            return false
        }
        return matched.qualities.count > 1
    }

    public func clearParserCache(id: String) -> Int {
        let dir = parserDir(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files where file.pathExtension == "cache" {
            if (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        let name = installedParsers[id]?.name ?? id
        appendLog("已清理 \(name) 缓存文件 \(removed) 项")
        return removed
    }

    /// 读写内置解析器配置项（与脚本内 host.getPref / host.setPref 共享 ownerID 隔离存储）
    public func getPref(parserID: String, key: String) async -> String? {
        await cookieVault.getSecret(ownerID: parserID, key: key)
    }

    public func setPref(parserID: String, key: String, value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        await cookieVault.setSecret((trimmed?.isEmpty == true) ? nil : trimmed, ownerID: parserID, key: key)
        appendLog("已更新解析器 \(parserID) 配置项 \(key)")
    }

    /// 启用或禁用内置解析器并同步落盘 meta.json
    public func setEnabled(id: String, enabled: Bool) throws {
        guard let old = installedParsers[id] else { return }
        let updated = BuiltinParserMetaDTO(
            id: old.id, name: old.name, version: old.version, author: old.author,
            summary: old.summary, hosts: old.hosts, networkHosts: old.networkHosts, sourceIDs: old.sourceIDs,
            qualities: old.qualities, supportsPlayback: old.supportsPlayback,
            supportsDownload: old.supportsDownload, requiresCookie: old.requiresCookie,
            sha256: old.sha256, isEnabled: enabled, healthStatus: old.healthStatus
        )
        let metaURL = parserDir(for: id).appendingPathComponent("meta.json")
        let metaData = try JSONEncoder().encode(updated)
        try metaData.write(to: metaURL, options: [.atomic])
        installedParsers[id] = updated
        appendLog("\(enabled ? "已启用" : "已停用")解析器 \(old.name)")
    }

    /// 删除已安装的内置解析器目录
    public func deleteParser(id: String) throws {
        let dir = parserDir(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        cachedScriptBodies.removeValue(forKey: id)
        let name = installedParsers.removeValue(forKey: id)?.name ?? id
        appendLog("已移除内置解析器 \(name)")
    }

    /// 清空当前内存中的解析与脚本诊断日志
    public func clearLogs() {
        incrementalLogs.removeAll()
        logsClearedAt = Date()
    }

    /// 按真实时间戳升序归并引擎日志与脚本内 host.log(...) 诊断日志，确保时间线严格准确
    public func combinedLogs(limit: Int = 120) async -> [String] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }
        let prefixes = Set(installedParsers.values.flatMap { ["[\($0.id)]", "[\($0.name)]"] })
        let diagEntries = await logger.snapshot(limit: 200)
        let cutoff = logsClearedAt
        var merged: [(timestamp: Date, order: Int, text: String)] = []
        var seq = 0

        for entry in diagEntries where entry.category == .plugin {
            if let cutoff, entry.timestamp < cutoff { continue }
            guard prefixes.contains(where: { entry.message.hasPrefix($0) }) else { continue }
            let stamp = Self.formatTimeStamp(entry.timestamp)
            merged.append((entry.timestamp, seq, "[\(stamp)] \(entry.message)"))
            seq += 1
        }
        for item in incrementalLogs {
            merged.append((item.timestamp, seq, item.text))
            seq += 1
        }
        merged.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.order < rhs.order
        }
        return Array(merged.suffix(safeLimit).map(\.text))
    }

    /// AUD-47：写入临时子目录并通过 replaceItemAt 原子替换目标目录，保障崩溃一致性并保留既有 .cache 文件
    internal func atomicWritePair(id: String, scriptBody: String, meta: BuiltinParserMetaDTO) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        let targetDir = parserDir(for: id)
        let stagingDir = storageDir.appendingPathComponent(
            ".staging-\(DSCrypto.sha256Hex(id).prefix(12))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        do {
            // 升级时继承既有 .cache 文件，避免原子替换目录导致直链/校验缓存丢失
            if fm.fileExists(atPath: targetDir.path),
               let existingFiles = try? fm.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil) {
                for file in existingFiles where file.pathExtension == "cache" {
                    let dst = stagingDir.appendingPathComponent(file.lastPathComponent)
                    try? fm.copyItem(at: file, to: dst)
                }
            }
            let metaData = try JSONEncoder().encode(meta)
            try Data(scriptBody.utf8).write(to: stagingDir.appendingPathComponent("script.js"), options: [.atomic])
            try metaData.write(to: stagingDir.appendingPathComponent("meta.json"), options: [.atomic])
            if fm.fileExists(atPath: targetDir.path) {
                _ = try fm.replaceItemAt(targetDir, withItemAt: stagingDir)
            } else {
                try fm.moveItem(at: stagingDir, to: targetDir)
            }
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
    }

    internal func matchParser(sourceID: String, chapterURL: String, forDownload: Bool) -> BuiltinParserMetaDTO? {
        let host = URL(string: chapterURL)?.host?.lowercased() ?? ""
        let candidates = installedParsers.values.filter { p in
            guard p.isEnabled else { return false }
            if forDownload && !p.supportsDownload { return false }
            if !forDownload && !p.supportsPlayback { return false }
            if p.sourceIDs.contains(sourceID) { return true }
            return p.hosts.contains { allowed in
                var clean = allowed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean.hasPrefix("*.") { clean = String(clean.dropFirst(2)) }
                clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return !clean.isEmpty && (host == clean || host.hasSuffix("." + clean))
            }
        }
        return candidates.sorted { lhs, rhs in
            let lExact = lhs.sourceIDs.contains(sourceID)
            let rExact = rhs.sourceIDs.contains(sourceID)
            if lExact != rExact { return lExact }
            if lhs.version != rhs.version { return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending }
            return lhs.id < rhs.id
        }.first
    }

    internal func markHealth(id: String, status: ParserHealthStatus) {
        guard let old = installedParsers[id] else { return }
        installedParsers[id] = BuiltinParserMetaDTO(
            id: old.id, name: old.name, version: old.version, author: old.author,
            summary: old.summary, hosts: old.hosts, networkHosts: old.networkHosts, sourceIDs: old.sourceIDs,
            qualities: old.qualities, supportsPlayback: old.supportsPlayback,
            supportsDownload: old.supportsDownload, requiresCookie: old.requiresCookie,
            sha256: old.sha256, isEnabled: old.isEnabled, healthStatus: status
        )
    }

    internal func parserDir(for id: String) -> URL {
        storageDir.appendingPathComponent(DSCrypto.sha256Hex(id), isDirectory: true)
    }

    internal func logResolveSuccess(
        parserName: String,
        chapterTitle: String,
        tier: AudioQualityTier,
        bitrate: Int?,
        forDownload: Bool,
        isTrial: Bool
    ) {
        let mode = forDownload ? "下载" : "播放"
        let rateText = bitrate.map { " \($0)kbps" } ?? ""
        let trialText = isTrial ? "（试听）" : ""
        appendLog("[\(parserName)] \(mode)解析成功：\(chapterTitle) · \(tier.displayName)\(rateText)\(trialText)")
    }

    internal static func formatTimeStamp(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }

    internal func appendLog(_ line: String) {
        let now = Date()
        let stamp = Self.formatTimeStamp(now)
        incrementalLogs.append(EngineLogItem(timestamp: now, text: "[\(stamp)] \(line)"))
        if incrementalLogs.count > 200 {
            incrementalLogs.removeFirst(incrementalLogs.count - 200)
        }
    }

    /// R4：优先按脚本实际生效档位（actualLevel / actualQuality）映射 AudioQualityTier
    internal static func resolveActualQualityTier(
        from inner: [String: Any],
        fallback: AudioQualityTier
    ) -> AudioQualityTier {
        if let actualLevel = inner["actualLevel"] as? Int {
            switch actualLevel {
            case ...0: return .saver
            case 1: return .standard
            default: return .high
            }
        }
        if let actualQuality = inner["actualQuality"] as? String,
           let mapped = AudioQualityTier.fromParserToken(actualQuality) {
            return mapped
        }
        return fallback
    }
}
