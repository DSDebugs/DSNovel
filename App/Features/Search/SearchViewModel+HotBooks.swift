import DSCore
import Foundation

/// 全源聚合热门书籍扩展（首页当前源第一优先 + 书源管理排序第二优先 + Top 30 零额外翻页开销 + 切源即时重排）
extension SearchViewModel {
    /// 严格按书源管理排序：置顶优先 → sortOrder 升序 → 名称稳定排序
    static func sortedBySourceManagementOrder(_ sources: [SourceMetaDTO]) -> [SourceMetaDTO] {
        sources.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 首页选中书源第一优先，其余严格遵循书源管理排序
    static func prioritizedSources(_ sources: [SourceMetaDTO], activeDiscoverSourceID: String) -> [SourceMetaDTO] {
        let ordered = sortedBySourceManagementOrder(sources)
        guard !activeDiscoverSourceID.isEmpty,
              let idx = ordered.firstIndex(where: { $0.id == activeDiscoverSourceID }) else {
            return ordered
        }
        var copy = ordered
        let preferred = copy.remove(at: idx)
        copy.insert(preferred, at: 0)
        return copy
    }

    func resolveTargetSources(from sources: [SourceMetaDTO], activeDiscoverSourceID: String) -> [SourceMetaDTO] {
        let unskipped = Self.prioritizedSources(
            sources.filter { !skippedSourceIDs.contains($0.id) },
            activeDiscoverSourceID: activeDiscoverSourceID
        )
        if selectedScopeID == Self.allSourcesChipID {
            return unskipped
        }
        if selectedScopeID == Self.currentDiscoverChipID {
            if !activeDiscoverSourceID.isEmpty,
               let match = unskipped.first(where: { $0.id == activeDiscoverSourceID }) {
                return [match]
            }
            return unskipped
        }
        let matched = unskipped.filter { $0.id == selectedScopeID || $0.groupName == selectedScopeID }
        return matched.isEmpty ? unskipped : matched
    }

    func invalidateHotBooksCache() {
        hotBooksLoadedAt = nil
        perSourceHotBooksCache.removeAll()
        discoverableSourcesCache = []
    }

    var hotBooksPriorityCaption: String {
        guard !hotBooks.isEmpty else { return "" }
        if selectedScopeID == Self.currentDiscoverChipID, !activeDiscoverSourceName.isEmpty {
            return "仅看\(activeDiscoverSourceName) · 共\(hotBooks.count)本"
        }
        if selectedScopeID != Self.allSourcesChipID, selectedScopeID != Self.currentDiscoverChipID {
            return "\(selectedScopeID) · 共\(hotBooks.count)本"
        }
        if !activeDiscoverSourceName.isEmpty {
            return "优先\(activeDiscoverSourceName) · 共\(hotBooks.count)本"
        }
        return "共\(hotBooks.count)本"
    }

    func recomputeHotBooksFromCache() {
        guard !perSourceHotBooksCache.isEmpty, !discoverableSourcesCache.isEmpty else { return }
        let preferredID = activeDiscoverSourceID
        let ordered = Self.prioritizedSources(discoverableSourcesCache, activeDiscoverSourceID: preferredID)

        let scopedSources: [SourceMetaDTO]
        let effectivePreferredID: String?
        if selectedScopeID == Self.currentDiscoverChipID, !preferredID.isEmpty {
            let match = ordered.filter { $0.id == preferredID }
            scopedSources = match.isEmpty ? ordered : match
            effectivePreferredID = preferredID
        } else if selectedScopeID != Self.allSourcesChipID, selectedScopeID != Self.currentDiscoverChipID {
            let match = ordered.filter { $0.groupName == selectedScopeID || $0.id == selectedScopeID }
            scopedSources = match.isEmpty ? ordered : match
            effectivePreferredID = scopedSources.first?.id
        } else {
            scopedSources = ordered
            effectivePreferredID = preferredID.isEmpty ? nil : preferredID
        }

        let merged = Self.mergeAggregatedHotBooks(
            from: perSourceHotBooksCache,
            sourceOrder: scopedSources.map(\.id),
            preferredSourceID: effectivePreferredID,
            limit: Self.defaultHotBooksLimit
        )
        if !merged.isEmpty {
            hotBooks = merged
        }
    }

    func loadHotBooksIfNeeded(container: AppContainer, forceReload: Bool = false) async {
        if activeDiscoverSourceID.isEmpty && !container.activeDiscoverSourceID.isEmpty {
            activeDiscoverSourceID = container.activeDiscoverSourceID
        }
        if !forceReload,
           !perSourceHotBooksCache.isEmpty,
           let loadedAt = hotBooksLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.hotBooksCacheTTL {
            recomputeHotBooksFromCache()
            return
        }
        guard forceReload || !isLoadingHotBooks else { return }

        hotBooksGeneration &+= 1
        let gen = hotBooksGeneration
        isLoadingHotBooks = true
        defer {
            if gen == hotBooksGeneration {
                isLoadingHotBooks = false
            }
        }

        await container.ensureSourcesRegistered()
        guard !Task.isCancelled, gen == hotBooksGeneration else { return }

        let all = (try? await container.persistence.fetchAllSources()) ?? []
        let enabledDiscoverable = all.map(\.meta).filter {
            $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus"))
        }
        let preferredID = activeDiscoverSourceID.isEmpty ? container.activeDiscoverSourceID : activeDiscoverSourceID
        let discoverable = Self.prioritizedSources(enabledDiscoverable, activeDiscoverSourceID: preferredID)
        guard !discoverable.isEmpty else { return }

        discoverableSourcesCache = discoverable
        var perSourceBooks: [String: [BookSummaryDTO]] = [:]

        let runtime = container.pluginRuntime
        await withTaskGroup(of: (sourceID: String, books: [BookSummaryDTO]).self) { group in
            for src in discoverable {
                group.addTask {
                    guard !Task.isCancelled else { return (src.id, []) }
                    do {
                        let categories = try await runtime.discoverCategories(sourceID: src.id)
                        let firstURL = categories.first?.url ?? ""
                        let page = try await runtime.discoverPage(
                            sourceID: src.id,
                            categoryURL: firstURL,
                            page: 1
                        )
                        return (src.id, page.books)
                    } catch {
                        return (src.id, [])
                    }
                }
            }

            for await result in group {
                if Task.isCancelled || gen != self.hotBooksGeneration {
                    group.cancelAll()
                    break
                }
                guard !result.books.isEmpty else { continue }
                perSourceBooks[result.sourceID] = result.books
                self.perSourceHotBooksCache = perSourceBooks
                self.recomputeHotBooksFromCache()
            }
            group.cancelAll()
        }

        if gen == hotBooksGeneration && !hotBooks.isEmpty {
            hotBooksLoadedAt = Date()
        }
    }

    static func mergeAggregatedHotBooks(
        from perSourceBooks: [String: [BookSummaryDTO]],
        sourceOrder: [String],
        preferredSourceID: String? = nil,
        limit: Int = SearchViewModel.defaultHotBooksLimit
    ) -> [BookSummaryDTO] {
        guard limit > 0 else { return [] }

        struct AggregatedEntry {
            var sourceIDs: Set<String>
            var bestRank: Int
            var bestBook: BookSummaryDTO
            var bestSourcePriority: Int
        }

        var byTitleKey: [String: AggregatedEntry] = [:]
        var dedupedPerSource: [String: [BookSummaryDTO]] = [:]

        for (priority, sourceID) in sourceOrder.enumerated() {
            guard let list = perSourceBooks[sourceID], !list.isEmpty else { continue }
            var seenLocalKeys: Set<String> = []
            var cleaned: [BookSummaryDTO] = []
            for (rank, book) in list.enumerated() {
                let key = normalizeHotBookTitle(book.title)
                guard !key.isEmpty, seenLocalKeys.insert(key).inserted else { continue }
                cleaned.append(book)

                if var existing = byTitleKey[key] {
                    existing.sourceIDs.insert(sourceID)
                    existing.bestRank = min(existing.bestRank, rank)
                    let betterMetadata = existing.bestBook.coverURL.isEmpty && !book.coverURL.isEmpty
                    if betterMetadata || (priority < existing.bestSourcePriority && !book.coverURL.isEmpty) {
                        existing.bestBook = book
                        existing.bestSourcePriority = priority
                    }
                    byTitleKey[key] = existing
                } else {
                    byTitleKey[key] = AggregatedEntry(
                        sourceIDs: [sourceID],
                        bestRank: rank,
                        bestBook: book,
                        bestSourcePriority: priority
                    )
                }
            }
            dedupedPerSource[sourceID] = cleaned
        }

        var result: [BookSummaryDTO] = []
        var usedTitleKeys: Set<String> = []
        var usedBookIDs: Set<String> = []

        // 0. 首页当前选中书源（如喜马拉雅）前三领衔置顶，确保榜单贴合用户当前所选书源
        if let preferred = preferredSourceID,
           !preferred.isEmpty,
           let preferredList = dedupedPerSource[preferred],
           !preferredList.isEmpty {
            let leadQuota = sourceOrder.count <= 1 ? limit : min(3, limit)
            for book in preferredList {
                guard result.count < leadQuota else { break }
                let key = normalizeHotBookTitle(book.title)
                if usedTitleKeys.insert(key).inserted && usedBookIDs.insert(book.id).inserted {
                    result.append(book)
                }
            }
        }

        // 1. 多源同时上榜的公认热书优先（含首选源元数据优先）
        let consensus = byTitleKey
            .filter { $0.value.sourceIDs.count >= 2 }
            .sorted { lhs, rhs in
                if let preferred = preferredSourceID, !preferred.isEmpty {
                    let lPref = lhs.value.sourceIDs.contains(preferred)
                    let rPref = rhs.value.sourceIDs.contains(preferred)
                    if lPref != rPref { return lPref && !rPref }
                }
                if lhs.value.sourceIDs.count != rhs.value.sourceIDs.count {
                    return lhs.value.sourceIDs.count > rhs.value.sourceIDs.count
                }
                if lhs.value.bestRank != rhs.value.bestRank {
                    return lhs.value.bestRank < rhs.value.bestRank
                }
                return lhs.value.bestSourcePriority < rhs.value.bestSourcePriority
            }

        for (key, entry) in consensus {
            guard result.count < limit else { break }
            if usedTitleKeys.insert(key).inserted && usedBookIDs.insert(entry.bestBook.id).inserted {
                result.append(entry.bestBook)
            }
        }

        // 2. 其余书籍按书源优先级顺序（首页当前源 → 书源管理排序）逐名次跨源轮转补齐至 30 本
        let maxDepth = dedupedPerSource.values.map(\.count).max() ?? 0
        if maxDepth > 0 && result.count < limit {
            for rank in 0..<maxDepth {
                guard result.count < limit else { break }
                for sourceID in sourceOrder {
                    guard result.count < limit else { break }
                    guard let list = dedupedPerSource[sourceID], rank < list.count else { continue }
                    let book = list[rank]
                    let key = normalizeHotBookTitle(book.title)
                    if usedTitleKeys.insert(key).inserted && usedBookIDs.insert(book.id).inserted {
                        result.append(book)
                    }
                }
            }
        }

        return result
    }

    static func normalizeHotBookTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let bracketPatterns = [
            "【[^】]*】",
            "\\[[^\\]]*\\]",
            "（[^）]*）",
            "\\([^\\)]*\\)"
        ]
        for pattern in bracketPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        if let barIdx = text.firstIndex(where: { $0 == "|" || $0 == "｜" || $0 == "丨" }) {
            let prefix = String(text[..<barIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 2 {
                text = prefix
            }
        }

        let noiseWords = [
            "多人有声剧", "精品多人剧", "多人剧", "有声小说", "有声书",
            "广播剧", "完整演播版", "演播版", "完整版", "免费", "第一季", "全本"
        ]
        for word in noiseWords {
            text = text.replacingOccurrences(of: word, with: "")
        }

        let cleaned = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return cleaned.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : cleaned
    }
}
