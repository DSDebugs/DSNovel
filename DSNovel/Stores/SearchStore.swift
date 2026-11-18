enum SearchPhase: String, Equatable, Sendable {
    case idle
    case typing
    case searching
    case results
    case empty
    case allFailed
}

import Foundation
import Observation
import SwiftData

enum SearchScopeSelection: Hashable, Equatable, Sendable {
    case all
    case currentDiscover
    case group(String)
    case custom(Set<String>)

    var title: String {
        switch self {
        case .all: return "全部书源"
        case .currentDiscover: return "当前发现书源"
        case .group(let name): return name
        case .custom(let ids): return "自定义(\(ids.count))"
        }
    }
}

struct SearchSourceDescriptor: Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

struct FailedSourceItem: Identifiable, Equatable, Hashable, Sendable {
    var id: String { sourceID }
    let sourceID: String
    let sourceName: String
    let reason: String
    let stateKind: DSStateKind
}

@MainActor
@Observable
final class SearchStore {
    static let shared = SearchStore()

    var keyword: String = ""
    var selectedScope: SearchScopeSelection = .all
    var selectedSourceFilterID: String = "all"
    var hasScrolledPastFirstScreen: Bool = false

    private(set) var phase: SearchPhase = .idle
    private(set) var isSearching: Bool = false
    private(set) var completedSourcesCount: Int = 0
    private(set) var totalSourcesCount: Int = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var mergedItems: [MergedSearchItem] = []
    private(set) var failedSources: [FailedSourceItem] = []
    private(set) var pendingHigherRelevanceCount: Int = 0
    private(set) var searchGeneration: UInt64 = 0

    private(set) var hotBooks: [BookRef] = []
    private(set) var isLoadingHotBooks: Bool = false
    private(set) var hotBooksSourceName: String = ""

    private var activeTask: Task<Void, Never>?
    private var stagingBuffer: [BookRef] = []
    private var skippedSourceIDs: Set<String> = []
    var customSourceSearchRunner: (@Sendable (SearchSourceDescriptor, String) async throws -> [BookRef])?
    var customHotBooksLoader: (@Sendable (String) async throws -> [BookRef])?

    init() {}

    nonisolated static func relevance(title: String, keyword: String) -> Int {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty, !t.isEmpty else { return 0 }
        if t == kw { return 3 }
        if t.hasPrefix(kw) { return 2 }
        if t.contains(kw) { return 1 }
        return 0
    }

    nonisolated static func mergeBookResults(_ incoming: [BookRef], into existing: [MergedSearchItem]) -> [MergedSearchItem] {
        var result = existing
        var indexByKey: [String: Int] = [:]
        for (idx, item) in result.enumerated() {
            indexByKey[item.primary.normalizedKey] = idx
        }

        for book in incoming {
            let key = book.normalizedKey
            if let idx = indexByKey[key] {
                var current = result[idx]
                if current.primary.id != book.id && !current.alternatives.contains(where: { $0.id == book.id }) {
                    current.alternatives.append(book)
                    result[idx] = current
                }
            } else {
                indexByKey[key] = result.count
                result.append(MergedSearchItem(primary: book, alternatives: []))
            }
        }
        return result
    }

    func activeTargetSources(from allSources: [PluginRecord], groups: [PluginGroup]) -> [PluginRecord] {
        let enabled = allSources.filter { $0.isEnabled && $0.searchable && !skippedSourceIDs.contains($0.id) }
        let scoped: [PluginRecord]
        switch selectedScope {
        case .all:
            scoped = enabled
        case .currentDiscover:
            let curID = AppSettingsStore.shared.currentDiscoverSourceID
            let matched = enabled.filter { $0.id == curID }
            scoped = matched.isEmpty ? enabled : matched
        case .group(let groupID):
            scoped = enabled.filter { $0.groupID == groupID }
        case .custom(let ids):
            scoped = enabled.filter { ids.contains($0.id) }
        }
        return scoped.sorted { $0.searchPriorityScore < $1.searchPriorityScore }
    }

