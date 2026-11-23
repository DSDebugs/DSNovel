import DSCore
import Foundation

/// 双层混合实时联想扩展（本地 0 延迟命中 + 350ms 防抖轻搜提炼 + 5 分钟前缀缓存 + 代际防乱序）
extension SearchViewModel {
    func clearSuggestions() {
        suggestTask?.cancel()
        suggestTask = nil
        suggestGeneration &+= 1
        isLoadingSuggestions = false
        isShowingSuggestions = false
        suggestedBooks = []
        suggestedKeywords = []
    }

    func updateLiveSuggestions(
        for rawQuery: String,
        activeDiscoverSourceID: String,
        container: AppContainer
    ) {
        let term = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            clearSuggestions()
            return
        }

        isShowingSuggestions = true
        suggestTask?.cancel()
        suggestGeneration &+= 1
        let gen = suggestGeneration

        // 第一层：0 延迟本地命中（历史 + 书架 + 已缓存全源热门书籍）
        let localMatch = buildLocalSuggestions(for: term)
        suggestedBooks = localMatch.books
        suggestedKeywords = localMatch.keywords

        let cacheKey = "\(selectedScopeID)|\(activeDiscoverSourceID)|\(term.lowercased())"
        if let cached = suggestCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < Self.suggestCacheTTL {
            suggestedBooks = cached.books.isEmpty ? localMatch.books : cached.books
            suggestedKeywords = cached.keywords.isEmpty ? localMatch.keywords : cached.keywords
            isLoadingSuggestions = false
            return
        }

        // 第二层：350ms 防抖轻搜提炼（自动跳过输入法快速拼音中间态）
        isLoadingSuggestions = true
        suggestTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, gen == self.suggestGeneration else { return }

            await container.ensureSourcesRegistered()
            guard !Task.isCancelled, gen == self.suggestGeneration else { return }

            if self.searchableSources.isEmpty {
                await self.loadSearchableSources(container: container)
                guard !Task.isCancelled, gen == self.suggestGeneration else { return }
            }

            let scoped = self.resolveTargetSources(
                from: self.searchableSources,
                activeDiscoverSourceID: activeDiscoverSourceID
            )
            let probeSources = Array(scoped.prefix(2))
            guard !probeSources.isEmpty else {
                self.isLoadingSuggestions = false
                return
            }

            let sourceOrder = probeSources.map(\.id)
            var perSource: [String: [BookSummaryDTO]] = [:]

            let runtime = container.pluginRuntime
            await withTaskGroup(of: (String, [BookSummaryDTO]).self) { group in
                for src in probeSources {
                    group.addTask {
                        guard !Task.isCancelled else { return (src.id, []) }
                        do {
                            let page = try await runtime.searchPage(
                                sourceID: src.id,
                                keyword: term,
                                page: 1
                            )
                            return (src.id, page.books)
                        } catch {
                            return (src.id, [])
                        }
                    }
                }
                for await (sourceID, books) in group {
                    if Task.isCancelled || gen != self.suggestGeneration {
                        group.cancelAll()
                        break
                    }
                    if !books.isEmpty {
                        perSource[sourceID] = books
                    }
                }
                group.cancelAll()
            }

            guard !Task.isCancelled, gen == self.suggestGeneration else { return }

            let mergedRemote = Self.mergeAggregatedHotBooks(
                from: perSource,
                sourceOrder: sourceOrder,
                limit: 12
            )
            let directBooks = Self.pickDirectSuggestionBooks(
                remote: mergedRemote,
                local: localMatch.books,
                term: term,
                limit: 3
            )
            let keywords = Self.extractSuggestionKeywords(
                from: mergedRemote,
                localHistory: self.history,
                localBooks: self.shelfBooksCache + self.hotBooks,
                term: term,
                limit: 10
            )

