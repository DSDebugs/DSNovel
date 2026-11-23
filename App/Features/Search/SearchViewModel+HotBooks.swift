import DSCore
import Foundation

/// 全源聚合热门书籍扩展（并发拉取全启用源首页、规范化书名去重、多源共热加权与跨源轮转混排 Top 15、30 分钟静默缓存）
extension SearchViewModel {
    func invalidateHotBooksCache() {
        hotBooksLoadedAt = nil
    }

    func loadHotBooksIfNeeded(container: AppContainer, forceReload: Bool = false) async {
        if !forceReload,
           !hotBooks.isEmpty,
           let loadedAt = hotBooksLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.hotBooksCacheTTL {
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
        let discoverable = all.map(\.meta).filter {
            $0.isEnabled && ($0.methods.contains("discover") || $0.methods.contains("categoryPage") || $0.methods.contains("categoryMenus"))
        }
        guard !discoverable.isEmpty else { return }

        let sourceOrder = discoverable.map(\.id)
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
                let merged = Self.mergeAggregatedHotBooks(
                    from: perSourceBooks,
                    sourceOrder: sourceOrder,
                    limit: 15
                )
                if !merged.isEmpty {
                    self.hotBooks = merged
                }
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
        limit: Int = 15
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

        // 1. 多源同时上榜的公认热书优先置顶
        let consensus = byTitleKey
            .filter { $0.value.sourceIDs.count >= 2 }
            .sorted { lhs, rhs in
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

        // 2. 其余书籍按所有书源第 1、2、3 名跨源轮转混排
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
