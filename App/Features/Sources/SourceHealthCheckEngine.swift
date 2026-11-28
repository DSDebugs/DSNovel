import DSCore
import DSPluginKit
import Foundation
import Observation

/// 书源健康检测状态
enum SourceHealthState: String, Codable, Sendable, Equatable {
    case unknown
    case checking
    case available
    case invalid
    case needsLogin
}

/// 单书源最近一次健康检测结果（轻量持久化，零 SwiftData Schema 侵入）
struct SourceHealthRecord: Codable, Sendable, Equatable {
    let state: SourceHealthState
    let latencyMs: Int?
    let reason: String?
    let checkedAt: Date

    var badgeText: String? {
        switch state {
        case .unknown:
            return nil
        case .checking:
            return "检测中…"
        case .available:
            if let ms = latencyMs {
                return "可用 \(ms)ms"
            }
            return "可用"
        case .invalid:
            if let reason, !reason.isEmpty {
                return "已失效 · \(reason)"
            }
            return "已失效"
        case .needsLogin:
            return "需登录"
        }
    }
}

/// 书源一键健康检测引擎（3 并发限流 + 单源 8 秒超时 + 两级探活 + UserDefaults 轻量持久化）
@Observable
@MainActor
final class SourceHealthCheckEngine {
    static let storageKey = "dsnovel.v3.sourceHealthRecords"
    static let defaultTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let defaults: UserDefaults
    private var batchTask: Task<Void, Never>?

