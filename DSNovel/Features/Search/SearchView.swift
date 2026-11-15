import SwiftUI
import SwiftData

struct FailedSourceSummary: Identifiable {
    var id: String { sourceID }
    let sourceID: String
    let sourceName: String
    let siteURL: String
    let error: PluginError
}

@MainActor
@Observable
final class SearchViewModel {
    var keyword: String = ""
    var selectedGroupID: String? = nil // nil 表示全部源
    var mergedResults: [MergedSearchItem] = []
    var completedSourcesCount: Int = 0
    var totalSourcesCount: Int = 0
    var failedSources: [FailedSourceSummary] = []
    var isSearching: Bool = false

    private var searchTask: Task<Void, Never>?

    /// 归一化去重合并算法（5.3 节步骤 2：按 标题+作者 归一化合并多来源结果）
    nonisolated static func mergeBookResults(_ incoming: [BookRef], into existing: [MergedSearchItem]) -> [MergedSearchItem] {
        var result = existing
        for book in incoming {
            let key = book.normalizedKey
            if let idx = result.firstIndex(where: { $0.primary.normalizedKey == key }) {
                var item = result[idx]
                if item.primary.id != book.id && !item.alternatives.contains(where: { $0.id == book.id }) {
                    item.alternatives.append(book)
                    result[idx] = item
                }
            } else {
                result.append(MergedSearchItem(primary: book, alternatives: []))
            }
        }
        return result
    }

    func performSearch(plugins: [PluginRecord]) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searchTask?.cancel()
        let activePlugins = plugins.filter { p in
            guard p.isEnabled && p.searchable else { return false }
            if let gid = selectedGroupID {
                return p.groupID == gid
            }
            return true
        }

        mergedResults = []
        failedSources = []
        completedSourcesCount = 0
        totalSourcesCount = activePlugins.count
        guard !activePlugins.isEmpty else { return }

        isSearching = true
        let pluginSnapshots = activePlugins.map {
            (id: $0.id, name: $0.name, siteURL: $0.siteURL)
        }

        searchTask = Task {
            let stream = AsyncStream<(sourceID: String, sourceName: String, siteURL: String, outcome: Result<[BookRef], PluginError>)> { continuation in
                Task {
                    await withTaskGroup(of: (String, String, String, Result<[BookRef], PluginError>).self) { group in
                        for snap in pluginSnapshots {
                            group.addTask {
                                do {
                                    // 每源独立 8 秒超时（5.3 节步骤 1）
                                    let books = try await withThrowingTaskGroup(of: [BookRef].self) { inner in
                                        inner.addTask {
                                            let dto = try await PluginRuntime.shared.search(
                                                sourceID: snap.id,
                                                keyword: trimmed,
                                                page: 1
                                            )
                                            return dto.books
                                        }
                                        inner.addTask {
                                            try await Task.sleep(for: .seconds(8))
                                            throw PluginError.timeout
                                        }
                                        let first = try await inner.next()!
                                        inner.cancelAll()
                                        return first
                                    }
                                    return (snap.id, snap.name, snap.siteURL, .success(books))
                                } catch let pErr as PluginError {
                                    return (snap.id, snap.name, snap.siteURL, .failure(pErr))
                                } catch {
                                    return (snap.id, snap.name, snap.siteURL, .failure(.network(error.localizedDescription)))
                                }
                            }
                        }
                        for await item in group {
                            continuation.yield(item)
                        }
                        continuation.finish()
                    }
                }
            }

            for await event in stream {
                if Task.isCancelled { break }
                completedSourcesCount += 1
                switch event.outcome {
                case .success(let books):
                    if !books.isEmpty {
                        mergedResults = Self.mergeBookResults(books, into: mergedResults)
                    }
                case .failure(let err):
                    failedSources.append(
                        FailedSourceSummary(
                            sourceID: event.sourceID,
                            sourceName: event.sourceName,
                            siteURL: event.siteURL,
                            error: err
                        )
                    )
                }
            }
            if !Task.isCancelled {
                isSearching = false
            }
        }
    }
}

