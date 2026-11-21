import Foundation
import Observation
import UIKit

struct DiscoverCategorySlotKey: Hashable, Equatable, Sendable {
    let sourceID: String
    let sectionIndex: Int
    let tabIndex: Int
}

final class DiscoverRenderCounter: @unchecked Sendable {
    static let shared = DiscoverRenderCounter()
    private let lock = NSLock()
    private var _rootBodyEvaluations: Int = 0
    private var _contentBodyEvaluations: Int = 0

    var rootBodyEvaluations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _rootBodyEvaluations
    }

    var contentBodyEvaluations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _contentBodyEvaluations
    }

    func recordRoot() {
        lock.lock()
        _rootBodyEvaluations += 1
        lock.unlock()
    }

    func recordContent() {
        lock.lock()
        _contentBodyEvaluations += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        _rootBodyEvaluations = 0
        _contentBodyEvaluations = 0
        lock.unlock()
    }
}

@MainActor
@Observable
final class DiscoverStore {
    static let shared = DiscoverStore()

    var currentSourceID: String = AppSettingsStore.shared.currentDiscoverSourceID {
        didSet {
            if AppSettingsStore.shared.currentDiscoverSourceID != currentSourceID {
                AppSettingsStore.shared.currentDiscoverSourceID = currentSourceID
            }
        }
    }

    private(set) var sectionsBySource: [String: [DiscoverSectionDTO]] = [:]
    private(set) var selectedSectionBySource: [String: Int] = [:]
    private(set) var selectedTabBySource: [String: Int] = [:]
    private(set) var booksBySlot: [DiscoverCategorySlotKey: [BookRef]] = [:]
    private(set) var nextPageBySlot: [DiscoverCategorySlotKey: String] = [:]
    private(set) var currentPageNumBySlot: [DiscoverCategorySlotKey: Int] = [:]

    /// 滚动位置非响应式缓存：读写不触发 SwiftUI body 重算（FIX-04）
    @ObservationIgnored private var scrollAnchorBySlot: [DiscoverCategorySlotKey: String] = [:]

    private(set) var isLoadingInitial: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadMoreFailed: Bool = false
    private(set) var lastError: Error?

    var searchKeyword: String = ""
    private(set) var isSearchActive: Bool = false
    private(set) var isSearchingInSource: Bool = false
    private(set) var searchResults: [BookRef] = []
    private(set) var searchError: Error?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreGeneration: UInt64 = 0
    @ObservationIgnored private var slotAccessOrder: [DiscoverCategorySlotKey] = []
    @ObservationIgnored private var fetchedAtBySlot: [DiscoverCategorySlotKey: Date] = [:]
    @ObservationIgnored private var menusFetchedAtBySource: [String: Date] = [:]
    @ObservationIgnored private let cacheTTL: TimeInterval = 600
    @ObservationIgnored private let maxCachedSlots = 16
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?