    func prefixSuggestions(from histories: [SearchHistory]) -> [String] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        return Array(
            histories
                .map(\.keyword)
                .filter { $0.lowercased().hasPrefix(kw) && $0.lowercased() != kw }
                .prefix(5)
        )
    }

    var displayedItems: [MergedSearchItem] {
        if selectedSourceFilterID == "all" {
            return mergedItems
        }
        return mergedItems.filter { item in
            item.primary.sourceID == selectedSourceFilterID ||
            item.alternatives.contains(where: { $0.sourceID == selectedSourceFilterID })
        }
    }

    func sourceResultCounts() -> [(sourceID: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in mergedItems {
            counts[item.primary.sourceID, default: 0] += 1
            for alt in item.alternatives {
                counts[alt.sourceID, default: 0] += 1
            }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    func loadHotBooksIfNeeded(sources: [PluginRecord], forceReload: Bool = false) async {
        if !forceReload && !hotBooks.isEmpty { return }
        if isLoadingHotBooks { return }
        let discoverable = sources.filter { $0.isEnabled && $0.discoverable }
        let preferredID = AppSettingsStore.shared.currentDiscoverSourceID
        guard let target = discoverable.first(where: { $0.id == preferredID }) ?? discoverable.first else {
            hotBooks = []
            hotBooksSourceName = ""
            return
        }

        if !forceReload && DiscoverStore.shared.currentSourceID == target.id && !DiscoverStore.shared.currentBooks.isEmpty {
            hotBooks = Array(DiscoverStore.shared.currentBooks.prefix(20))
            hotBooksSourceName = target.name
            return
        }

        isLoadingHotBooks = true
        defer { isLoadingHotBooks = false }

        do {
            let books: [BookRef]
            if let custom = customHotBooksLoader {
                books = try await custom(target.id)
            } else {
                let sections = try await PluginRuntime.shared.discoverSections(sourceID: target.id)
                if let firstTab = sections.first?.tabs.first {
                    let page = try await PluginRuntime.shared.discoverList(sourceID: target.id, tabURL: firstTab.url)
                    books = page.books
                } else {
                    books = []
                }
            }
            hotBooks = Array(books.prefix(20))
            hotBooksSourceName = target.name
        } catch {
            if hotBooks.isEmpty {
                hotBooksSourceName = ""
            }
        }
    }

    func submit(
        keyword rawKeyword: String? = nil,
        sources: [PluginRecord],
        modelContext: ModelContext? = nil
    ) {
        if let rawKeyword {
            self.keyword = rawKeyword
        }
        let cleanKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKeyword.isEmpty else { return }

        if let ctx = modelContext {
            let desc = FetchDescriptor<SearchHistory>(predicate: #Predicate<SearchHistory> { $0.keyword == cleanKeyword })
            if let existing = try? ctx.fetch(desc).first {
                existing.updatedAt = .now
            } else {
                ctx.insert(SearchHistory(keyword: cleanKeyword, updatedAt: .now))
            }
            try? ctx.save()
        }

        cancelCurrentSearch()
        searchGeneration &+= 1
        let gen = searchGeneration

        mergedItems.removeAll()
        failedSources.removeAll()
        stagingBuffer.removeAll()
        pendingHigherRelevanceCount = 0
        selectedSourceFilterID = "all"
        completedSourcesCount = 0
        totalSourcesCount = sources.count
        elapsedSeconds = 0
        isSearching = !sources.isEmpty
        phase = isSearching ? .searching : .empty

        guard !sources.isEmpty else { return }
        let startTime = Date().timeIntervalSince1970
        let runner = customSourceSearchRunner
        let descriptors = sources.map { SearchSourceDescriptor(id: $0.id, name: $0.name) }

        activeTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (SearchSourceDescriptor, Result<[BookRef], Error>).self) { group in
                for src in descriptors {
                    group.addTask {
                        do {
                            if let runner {
                                let books = try await runner(src, cleanKeyword)
                                return (src, .success(books))
                            } else {
                                let page = try await PluginRuntime.shared.search(
                                    sourceID: src.id,
                                    keyword: cleanKeyword,
                                    page: 1
                                )
                                return (src, .success(page.books))
                            }
                        } catch {
                            return (src, .failure(error))
                        }
                    }
                }

                var lastFlushTime = Date().timeIntervalSince1970
                for await (src, outcome) in group {
                    guard !Task.isCancelled, self.searchGeneration == gen else { return }
                    self.completedSourcesCount += 1
                    switch outcome {
                    case .success(let books):
                        self.stagingBuffer.append(contentsOf: books)
                    case .failure(let err):
                        let kind = UserFacingError.from(err, sourceName: src.name)
                        if case .needLogin = kind {
                            SourceStore.shared.markAuthExpired(sourceID: src.id)
                        } else if case .needVerify = kind {
                            SourceStore.shared.markAuthExpired(sourceID: src.id)
                        }
                        self.failedSources.append(
                            FailedSourceItem(
                                sourceID: src.id,
                                sourceName: src.name,
                                reason: err.localizedDescription,
                                stateKind: kind
                            )
                        )
                    }
                    let now = Date().timeIntervalSince1970
                    if (now - lastFlushTime) >= 0.10 {
                        lastFlushTime = now
                        self.flushStagingBuffer(forKeyword: cleanKeyword, generation: gen)
                    }
                }
            }

            guard !Task.isCancelled, self.searchGeneration == gen else { return }
            self.flushStagingBuffer(forKeyword: cleanKeyword, generation: gen)
            self.elapsedSeconds = max(0.1, Date().timeIntervalSince1970 - startTime)
            self.isSearching = false
            if !self.hasScrolledPastFirstScreen && self.pendingHigherRelevanceCount > 0 {
                self.applyRelevanceResort()
            }
            if !self.mergedItems.isEmpty {
                self.phase = .results
            } else if !self.failedSources.isEmpty {
                self.phase = .allFailed
            } else {
                self.phase = .empty
            }
        }
    }

    func flushStagingBuffer(forKeyword cleanKeyword: String, generation: UInt64) {
        guard generation == searchGeneration, !stagingBuffer.isEmpty else { return }
        let batch = stagingBuffer
        stagingBuffer.removeAll()

        let topBaselineScore = mergedItems.prefix(3).map {
            Self.relevance(title: $0.primary.title, keyword: cleanKeyword)
        }.max() ?? 0

        let previousCount = mergedItems.count
        mergedItems = Self.mergeBookResults(batch, into: mergedItems)
        if previousCount > 0 {
            let newlyAdded = mergedItems.dropFirst(previousCount)
            let higherCount = newlyAdded.filter {
                Self.relevance(title: $0.primary.title, keyword: cleanKeyword) > topBaselineScore
            }.count
            pendingHigherRelevanceCount += higherCount
        }
    }

    func ingestBatchForTesting(_ batch: [BookRef], generation: UInt64) {
        guard generation == searchGeneration else { return }
        stagingBuffer.append(contentsOf: batch)
        flushStagingBuffer(forKeyword: keyword, generation: generation)
    }

    func applyRelevanceResort() {
        let kw = keyword
        mergedItems.sort { a, b in
            let ra = Self.relevance(title: a.primary.title, keyword: kw)
            let rb = Self.relevance(title: b.primary.title, keyword: kw)
            if ra != rb { return ra > rb }
            if a.alternatives.count != b.alternatives.count {
                return a.alternatives.count > b.alternatives.count
            }
            return a.primary.title.localizedStandardCompare(b.primary.title) == .orderedAscending
        }
        pendingHigherRelevanceCount = 0
    }

    func updateTypingState(isFocused: Bool) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if phase != .idle {
                reset()
            }
        } else if !isSearching && phase != .results && phase != .empty && phase != .allFailed {
            phase = isFocused ? .typing : .idle
        }
    }

    func reset() {
        cancelCurrentSearch()
        keyword = ""
        mergedItems.removeAll()
        failedSources.removeAll()
        pendingHigherRelevanceCount = 0
        completedSourcesCount = 0
        totalSourcesCount = 0
        elapsedSeconds = 0
        selectedSourceFilterID = "all"
        phase = .idle
    }

    func cancelCurrentSearch() {
        activeTask?.cancel()
        activeTask = nil
        searchGeneration &+= 1
        stagingBuffer.removeAll()
        isSearching = false
        if !mergedItems.isEmpty { phase = .results }
    }

    func skipFailedSource(_ sourceID: String) {
        skippedSourceIDs.insert(sourceID)
        failedSources.removeAll { $0.sourceID == sourceID }
    }
}

typealias SearchViewModel = SearchStore
