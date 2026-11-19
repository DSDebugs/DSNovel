import Foundation
import Observation
import SwiftData
import WebKit

struct GroupedSourceSection: Identifiable {
    let id: String
    let title: String
    let groupID: String?
    let sources: [PluginRecord]
}

enum SourceOrganizeRow: Identifiable {
    case groupHeader(groupID: String?, title: String, count: Int)
    case source(PluginRecord)

    var id: String {
        switch self {
        case .groupHeader(let gid, _, _):
            return "header::\(gid ?? "__ungrouped__")"
        case .source(let src):
            return "source::\(src.id)"
        }
    }
}

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

    var sortedGroups: [PluginGroup] {
        groups.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func memberCount(forGroupID groupID: String?) -> Int {
        let validGroupIDs = Set(groups.map(\.id))
        return allSources.filter { src in
            if let groupID {
                return src.groupID == groupID
            } else {
                guard let gid = src.groupID, !gid.isEmpty else { return true }
                return !validGroupIDs.contains(gid)
            }
        }.count
    }

    func recomputeDerived() {
        let groupRankByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: sortedGroups.enumerated().map { ($0.element.id, $0.offset) }
        )
        let ungroupedRank = groupRankByID.count
        let sortedAll = allSources.sorted { a, b in
            let rankA = a.groupID.flatMap { groupRankByID[$0] } ?? ungroupedRank
            let rankB = b.groupID.flatMap { groupRankByID[$0] } ?? ungroupedRank
            if rankA != rankB { return rankA < rankB }
            if a.order != b.order { return a.order < b.order }
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

    func groupedSections(from sources: [PluginRecord], includeEmptyGroups: Bool) -> [GroupedSourceSection] {
        let sortedGroups = groups.sorted { $0.order < $1.order }
        let validGroupIDs = Set(sortedGroups.map(\.id))
        var result: [GroupedSourceSection] = []

        for group in sortedGroups {
            let members = sources
                .filter { $0.groupID == group.id }
                .sorted { a, b in
                    if a.order != b.order { return a.order < b.order }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            if includeEmptyGroups || !members.isEmpty {
                result.append(
                    GroupedSourceSection(
                        id: "group-\(group.id)",
                        title: group.name,
                        groupID: group.id,
                        sources: members
                    )
                )
            }
        }

        let ungrouped = sources
            .filter { src in
                guard let gid = src.groupID, !gid.isEmpty else { return true }
                return !validGroupIDs.contains(gid)
            }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        if !ungrouped.isEmpty || result.isEmpty {
            result.append(
                GroupedSourceSection(
                    id: "group-ungrouped",
                    title: sortedGroups.isEmpty ? "全部书源" : "未分组",
                    groupID: nil,
                    sources: ungrouped
                )
            )
        }
        return result
    }

    func moveSources(_ ids: Set<String>, toGroupID groupID: String?) {
        let existingInTarget = allSources
            .filter { $0.groupID == groupID && !ids.contains($0.id) }
            .sorted { $0.order < $1.order }
        var nextOrder = (existingInTarget.last?.order ?? -1) + 1
        for s in allSources where ids.contains(s.id) {
            s.groupID = groupID
            s.order = nextOrder
            nextOrder += 1
        }
        try? modelContext?.save()
        refreshNow()
    }

    func reorderSources(inGroupID groupID: String?, from sourceOffsets: IndexSet, to destinationOffset: Int) {
        let validGroupIDs = Set(groups.map(\.id))
        var members = allSources.filter { src in
            if let groupID {
                return src.groupID == groupID
            } else {
                guard let gid = src.groupID, !gid.isEmpty else { return true }
                return !validGroupIDs.contains(gid)
            }
        }.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !members.isEmpty else { return }

        let movingItems = sourceOffsets.map { members[$0] }
        for index in sourceOffsets.sorted(by: >) {
            members.remove(at: index)
        }
        let adjustedDest = destinationOffset - sourceOffsets.filter { $0 < destinationOffset }.count
        let clampedDest = max(0, min(adjustedDest, members.count))
        members.insert(contentsOf: movingItems, at: clampedDest)

        for (idx, item) in members.enumerated() {
            item.groupID = groupID
            item.order = idx
        }
        try? modelContext?.save()
        refreshNow()
    }

    /// 构建整理模式下的扁平可拖拽列表（包含所有分组标题及末尾「未分组」，支持同组调序与跨分组拖动）
    func buildOrganizeRows() -> [SourceOrganizeRow] {
        let orderedGroups = sortedGroups
        let validGroupIDs = Set(orderedGroups.map(\.id))
        var rows: [SourceOrganizeRow] = []

        for group in orderedGroups {
            let members = allSources
                .filter { $0.groupID == group.id }
                .sorted { a, b in
                    if a.order != b.order { return a.order < b.order }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            rows.append(.groupHeader(groupID: group.id, title: group.name, count: members.count))
            for src in members {
                rows.append(.source(src))
            }
        }

        let ungrouped = allSources
            .filter { src in
                guard let gid = src.groupID, !gid.isEmpty else { return true }
                return !validGroupIDs.contains(gid)
            }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        rows.append(.groupHeader(
            groupID: nil,
            title: orderedGroups.isEmpty ? "全部书源" : "未分组",
            count: ungrouped.count
        ))
        for src in ungrouped {
            rows.append(.source(src))
        }
        return rows
    }

    /// 处理整理模式下的扁平拖拽移动（自动同步跨分组 groupID 与组内 order）
    func applyOrganizeMove(rows currentRows: [SourceOrganizeRow], from offsets: IndexSet, to destination: Int) {
        guard !currentRows.isEmpty else { return }
        var updated = currentRows
        let moving = offsets.map { updated[$0] }
        // 仅允许移动书源行
        guard moving.allSatisfy({ if case .source = $0 { return true } else { return false } }) else { return }

        for idx in offsets.sorted(by: >) {
            updated.remove(at: idx)
        }
        let adjustedDest = destination - offsets.filter { $0 < destination }.count
        // 若拖到首个分组标题之上，自动落到首个分组标题下方首位
        let minAllowedIndex = (updated.first.map { if case .groupHeader = $0 { return 1 } else { return 0 } }) ?? 0
        let clampedDest = max(minAllowedIndex, min(adjustedDest, updated.count))
        updated.insert(contentsOf: moving, at: clampedDest)

        var activeGroupID: String? = nil
        var orderInGroup = 0
        for row in updated {
            switch row {
            case .groupHeader(let gid, _, _):
                activeGroupID = gid
                orderInGroup = 0
            case .source(let src):
                src.groupID = activeGroupID
                src.order = orderInGroup
                orderInGroup += 1
            }
        }
        try? modelContext?.save()
        refreshNow()
    }

    @discardableResult
    func createGroup(named rawName: String) -> PluginGroup? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }
        let nextOrder = (sortedGroups.last?.order ?? -1) + 1
        let group = PluginGroup(name: trimmed, order: nextOrder)
        modelContext?.insert(group)
        try? modelContext?.save()
        refreshNow()
        return group
    }

    @discardableResult
    func renameGroup(_ group: PluginGroup, to rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let duplicate = groups.contains { $0.id != group.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !duplicate else { return false }
        group.name = trimmed
        try? modelContext?.save()
        refreshNow()
        return true
    }

    func reorderGroups(from offsets: IndexSet, to destination: Int) {
        var ordered = sortedGroups
        guard !ordered.isEmpty else { return }
        let moving = offsets.map { ordered[$0] }
        for idx in offsets.sorted(by: >) {
            ordered.remove(at: idx)
        }
        let adjustedDest = destination - offsets.filter { $0 < destination }.count
        let clampedDest = max(0, min(adjustedDest, ordered.count))
        ordered.insert(contentsOf: moving, at: clampedDest)
        for (idx, grp) in ordered.enumerated() {
            grp.order = idx
        }
        try? modelContext?.save()
        refreshNow()
    }

    func deleteGroup(_ group: PluginGroup) {
        let targetID = group.id
        for src in allSources where src.groupID == targetID {
            src.groupID = nil
        }
        modelContext?.delete(group)
        try? modelContext?.save()
        refreshNow()
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

    func logoutSource(_ source: PluginRecord) async {
        let urls = [source.siteURL, source.loginURL]
        await CookieSync.clearCookies(for: urls, sourceID: source.id)
        await clearWebKitData(for: urls)
        source.loggedIn = false
        if source.healthState == .healthy || source.healthState == .slow {
            source.lastCheckStatus = SourceHealthState.needAuth.rawValue
        }
        try? modelContext?.save()
        recomputeDerived()
    }

    private func clearWebKitData(for urlStrings: [String]) async {
        let targetDomains: Set<String> = Set(
            urlStrings.compactMap { raw -> String? in
                guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let host = url.host?.lowercased(), !host.isEmpty else { return nil }
                return host
            }
        )
        let targetRoots: Set<String> = Set(
            targetDomains.map { host in
                let parts = host.split(separator: ".")
                if parts.count >= 2 {
                    return parts.suffix(2).joined(separator: ".")
                }
                return host
            }
        )
        guard !targetRoots.isEmpty else { return }

        let dataStore = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: allTypes)
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return targetDomains.contains(name)
                || targetRoots.contains(name)
                || targetRoots.contains(where: { name.hasSuffix(".\($0)") || $0.hasSuffix(".\(name)") })
        }
        if !matching.isEmpty {
            await dataStore.removeData(ofTypes: allTypes, for: matching)
        }
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