    var customSourceSearchLoader: ((String, String) async throws -> [BookRef])?
    var customMenusLoader: ((String) async throws -> [DiscoverSectionDTO])?
    var customPageLoader: ((String, String, Int) async throws -> DiscoverPageDTO)?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.trimCacheForMemoryWarning()
            }
        }
    }

    private static func deduplicatePreservingOrder(_ books: [BookRef]) -> [BookRef] {
        var seen = Set<String>()
        seen.reserveCapacity(books.count)
        var result: [BookRef] = []
        result.reserveCapacity(books.count)
        for book in books {
            if seen.insert(book.id).inserted {
                result.append(book)
            }
        }
        return result
    }

    private func touchSlot(_ slot: DiscoverCategorySlotKey) {
        if let idx = slotAccessOrder.firstIndex(of: slot) {
            slotAccessOrder.remove(at: idx)
        }
        slotAccessOrder.append(slot)
        let activeSlot = currentSlotKey
        while slotAccessOrder.count > maxCachedSlots {
            guard let evictIdx = slotAccessOrder.firstIndex(where: { $0 != activeSlot && $0 != slot }) else {
                break
            }
            let victim = slotAccessOrder.remove(at: evictIdx)
            booksBySlot.removeValue(forKey: victim)
            nextPageBySlot.removeValue(forKey: victim)
            currentPageNumBySlot.removeValue(forKey: victim)
            fetchedAtBySlot.removeValue(forKey: victim)
        }
    }

    private func isSlotCacheFresh(_ slot: DiscoverCategorySlotKey, now: Date = .now) -> Bool {
        guard let fetchedAt = fetchedAtBySlot[slot] else { return false }
        return now.timeIntervalSince(fetchedAt) < cacheTTL
    }

    private func isMenusCacheFresh(for sourceID: String, now: Date = .now) -> Bool {
        guard let fetchedAt = menusFetchedAtBySource[sourceID] else { return false }
        return now.timeIntervalSince(fetchedAt) < cacheTTL
    }

    private func cancelLoadMoreTask() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreGeneration &+= 1
        isLoadingMore = false
        loadMoreFailed = false
    }

    private func cancelActiveLoadTask() {
        cancelLoadMoreTask()
        activeLoadTask?.cancel()
        activeLoadTask = nil
        isLoadingInitial = false
        loadGeneration &+= 1
    }

    func invalidate(sourceID: String? = nil) {
        cancelActiveLoadTask()
        if let sid = sourceID, !sid.isEmpty {
            sectionsBySource.removeValue(forKey: sid)
            menusFetchedAtBySource.removeValue(forKey: sid)
            let keysToDrop = booksBySlot.keys.filter { $0.sourceID == sid }
            for key in keysToDrop {
                booksBySlot.removeValue(forKey: key)
                nextPageBySlot.removeValue(forKey: key)
                currentPageNumBySlot.removeValue(forKey: key)
                fetchedAtBySlot.removeValue(forKey: key)
            }
            slotAccessOrder.removeAll { $0.sourceID == sid }
            if currentSourceID == sid {
                lastError = nil
                loadMoreFailed = false
            }
        } else {
            sectionsBySource.removeAll()
            menusFetchedAtBySource.removeAll()
            booksBySlot.removeAll()
            nextPageBySlot.removeAll()
            currentPageNumBySlot.removeAll()
            fetchedAtBySlot.removeAll()
            slotAccessOrder.removeAll()
            lastError = nil
            loadMoreFailed = false
        }
    }

    func trimCacheForMemoryWarning() {
        let activeSlot = currentSlotKey
        let keysToDrop = booksBySlot.keys.filter { $0 != activeSlot }
        for key in keysToDrop {
            booksBySlot.removeValue(forKey: key)
            nextPageBySlot.removeValue(forKey: key)
            currentPageNumBySlot.removeValue(forKey: key)
            fetchedAtBySlot.removeValue(forKey: key)
        }
        slotAccessOrder = booksBySlot[activeSlot] != nil ? [activeSlot] : []
    }

    var currentSlotKey: DiscoverCategorySlotKey {
        DiscoverCategorySlotKey(
            sourceID: currentSourceID,
            sectionIndex: selectedSectionIndex,
            tabIndex: selectedTabIndex
        )
    }

    var currentSections: [DiscoverSectionDTO] {
        sectionsBySource[currentSourceID] ?? []
    }

    var selectedSectionIndex: Int {
        get { selectedSectionBySource[currentSourceID] ?? 0 }
        set { selectedSectionBySource[currentSourceID] = newValue }
    }

    var selectedTabIndex: Int {
        get { selectedTabBySource[currentSourceID] ?? 0 }
        set { selectedTabBySource[currentSourceID] = newValue }
    }

    var currentTabs: [DiscoverTabDTO] {
        let secs = currentSections
        guard secs.indices.contains(selectedSectionIndex) else { return [] }
        return secs[selectedSectionIndex].tabs
    }

    var currentBooks: [BookRef] {
        booksBySlot[currentSlotKey] ?? []
    }

    var canLoadMore: Bool {
        guard let next = nextPageBySlot[currentSlotKey] else { return false }
        return !next.isEmpty
    }

    func saveAnchor(_ bookID: String?, for key: DiscoverCategorySlotKey? = nil) {
        let target = key ?? currentSlotKey
        scrollAnchorBySlot[target] = bookID
    }

    func recordScrollAnchor(_ bookID: String?, for key: DiscoverCategorySlotKey? = nil) {
        saveAnchor(bookID, for: key)
    }

    func savedScrollAnchor(for key: DiscoverCategorySlotKey? = nil) -> String? {
        scrollAnchorBySlot[key ?? currentSlotKey]
    }


    nonisolated static func twoCharBadge(for sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "源" }
        return String(trimmed.prefix(2))
    }

    func submitSourceSearch(keyword rawKeyword: String? = nil) {
        if let rawKeyword {
            searchKeyword = rawKeyword
        }
        let clean = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            clearSourceSearch()
            return
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        let gen = searchGeneration
        let sid = currentSourceID
        guard !sid.isEmpty else { return }

        isSearchActive = true
        isSearchingInSource = true
        searchError = nil
        let loader = customSourceSearchLoader

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let books: [BookRef]
                if let loader {
                    books = try await loader(sid, clean)
                } else {
                    let page = try await PluginRuntime.shared.search(sourceID: sid, keyword: clean, page: 1)
                    books = page.books
                }
                guard !Task.isCancelled, self.searchGeneration == gen else { return }
                self.searchResults = Self.deduplicatePreservingOrder(books)
                self.isSearchingInSource = false
            } catch {
                guard !Task.isCancelled, self.searchGeneration == gen else { return }
                self.searchResults = []
                self.searchError = error
                self.isSearchingInSource = false
                if let pErr = error as? PluginError {
                    switch pErr {
                    case .needLogin, .needVerify:
                        SourceStore.shared.markAuthExpired(sourceID: sid)
                    default:
                        break
                    }
                }
            }
        }
    }

    func refreshSourceSearch() async {
        submitSourceSearch()
        if let task = searchTask {
            await task.value
        }
    }

    func clearSourceSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        searchKeyword = ""
        isSearchActive = false
        isSearchingInSource = false
        searchResults = []
        searchError = nil
    }

    func switchSource(to sourceID: String) async {
        guard !sourceID.isEmpty else { return }
        cancelActiveLoadTask()
        currentSourceID = sourceID
        lastError = nil
        if isSearchActive && !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submitSourceSearch()
        }
        if sectionsBySource[sourceID] == nil || !isMenusCacheFresh(for: sourceID) {
            await loadCategoryMenusAndFirstPage(forceReload: false)
        } else if currentBooks.isEmpty || !isSlotCacheFresh(currentSlotKey) {
            await loadFirstPage(forceReload: false)
        }
    }

    func selectSection(_ index: Int) async {
        guard selectedSectionIndex != index else { return }
        cancelActiveLoadTask()
        selectedSectionIndex = index
        selectedTabIndex = 0
        if currentBooks.isEmpty || !isSlotCacheFresh(currentSlotKey) {
            await loadFirstPage(forceReload: false)
        }
    }

    func selectTab(_ index: Int) async {
        guard selectedTabIndex != index else { return }
        cancelActiveLoadTask()
        selectedTabIndex = index
        if currentBooks.isEmpty || !isSlotCacheFresh(currentSlotKey) {
            await loadFirstPage(forceReload: false)
        }
    }

    func loadCategoryMenusAndFirstPage(forceReload: Bool = false) async {
        let sid = currentSourceID
        guard !sid.isEmpty else { return }
        if !forceReload,
           let existing = sectionsBySource[sid], !existing.isEmpty,
           isMenusCacheFresh(for: sid),
           !currentBooks.isEmpty,
           isSlotCacheFresh(currentSlotKey) {
            touchSlot(currentSlotKey)
            return
        }
        cancelActiveLoadTask()
        let gen = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoadCategoryMenusAndFirstPage(sourceID: sid, generation: gen)
        }
        activeLoadTask = task
        await task.value
    }

    private func performLoadCategoryMenusAndFirstPage(sourceID sid: String, generation gen: UInt64) async {
        isLoadingInitial = true
        lastError = nil
        do {
            let menus: [DiscoverSectionDTO]
            if let custom = customMenusLoader {
                menus = try await custom(sid)
            } else {
                menus = try await PluginRuntime.shared.discoverSections(sourceID: sid)
            }
            guard !Task.isCancelled, loadGeneration == gen, currentSourceID == sid else { return }
            sectionsBySource[sid] = menus
            menusFetchedAtBySource[sid] = .now
            if !menus.indices.contains(selectedSectionIndex) {
                selectedSectionIndex = 0
            }
            let tabs = currentTabs
            if !tabs.indices.contains(selectedTabIndex) {
                selectedTabIndex = 0
            }
            isLoadingInitial = false
            await performLoadFirstPage(slot: currentSlotKey, generation: gen)
        } catch {
            guard !Task.isCancelled, loadGeneration == gen, currentSourceID == sid else { return }
            isLoadingInitial = false
            lastError = error
            if let pErr = error as? PluginError {
                switch pErr {
                case .needLogin, .needVerify:
                    SourceStore.shared.markAuthExpired(sourceID: sid)
                default:
                    break
                }
            }
        }
    }

    func loadFirstPage(forceReload: Bool = false) async {
        let slot = currentSlotKey
        if !forceReload, let cached = booksBySlot[slot], !cached.isEmpty, isSlotCacheFresh(slot) {
            touchSlot(slot)
            isLoadingInitial = false
            lastError = nil
            return
        }
        cancelActiveLoadTask()
        let gen = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoadFirstPage(slot: slot, generation: gen)
        }
        activeLoadTask = task
        await task.value
    }

    private func performLoadFirstPage(slot: DiscoverCategorySlotKey, generation gen: UInt64) async {
        let tabs = currentTabs
        guard tabs.indices.contains(slot.tabIndex) else {
            booksBySlot[slot] = []
            nextPageBySlot[slot] = nil
            fetchedAtBySlot[slot] = .now
            isLoadingInitial = false
            return
        }
        let tabURL = tabs[slot.tabIndex].url
        isLoadingInitial = true
        lastError = nil
        loadMoreFailed = false
        do {
            let page: DiscoverPageDTO
            if let custom = customPageLoader {
                page = try await custom(slot.sourceID, tabURL, 1)
            } else {
                page = try await PluginRuntime.shared.discoverList(sourceID: slot.sourceID, tabURL: tabURL)
            }
            guard !Task.isCancelled, loadGeneration == gen, currentSlotKey == slot else { return }
            booksBySlot[slot] = Self.deduplicatePreservingOrder(page.books)
            nextPageBySlot[slot] = page.nextPageURL
            currentPageNumBySlot[slot] = 1
            fetchedAtBySlot[slot] = .now
            touchSlot(slot)
            isLoadingInitial = false
        } catch {
            guard !Task.isCancelled, loadGeneration == gen, currentSlotKey == slot else { return }
            isLoadingInitial = false
            lastError = error
            if let pErr = error as? PluginError {
                switch pErr {
                case .needLogin, .needVerify:
                    SourceStore.shared.markAuthExpired(sourceID: slot.sourceID)
                default:
                    break
                }
            }
        }
    }

    func loadNextPageIfNeeded(currentItemID: String? = nil) async {
        let slot = currentSlotKey
        guard !isLoadingInitial, !isLoadingMore,
              let nextURL = nextPageBySlot[slot], !nextURL.isEmpty else { return }
        let items = booksBySlot[slot] ?? []
        if let currentItemID, !currentItemID.isEmpty,
           let idx = items.firstIndex(where: { $0.id == currentItemID }),
           idx < max(0, items.count - 6) {
            return
        }
        loadMoreTask?.cancel()
        loadMoreGeneration &+= 1
        let loadGen = loadGeneration
        let moreGen = loadMoreGeneration
        isLoadingMore = true
        loadMoreFailed = false
        let nextPageNum = (currentPageNumBySlot[slot] ?? 1) + 1
        let customLoader = customPageLoader

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page: DiscoverPageDTO
                if let customLoader {
                    page = try await customLoader(slot.sourceID, nextURL, nextPageNum)
                } else {
                    page = try await PluginRuntime.shared.discoverList(sourceID: slot.sourceID, tabURL: nextURL)
                }
                guard !Task.isCancelled,
                      self.loadGeneration == loadGen,
                      self.loadMoreGeneration == moreGen,
                      self.currentSlotKey == slot else {
                    return
                }
                var merged = self.booksBySlot[slot] ?? []
                let oldCount = merged.count
                var seenIDs = Set(merged.map(\.id))
                for b in Self.deduplicatePreservingOrder(page.books) where seenIDs.insert(b.id).inserted {
                    merged.append(b)
                }
                self.booksBySlot[slot] = merged
                // 若远端返回空页或全重复页无增量，收敛 nextPageURL 防止空转卡死
                let hasNewBooks = merged.count > oldCount
                self.nextPageBySlot[slot] = hasNewBooks ? page.nextPageURL : nil
                self.currentPageNumBySlot[slot] = nextPageNum
                self.touchSlot(slot)
                self.isLoadingMore = false
                self.loadMoreTask = nil
            } catch {
                guard !Task.isCancelled,
                      self.loadGeneration == loadGen,
                      self.loadMoreGeneration == moreGen,
                      self.currentSlotKey == slot else {
                    return
                }
                self.isLoadingMore = false
                self.loadMoreFailed = true
                self.loadMoreTask = nil
            }
        }
        loadMoreTask = task
        await task.value
    }

    func resetForTesting() {
        cancelActiveLoadTask()
        searchTask?.cancel()
        searchTask = nil
        sectionsBySource.removeAll()
        menusFetchedAtBySource.removeAll()
        selectedSectionBySource.removeAll()
        selectedTabBySource.removeAll()
        booksBySlot.removeAll()
        nextPageBySlot.removeAll()
        currentPageNumBySlot.removeAll()
        fetchedAtBySlot.removeAll()
        scrollAnchorBySlot.removeAll()
        slotAccessOrder.removeAll()
        isLoadingInitial = false
        isLoadingMore = false
        loadMoreFailed = false
        lastError = nil
    }
}
