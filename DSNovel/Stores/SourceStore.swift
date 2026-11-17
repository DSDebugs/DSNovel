import Foundation
import Observation
import SwiftData

enum SourceDisplayStatus: String, CaseIterable, Equatable, Sendable {
    case disabled
    case unavailable
    case needAuth
    case untested
    case available

    var title: String {
        switch self {
        case .disabled: return "已停用"
        case .unavailable: return "异常"
        case .needAuth: return "需登录"
        case .untested: return "未检测"
        case .available: return "可用"
        }
    }

    static func classify(_ source: PluginRecord) -> SourceDisplayStatus {
        if !source.isEnabled {
            return .disabled
        }
        if source.healthState == .unavailable {
            return .unavailable
        }
        if (source.requiresLogin && !source.loggedIn) || source.healthState == .needAuth {
            return .needAuth
        }
        if source.healthState == .untested {
            return .untested
        }
        return .available
    }
}

struct SourceHealthSummary: Equatable, Hashable, Sendable {
    var totalCount: Int
    var enabledCount: Int
    var availableCount: Int
    var needAuthCount: Int
    var unavailableCount: Int
    var untestedCount: Int
    var stoppedCount: Int

    static let empty = SourceHealthSummary(
        totalCount: 0,
        enabledCount: 0,
        availableCount: 0,
        needAuthCount: 0,
        unavailableCount: 0,
        untestedCount: 0,
        stoppedCount: 0
    )
}

enum SourceListFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "all"
    case available = "available"
    case needAuth = "needAuth"
    case unavailable = "unavailable"
    case untested = "untested"
    case disabled = "disabled"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .available: return "可用"
        case .needAuth: return "需登录"
        case .unavailable: return "异常"
        case .untested: return "未检测"
        case .disabled: return "已停用"
        }
    }
}

enum SourceSearchCapabilityScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "all"
    case discoverable = "discoverable"
    case searchable = "searchable"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .discoverable: return "可发现"
        case .searchable: return "可搜索"
        }
    }
}

@MainActor
@Observable
final class SourceStore {
    static let shared = SourceStore()

    var modelContext: ModelContext? {
        didSet {
            observeContextNotifications()
            refreshNow()
        }
    }

    var filter: SourceListFilter = .all {
        didSet { recomputeDerived() }
    }
    var capabilityScope: SourceSearchCapabilityScope = .all {
        didSet { recomputeDerived() }
    }
    var searchKeyword: String = "" {
        didSet { recomputeDerived() }
    }

    private(set) var hasLoadedOnce: Bool = false
    private(set) var allSources: [PluginRecord] = []
    private(set) var groups: [PluginGroup] = []
    private(set) var filteredSources: [PluginRecord] = []
    private(set) var pinnedSources: [PluginRecord] = []
    private(set) var discoverableSources: [PluginRecord] = []
    private(set) var searchableSources: [PluginRecord] = []
    private(set) var needAttention: [PluginRecord] = []
    private(set) var healthSummary: SourceHealthSummary = .empty
    private(set) var checkingSourceIDs: Set<String> = []
    private(set) var isCheckingAll: Bool = false

    var hasEnabledSource: Bool {
        healthSummary.enabledCount > 0
    }

    var customHealthChecker: (@Sendable (String) async -> SourceHealthCheckResult)?
    private var saveObserver: NSObjectProtocol?
    private var throttleTask: Task<Void, Never>?

    init() {}