/// 搜索页（5.3 节）：并发流式搜索、标题+作者去重合并、最多 30 条搜索历史与失败源就地验证
struct SearchView: View {
    let onSelectMergedItem: (MergedSearchItem) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\.order)]) private var groups: [PluginGroup]
    @Query(sort: [SortDescriptor(\.updatedAt, order: .reverse)]) private var histories: [SearchHistory]

    @State private var viewModel = SearchViewModel()
    @State private var showFailedDetails = false
    @State private var authSession: WebAuthSessionRequest?

    var body: some View {
        VStack(spacing: 0) {
            scopeCapsuleBar

            if viewModel.totalSourcesCount > 0 && (viewModel.isSearching || !viewModel.mergedResults.isEmpty) {
                HStack {
                    Text("已完成 \(viewModel.completedSourcesCount) / \(viewModel.totalSourcesCount) 个源")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, 4)
            }

            if viewModel.keyword.trimmingCharacters(in: .whitespaces).isEmpty && viewModel.mergedResults.isEmpty {
                historySection
            } else {
                resultsList
            }
        }
        .background(DSColor.contentBackground)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.keyword, prompt: "搜索书名、作者或主播")
        .onSubmit(of: .search) {
            recordHistory(viewModel.keyword)
            viewModel.performSearch(plugins: plugins)
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
    }

    private var scopeCapsuleBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let allSelected = viewModel.selectedGroupID == nil
                Button {
                    viewModel.selectedGroupID = nil
                    if !viewModel.keyword.isEmpty {
                        viewModel.performSearch(plugins: plugins)
                    }
                } label: {
                    Text("全部源")
                        .font(.caption.weight(allSelected ? .semibold : .regular))
                        .foregroundStyle(allSelected ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(allSelected ? DSColor.primary : DSColor.cardSurface)
                        )
                }
                .buttonStyle(.plain)

                ForEach(groups) { group in
                    let isSelected = viewModel.selectedGroupID == group.id
                    Button {
                        viewModel.selectedGroupID = group.id
                        if !viewModel.keyword.isEmpty {
                            viewModel.performSearch(plugins: plugins)
                        }
                    } label: {
                        Text(group.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? DSColor.primary : DSColor.cardSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, 8)
        }
    }

    private var historySection: some View {
        List {
            if !histories.isEmpty {
                Section {
                    ForEach(histories) { item in
                        Button {
                            viewModel.keyword = item.keyword
                            recordHistory(item.keyword)
                            viewModel.performSearch(plugins: plugins)
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(item.keyword)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            modelContext.delete(histories[idx])
                        }
                        try? modelContext.save()
                    }
                } header: {
                    HStack {
                        Text("搜索历史")
                        Spacer()
                        Button("清空") {
                            for h in histories {
                                modelContext.delete(h)
                            }
                            try? modelContext.save()
                        }
                        .font(.caption)
                    }
                }
            } else {
                ContentUnavailableView(
                    "输入关键词开始聚合搜索",
                    systemImage: "magnifyingglass",
                    description: Text("支持跨多个听书源并发搜索，自动合并同名书籍并提供一键换源")
                )
            }
        }
        .listStyle(.plain)
    }

    private var resultsList: some View {
        List {
            ForEach(viewModel.mergedResults) { merged in
                let book = merged.primary
                let srcName = plugins.first(where: { $0.id == book.sourceID })?.name ?? book.sourceID
                HStack(alignment: .top, spacing: 12) {
                    CoverImageView(url: book.cover, title: book.title, width: 60, height: 80, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(book.author.isEmpty ? "未知作者" : book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(srcName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DSColor.cardSurface)
                                .clipShape(Capsule())

                            if !merged.alternatives.isEmpty {
                                Text("另有 \(merged.alternatives.count) 个可用源")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(DSColor.primary)
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelectMergedItem(merged)
                }
            }

            if !viewModel.failedSources.isEmpty {
                Section {
                    Button {
                        showFailedDetails.toggle()
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("\(viewModel.failedSources.count) 个源未返回结果")
                                .font(.footnote)
                            Spacer()
                            Image(systemName: showFailedDetails ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }

                    if showFailedDetails {
                        ForEach(viewModel.failedSources) { failed in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failed.sourceName)
                                        .font(.subheadline.weight(.medium))
                                    Text(failed.error.localizedDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if case .needVerify(_, let vURL) = failed.error {
                                    Button("去验证") {
                                        authSession = WebAuthSessionRequest(
                                            sourceID: failed.sourceID,
                                            title: "验证 · \(failed.sourceName)",
                                            initialURL: vURL.isEmpty ? failed.siteURL : vURL,
                                            expectedCookieName: nil,
                                            onCompleted: {
                                                viewModel.performSearch(plugins: plugins)
                                            }
                                        )
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderedProminent)
                                } else if case .needLogin(_, let lURL) = failed.error {
                                    Button("去登录") {
                                        authSession = WebAuthSessionRequest(
                                            sourceID: failed.sourceID,
                                            title: "登录 · \(failed.sourceName)",
                                            initialURL: lURL.isEmpty ? failed.siteURL : lURL,
                                            expectedCookieName: nil,
                                            onCompleted: {
                                                viewModel.performSearch(plugins: plugins)
                                            }
                                        )
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func recordHistory(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = histories.first(where: { $0.keyword == trimmed }) {
            existing.updatedAt = .now
        } else {
            modelContext.insert(SearchHistory(keyword: trimmed, updatedAt: .now))
            // 最多保留 30 条（4.1 节）
            let sorted = histories.sorted { $0.updatedAt > $1.updatedAt }
            if sorted.count >= 30 {
                for extra in sorted.dropFirst(29) {
                    modelContext.delete(extra)
                }
            }
        }
        try? modelContext.save()
    }
}
