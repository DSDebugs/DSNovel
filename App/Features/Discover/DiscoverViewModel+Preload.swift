import DSCore
import DSDesignSystem
import DSPluginKit
import Foundation

/// 纯函数空分类过滤器（24 小时 TTL + 全空兜底防分类栏清空，便于单元测试）
enum DiscoverCategoryEmptyFilter {
    static let emptyCategoryTTL: TimeInterval = 24 * 60 * 60

    static func filter(
        raw: [DiscoverCategoryDTO],
        emptyMap: [String: TimeInterval],
        now: TimeInterval = Date().timeIntervalSince1970,
        ttl: TimeInterval = emptyCategoryTTL
    ) -> [DiscoverCategoryDTO] {
        guard !raw.isEmpty, !emptyMap.isEmpty else { return raw }
        let kept = raw.filter { cat in
            guard let markedAt = emptyMap[cat.id] else { return true }
            return (now - markedAt) >= ttl
        }
        return kept.isEmpty ? raw : kept
    }
}

extension DiscoverViewModel {
    private static let emptyCategoriesDefaultsKey = "dsnovel.v3.discover.emptyCategories.v1"
    private static let maxProbeCountPerPass = 12
    private static let maxPrefetchedCoverMemory = 300

    func loadPersistedEmptyCategories() {
        guard let data = UserDefaults.standard.data(forKey: Self.emptyCategoriesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String: TimeInterval]].self, from: data) else {
            return
        }
        let now = Date().timeIntervalSince1970
        var pruned: [String: [String: TimeInterval]] = [:]
        for (sourceID, entries) in decoded {
            let valid = entries.filter { (now - $0.value) < DiscoverCategoryEmptyFilter.emptyCategoryTTL }
            if !valid.isEmpty {
                pruned[sourceID] = valid
            }
        }
        emptyCategoriesBySource = pruned
    }

    func persistEmptyCategories() {
        if let data = try? JSONEncoder().encode(emptyCategoriesBySource) {
            UserDefaults.standard.set(data, forKey: Self.emptyCategoriesDefaultsKey)
        }
    }

    func filteredVisibleCategories(from raw: [DiscoverCategoryDTO], sourceID: String) -> [DiscoverCategoryDTO] {
        let emptyMap = emptyCategoriesBySource[sourceID] ?? [:]
        return DiscoverCategoryEmptyFilter.filter(raw: raw, emptyMap: emptyMap)
    }

    func clearEmptyCategories(for sourceID: String?) {
        if let sourceID {
            emptyCategoriesBySource.removeValue(forKey: sourceID)
        } else {
            emptyCategoriesBySource.removeAll()
        }
        persistEmptyCategories()
    }

    func markCategoryHasContent(sourceID: String, categoryID: String) {
        guard var map = emptyCategoriesBySource[sourceID], map.removeValue(forKey: categoryID) != nil else {
            return
        }
        if map.isEmpty {
            emptyCategoriesBySource.removeValue(forKey: sourceID)
        } else {
            emptyCategoriesBySource[sourceID] = map
        }
        persistEmptyCategories()
    }

    func markCategoryConfirmedEmpty(sourceID: String, categoryID: String) {
        var map = emptyCategoriesBySource[sourceID] ?? [:]
        map[categoryID] = Date().timeIntervalSince1970
        emptyCategoriesBySource[sourceID] = map
        persistEmptyCategories()

        guard sourceID == selectedSourceID, categoryID != selectedCategoryID else { return }
        let updated = filteredVisibleCategories(from: rawCategories, sourceID: sourceID)
        if updated.count != categories.count {
            categories = updated
        }
    }

    /// 前台发生交互、切源、进入搜索或离开发现页时立即取消后台预热，优先保障前台响应
    func cancelBackgroundPreloads() {
        categoryProbeTask?.cancel()
        categoryProbeTask = nil
        coverPrefetchTask?.cancel()
        coverPrefetchTask = nil
    }

    /// L1：首屏稳定 1.2s 后，仅对当前书源可见层级的未探测分类做单路串行预探测（有书进缓存，连续两次为空则隐藏）
    func scheduleCategoryProbeIfNeeded(container: AppContainer) {
        categoryProbeTask?.cancel()
        categoryProbeTask = nil

        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious && thermal != .critical else { return }

        let targetSourceID = selectedSourceID
        let currentCatID = selectedCategoryID
        guard !targetSourceID.isEmpty, categories.count > 1 else { return }

        let candidates = buildProbeCandidates(excluding: currentCatID, sourceID: targetSourceID)
        guard !candidates.isEmpty else { return }

        categoryProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.selectedSourceID == targetSourceID else { return }

            var consecutiveErrors = 0
            for cat in candidates {
                guard !Task.isCancelled, self.selectedSourceID == targetSourceID else { return }
                let thermalNow = ProcessInfo.processInfo.thermalState
                if thermalNow == .serious || thermalNow == .critical { return }

                let reqURL = self.resolvedRequestURL(for: cat.url)
                let cacheKey = self.feedCacheKey(sourceID: targetSourceID, categoryURL: reqURL)
                if self.cachedFeed(for: cacheKey) != nil { continue }

                do {
                    var pageResult = try await container.pluginRuntime.discoverPage(
                        sourceID: targetSourceID,
                        categoryURL: reqURL,
                        page: 1
                    )
                    guard !Task.isCancelled, self.selectedSourceID == targetSourceID else { return }

                    if pageResult.books.isEmpty {
                        // 首次空结果短间隔复检 1 次，避免首次种 Cookie 或瞬时风控误杀正常分类
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled, self.selectedSourceID == targetSourceID else { return }
                        pageResult = try await container.pluginRuntime.discoverPage(
                            sourceID: targetSourceID,
                            categoryURL: reqURL,
                            page: 1
                        )
                        guard !Task.isCancelled, self.selectedSourceID == targetSourceID else { return }
                    }

                    consecutiveErrors = 0
                    if pageResult.books.isEmpty {
                        self.markCategoryConfirmedEmpty(sourceID: targetSourceID, categoryID: cat.id)
                    } else {
                        self.markCategoryHasContent(sourceID: targetSourceID, categoryID: cat.id)
                        self.storeProbedFeedCache(key: cacheKey, pageResult: pageResult)
                    }
                } catch {
                    if Self.isCancellationError(error) { return }
                    // 网络报错/超时绝不判空，连续失败 2 次立即中止本轮探测
                    consecutiveErrors += 1
                    if consecutiveErrors >= 2 { return }
                }

                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// L2：提前一屏预热封面图进 CoverImagePipeline（自动适配 Wi-Fi / 低电量 / 发热状态）
    func prefetchCovers(startingAt startIndex: Int, container: AppContainer) {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious && thermal != .critical else { return }
        guard !books.isEmpty else { return }

        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let batchCount = (container.networkMonitor.isOnWiFi && !isLowPower) ? 8 : 4
        let clampedStart = max(0, min(startIndex, books.count - 1))
        let upper = min(books.count, clampedStart + batchCount)
        guard clampedStart < upper else { return }

        var urlsToFetch: [String] = []
        urlsToFetch.reserveCapacity(upper - clampedStart)
        for idx in clampedStart..<upper {
            let url = books[idx].coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty,
                  !prefetchedCoverURLs.contains(url),
                  container.coverPipeline.cachedImageSync(for: url) == nil else {
                continue
            }
            urlsToFetch.append(url)
            prefetchedCoverURLs.insert(url)
        }
        if prefetchedCoverURLs.count > Self.maxPrefetchedCoverMemory {
            prefetchedCoverURLs.removeAll(keepingCapacity: true)
        }
        guard !urlsToFetch.isEmpty else { return }

        let pipeline = container.coverPipeline
        coverPrefetchTask?.cancel()
        coverPrefetchTask = Task.detached(priority: .utility) {
            for url in urlsToFetch {
                guard !Task.isCancelled else { return }
                _ = await pipeline.image(for: url)
            }
        }
    }

    private func buildProbeCandidates(excluding currentCatID: String, sourceID: String) -> [DiscoverCategoryDTO] {
        var ordered: [DiscoverCategoryDTO] = []
        var seenIDs: Set<String> = [currentCatID]
        let emptyMap = emptyCategoriesBySource[sourceID] ?? [:]
        let now = Date().timeIntervalSince1970

        func consider(_ cat: DiscoverCategoryDTO) {
            guard ordered.count < Self.maxProbeCountPerPass else { return }
            guard seenIDs.insert(cat.id).inserted else { return }
            if let markedAt = emptyMap[cat.id], (now - markedAt) < DiscoverCategoryEmptyFilter.emptyCategoryTTL {
                return
            }
            let reqURL = resolvedRequestURL(for: cat.url)
            if cachedFeed(for: feedCacheKey(sourceID: sourceID, categoryURL: reqURL)) != nil {
                return
            }
            ordered.append(cat)
        }

        if categorySections.indices.contains(selectedSectionIndex) {
            for tab in categorySections[selectedSectionIndex].tabs {
                consider(tab.category)
                for sub in tab.subTabs {
                    consider(sub.category)
                }
            }
        }
        for cat in categories {
            consider(cat)
        }
        return ordered
    }

    private func storeProbedFeedCache(key: String, pageResult: SourceContractAdapter.DiscoverPageResult) {
        var uniqueBooks: [BookSummaryDTO] = []
        var seen: Set<String> = []
        for item in pageResult.books where seen.insert(item.id).inserted {
            uniqueBooks.append(item)
        }
        guard !uniqueBooks.isEmpty else { return }
        feedCache[key] = DiscoverFeedCacheEntry(
            books: uniqueBooks,
            currentPage: 1,
            nextPageURL: pageResult.nextURL,
            hasMore: pageResult.hasMore,
            cachedAt: Date()
        )
        feedCacheOrder.removeAll { $0 == key }
        feedCacheOrder.append(key)
        while feedCacheOrder.count > Self.maxFeedCacheEntries {
            let evicted = feedCacheOrder.removeFirst()
            feedCache.removeValue(forKey: evicted)
        }
    }
}