    private(set) var records: [String: SourceHealthRecord] = [:]
    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var currentSourceName = ""
    private(set) var hasCompletedBatch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedRecords()
    }

    var invalidSourceIDs: Set<String> {
        Set(records.compactMap { key, val in val.state == .invalid ? key : nil })
    }

    func record(for sourceID: String) -> SourceHealthRecord? {
        records[sourceID]
    }

    func availableCount(in sources: [SourceMetaDTO]) -> Int {
        sources.filter { records[$0.id]?.state == .available }.count
    }

    func invalidCount(in sources: [SourceMetaDTO]) -> Int {
        sources.filter { records[$0.id]?.state == .invalid }.count
    }

    func enabledInvalidSources(in sources: [SourceMetaDTO]) -> [SourceMetaDTO] {
        sources.filter { $0.isEnabled && records[$0.id]?.state == .invalid }
    }

    func cancel() {
        batchTask?.cancel()
        batchTask = nil
        isRunning = false
        currentSourceName = ""
        for (id, rec) in records where rec.state == .checking {
            records.removeValue(forKey: id)
        }
    }

    func clearResult(for sourceID: String) {
        records.removeValue(forKey: sourceID)
        persistRecords()
    }

    func startBatchCheck(
        sources: [SourceMetaDTO],
        loggedInSourceIDs: Set<String>,
        maxConcurrent: Int = 3,
        probe: @escaping @Sendable (SourceMetaDTO) async -> SourceHealthRecord
    ) {
        cancel()
        guard !sources.isEmpty else { return }
        isRunning = true
        hasCompletedBatch = false
        completedCount = 0
        totalCount = sources.count
        currentSourceName = sources.first?.name ?? ""

        for src in sources {
            records[src.id] = SourceHealthRecord(state: .checking, latencyMs: nil, reason: nil, checkedAt: Date())
        }

        let concurrency = max(1, min(3, maxConcurrent))
        batchTask = Task { [weak self] in
            guard let self else { return }
            var nextIndex = 0
            await withTaskGroup(of: (String, String, SourceHealthRecord).self) { group in
                while nextIndex < min(concurrency, sources.count) {
                    let src = sources[nextIndex]
                    nextIndex += 1
                    let needsLogin = SourceListHelper.needsLogin(src, loggedInSourceIDs: loggedInSourceIDs)
                    group.addTask {
                        if needsLogin {
                            return (src.id, src.name, SourceHealthRecord(state: .needsLogin, latencyMs: nil, reason: "未登录", checkedAt: Date()))
                        }
                        let res = await probe(src)
                        return (src.id, src.name, res)
                    }
                }

                while let (id, name, result) = await group.next() {
                    guard !Task.isCancelled else { break }
                    self.records[id] = result
                    self.completedCount += 1
                    self.currentSourceName = name
                    if nextIndex < sources.count {
                        let nextSrc = sources[nextIndex]
                        nextIndex += 1
                        let needsLogin = SourceListHelper.needsLogin(nextSrc, loggedInSourceIDs: loggedInSourceIDs)
                        group.addTask {
                            if needsLogin {
                                return (nextSrc.id, nextSrc.name, SourceHealthRecord(state: .needsLogin, latencyMs: nil, reason: "未登录", checkedAt: Date()))
                            }
                            let res = await probe(nextSrc)
                            return (nextSrc.id, nextSrc.name, res)
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.isRunning = false
            self.currentSourceName = ""
            self.hasCompletedBatch = true
            self.persistRecords()
        }
    }

    func checkSingle(
        source: SourceMetaDTO,
        loggedInSourceIDs: Set<String>,
        probe: @escaping @Sendable (SourceMetaDTO) async -> SourceHealthRecord
    ) async -> SourceHealthRecord {
        if SourceListHelper.needsLogin(source, loggedInSourceIDs: loggedInSourceIDs) {
            let rec = SourceHealthRecord(state: .needsLogin, latencyMs: nil, reason: "未登录", checkedAt: Date())
            records[source.id] = rec
            persistRecords()
            return rec
        }
        records[source.id] = SourceHealthRecord(state: .checking, latencyMs: nil, reason: nil, checkedAt: Date())
        let result = await probe(source)
        records[source.id] = result
        persistRecords()
        return result
    }

    /// 生产环境两级轻量探活（1. 发现页首屏 -> 2. 搜索「凡人」兜底，单源 8 秒超时防卡死）
    nonisolated static func probeSource(
        meta: SourceMetaDTO,
        runtime: PluginRuntime,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds
    ) async -> SourceHealthRecord {
        let start = Date()
        let outcome = await withTaskGroup(of: SourceHealthRecord?.self) { group in
            group.addTask {
                await executeTwoTierProbe(meta: meta, runtime: runtime, start: start)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return SourceHealthRecord(state: .invalid, latencyMs: nil, reason: "超时", checkedAt: Date())
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return outcome ?? SourceHealthRecord(state: .invalid, latencyMs: nil, reason: "超时", checkedAt: Date())
    }

    nonisolated private static func executeTwoTierProbe(
        meta: SourceMetaDTO,
        runtime: PluginRuntime,
        start: Date
    ) async -> SourceHealthRecord {
        var lastError: Error?
        if meta.methods.contains("discover") || meta.methods.contains("getDiscover") {
            do {
                let cats = try await runtime.discoverCategories(sourceID: meta.id)
                if let firstCat = cats.first {
                    let books = try await runtime.discoverBooks(sourceID: meta.id, categoryURL: firstCat.url, page: 1)
                    if !books.isEmpty {
                        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                        return SourceHealthRecord(state: .available, latencyMs: ms, reason: nil, checkedAt: Date())
                    }
                }
            } catch {
                lastError = error
            }
        }
        do {
            let books = try await runtime.search(sourceID: meta.id, keyword: "凡人", page: 1)
            if !books.isEmpty {
                let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
                return SourceHealthRecord(state: .available, latencyMs: ms, reason: nil, checkedAt: Date())
            }
            if let lastError {
                let (state, reason) = classifyError(lastError)
                return SourceHealthRecord(state: state, latencyMs: nil, reason: reason, checkedAt: Date())
            }
            return SourceHealthRecord(state: .invalid, latencyMs: nil, reason: "无返回", checkedAt: Date())
        } catch {
            let (state, reason) = classifyError(error)
            return SourceHealthRecord(state: state, latencyMs: nil, reason: reason, checkedAt: Date())
        }
    }

    nonisolated static func classifyError(_ error: Error) -> (SourceHealthState, String) {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("登录") || desc.contains("login") || desc.contains("401") || desc.contains("cookie") {
            return (.needsLogin, "需登录")
        }
        if let urlErr = error as? URLError {
            if urlErr.code == .timedOut { return (.invalid, "超时") }
            return (.invalid, "网络异常")
        }
        if desc.contains("timeout") || desc.contains("超时") {
            return (.invalid, "超时")
        }
        if desc.contains("decode") || desc.contains("json") || desc.contains("解析") || desc.contains("script") {
            return (.invalid, "解析异常")
        }
        return (.invalid, "不可用")
    }

    private func loadPersistedRecords() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: SourceHealthRecord].self, from: data) {
            records = decoded.filter { $0.value.state != .checking }
        }
    }

    private func persistRecords() {
        let clean = records.filter { $0.value.state != .checking }
        if let data = try? JSONEncoder().encode(clean) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