            self.suggestedBooks = directBooks
            self.suggestedKeywords = keywords
            self.isLoadingSuggestions = false
            self.storeSuggestCache(
                key: cacheKey,
                entry: SearchSuggestCacheEntry(books: directBooks, keywords: keywords, timestamp: Date())
            )
        }
    }

    private func buildLocalSuggestions(for term: String) -> (books: [BookSummaryDTO], keywords: [SearchSuggestionItem]) {
        var matchedBooks: [BookSummaryDTO] = []
        var seenBookIDs: Set<String> = []
        for book in shelfBooksCache + hotBooks {
            let hitTitle = book.title.localizedCaseInsensitiveContains(term)
            let hitNarrator = book.narrator.localizedCaseInsensitiveContains(term)
            let hitAuthor = book.author.localizedCaseInsensitiveContains(term)
            if (hitTitle || hitNarrator || hitAuthor), seenBookIDs.insert(book.id).inserted {
                matchedBooks.append(book)
                if matchedBooks.count >= 3 { break }
            }
        }

        let keywords = Self.extractSuggestionKeywords(
            from: [],
            localHistory: history,
            localBooks: shelfBooksCache + hotBooks,
            term: term,
            limit: 8
        )
        return (matchedBooks, keywords)
    }

    private func storeSuggestCache(key: String, entry: SearchSuggestCacheEntry) {
        suggestCache[key] = entry
        if suggestCache.count > 40 {
            let sortedKeys = suggestCache
                .sorted { $0.value.timestamp < $1.value.timestamp }
                .prefix(suggestCache.count - 30)
                .map(\.key)
            for oldKey in sortedKeys {
                suggestCache.removeValue(forKey: oldKey)
            }
        }
    }

    static func pickDirectSuggestionBooks(
        remote: [BookSummaryDTO],
        local: [BookSummaryDTO],
        term: String,
        limit: Int = 3
    ) -> [BookSummaryDTO] {
        var result: [BookSummaryDTO] = []
        var seenTitleKeys: Set<String> = []
        let combined = remote + local
        let prioritized = combined.sorted { lhs, rhs in
            let lHit = lhs.title.localizedCaseInsensitiveContains(term) ? 0 : 1
            let rHit = rhs.title.localizedCaseInsensitiveContains(term) ? 0 : 1
            return lHit < rHit
        }
        for book in prioritized {
            let key = normalizeHotBookTitle(book.title)
            if seenTitleKeys.insert(key).inserted {
                result.append(book)
                if result.count >= limit { break }
            }
        }
        return result
    }

    static func extractSuggestionKeywords(
        from remoteBooks: [BookSummaryDTO],
        localHistory: [String],
        localBooks: [BookSummaryDTO],
        term: String,
        limit: Int = 10
    ) -> [SearchSuggestionItem] {
        var items: [SearchSuggestionItem] = []
        var seenLower: Set<String> = []

        func appendCandidate(_ raw: String, isHistory: Bool) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 28 else { return }
            let lower = trimmed.lowercased()
            guard seenLower.insert(lower).inserted else { return }
            items.append(SearchSuggestionItem(id: "\(isHistory ? "h" : "s")-\(lower)", text: trimmed, isFromHistory: isHistory))
        }

        for kw in localHistory where kw.localizedCaseInsensitiveContains(term) {
            appendCandidate(kw, isHistory: true)
            if items.count >= limit { return items }
        }

        for book in remoteBooks + localBooks {
            let mainTitle = cleanDisplayTitle(book.title)
            if mainTitle.localizedCaseInsensitiveContains(term) {
                appendCandidate(mainTitle, isHistory: false)
                if items.count >= limit { return items }
            }
            let narrator = book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
            if !narrator.isEmpty && narrator.localizedCaseInsensitiveContains(term) {
                appendCandidate(narrator, isHistory: false)
                if items.count >= limit { return items }
            }
        }

        for book in remoteBooks {
            let mainTitle = cleanDisplayTitle(book.title)
            appendCandidate(mainTitle, isHistory: false)
            if items.count >= limit { return items }
        }

        return items
    }

    static func cleanDisplayTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let barIdx = text.firstIndex(where: { $0 == "|" || $0 == "｜" || $0 == "丨" }) {
            let prefix = String(text[..<barIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 2 { text = prefix }
        }
        text = text.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }
}