    private func observeContextNotifications() {
        if let token = saveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    func scheduleRefresh() {
        throttleTask?.cancel()
        throttleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard let ctx = modelContext else { return }
        let srcDesc = FetchDescriptor<PluginRecord>(sortBy: [SortDescriptor(\PluginRecord.order)])
        let grpDesc = FetchDescriptor<PluginGroup>(sortBy: [SortDescriptor(\PluginGroup.order)])
        allSources = (try? ctx.fetch(srcDesc)) ?? []
        groups = (try? ctx.fetch(grpDesc)) ?? []
        hasLoadedOnce = true
        recomputeDerived()
    }

    func recomputeDerived() {
        let sortedAll = allSources.sorted { a, b in
            if a.searchPriorityScore != b.searchPriorityScore {
                return a.searchPriorityScore < b.searchPriorityScore
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        let enabled = sortedAll.filter(\.isEnabled)
        discoverableSources = enabled.filter(\.discoverable)
        searchableSources = enabled.filter(\.searchable)

        var available = 0
        var needAuth = 0
        var unavailable = 0
        var untested = 0
        var stopped = 0
        var unavailableList: [PluginRecord] = []
        var needAuthList: [PluginRecord] = []

        for s in sortedAll {
            switch SourceDisplayStatus.classify(s) {
            case .disabled:
                stopped += 1
            case .unavailable:
                unavailable += 1
                unavailableList.append(s)
            case .needAuth:
                needAuth += 1
                needAuthList.append(s)
            case .untested:
                untested += 1
            case .available:
                available += 1
            }
        }

        healthSummary = SourceHealthSummary(
            totalCount: sortedAll.count,
            enabledCount: enabled.count,
            availableCount: available,
            needAuthCount: needAuth,
            unavailableCount: unavailable,
            untestedCount: untested,
            stoppedCount: stopped
        )
        needAttention = unavailableList + needAuthList

        let kw = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sortedAll.filter { s in
            let status = SourceDisplayStatus.classify(s)
            switch filter {
            case .all:
                break
            case .available:
                if status != .available { return false }
            case .needAuth:
                if status != .needAuth { return false }
            case .unavailable:
                if status != .unavailable { return false }
            case .untested:
                if status != .untested { return false }
            case .disabled:
                if status != .disabled { return false }
            }
            switch capabilityScope {
            case .all:
                break
            case .discoverable:
                if !s.discoverable { return false }
            case .searchable:
                if !s.searchable { return false }
            }
            if !kw.isEmpty {
                return s.name.lowercased().contains(kw) || s.siteURL.lowercased().contains(kw)
            }
            return true
        }

        filteredSources = filtered
        pinnedSources = filtered.filter(\.isPinned)
    }

    func markLoggedIn(sourceID: String) {
        guard let src = source(for: sourceID) else { return }
        src.loggedIn = true
        if src.healthState == .needAuth {
            src.lastCheckStatus = SourceHealthState.healthy.rawValue
        }
        try? modelContext?.save()
        recomputeDerived()
    }

    func markAuthExpired(sourceID: String) {
        guard let src = source(for: sourceID), src.loggedIn else { return }
        src.loggedIn = false
        try? modelContext?.save()
        recomputeDerived()
    }

    func sourceName(for sourceID: String) -> String {
        allSources.first(where: { $0.id == sourceID })?.name ?? sourceID
    }

    func source(for sourceID: String) -> PluginRecord? {
        allSources.first(where: { $0.id == sourceID })
    }

    func setEnabled(_ enabled: Bool, forIDs ids: Set<String>) {
        for s in allSources where ids.contains(s.id) {
            s.isEnabled = enabled
        }
        try? modelContext?.save()
        refreshNow()
    }

    func moveSources(_ ids: Set<String>, toGroupID groupID: String?) {
        for s in allSources where ids.contains(s.id) {
            s.groupID = groupID
        }
        try? modelContext?.save()
        refreshNow()
    }

    func deleteSources(_ ids: Set<String>, alsoRemoveShelfAndDownloads: Bool = false) async {
        guard let ctx = modelContext else { return }
        let targets = allSources.filter { ids.contains($0.id) }
        for target in targets {
            await PluginRuntime.shared.removeSourceFilesAndCache(sourceID: target.id, packageID: target.packageID)
            if alsoRemoveShelfAndDownloads {
                let sid = target.id
                let bDesc = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.sourceID == sid })
                if let books = try? ctx.fetch(bDesc) {
                    for b in books {
                        DownloadManager.shared.removeDownloads(forBookID: b.id)
                        ctx.delete(b)
                    }
                }
            }
            ctx.delete(target)
        }
        try? ctx.save()
        refreshNow()
    }

    @discardableResult
    func checkSource(_ source: PluginRecord) async -> SourceHealthCheckResult {
        checkingSourceIDs.insert(source.id)
        defer { checkingSourceIDs.remove(source.id) }

        let sid = source.id
        let result: SourceHealthCheckResult
        if let custom = customHealthChecker {
            result = await custom(sid)
        } else {
            result = await PluginRuntime.shared.checkSourceHealth(sourceID: sid)
        }
        source.lastCheckStatus = result.state.rawValue
        source.lastLatencyMs = result.latencyMs
        source.lastCheckMessage = result.message
        source.lastCheckedAt = result.checkedAt
        try? modelContext?.save()
        recomputeDerived()
        return result
    }

    func checkSources(_ sources: [PluginRecord]? = nil) async {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        defer { isCheckingAll = false }

        let targets = sources ?? allSources.filter(\.isEnabled)
        guard !targets.isEmpty else { return }

        let chunkSize = 3
        var start = 0
        while start < targets.count {
            let end = min(start + chunkSize, targets.count)
            let slice = Array(targets[start..<end])
            for s in slice { checkingSourceIDs.insert(s.id) }

            let custom = customHealthChecker
            let targetIDs = slice.map(\.id)
            let results = await withTaskGroup(of: SourceHealthCheckResult.self) { group in
                for sid in targetIDs {
                    group.addTask {
                        if let custom {
                            return await custom(sid)
                        }
                        return await PluginRuntime.shared.checkSourceHealth(sourceID: sid)
                    }
                }
                var list: [SourceHealthCheckResult] = []
                for await r in group {
                    list.append(r)
                }
                return list
            }

            let map = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0) })
            for s in slice {
                checkingSourceIDs.remove(s.id)
                if let res = map[s.id] {
                    s.lastCheckStatus = res.state.rawValue
                    s.lastLatencyMs = res.latencyMs
                    s.lastCheckMessage = res.message
                    s.lastCheckedAt = res.checkedAt
                }
            }
            try? modelContext?.save()
            recomputeDerived()
            start = end
        }
    }
}
