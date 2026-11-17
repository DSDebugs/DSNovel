import SwiftUI
import SwiftData

struct FailedSourceSummary: Identifiable, Equatable, Sendable {
    var id: String { sourceID }
    let sourceID: String
    let sourceName: String
    let siteURL: String
    let error: PluginError
}

struct SourceSearchFilterChip: Identifiable, Equatable, Sendable {
    var id: String { sourceID }
    let sourceID: String
    let sourceName: String
    let count: Int
}

struct SearchPluginSnapshot: Sendable {
    let id: String
    let name: String
    let siteURL: String
}

struct SingleSourceSearchEvent: Sendable {
    let sourceID: String
    let sourceName: String
    let siteURL: String
    let latencyMs: Int
    let outcome: Result<[BookRef], PluginError>
}

@MainActor
@Observable
final class SearchViewModel {
    var keyword: String = ""
    var searchedKeyword: String = ""
    var hasSearched: Bool = false
    var selectedGroupID: String? = nil // nil 表示全部书源
    var selectedSourceFilterID: String? = nil // nil 表示合并展示全部结果，非 nil 表示仅看指定书源
    private(set) var mergedResults: [MergedSearchItem] = []
    /// 按相关度排序后的展示结果（精确匹配 > 前缀匹配 > 包含匹配，同级按可用书源数量）
    private(set) var sortedResults: [MergedSearchItem] = []
    var rawBySource: [String: [BookRef]] = [:]
    var completedSourcesCount: Int = 0
    var totalSourcesCount: Int = 0
    /// 搜索前已被预先跳过的书源数量（近期检测为不可用，不再浪费时间等待超时）
    var skippedSourcesCount: Int = 0
    var failedSources: [FailedSourceSummary] = []
    var isSearching: Bool = false
    var elapsedSecondsText: String = ""

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    /// normalizedKey -> mergedResults 下标，使合并去重由 O(n²) 降为 O(n)
    private var mergedIndex: [String: Int] = [:]

    /// 单个书源的搜索超时与整体并发上限
    private static let perSourceTimeout: Double = 8.0
    private static let maxConcurrency = 8
    /// 超过该时长后不再启动尚未开始的书源，避免书源很多时长时间转圈
    private static let launchDeadlineSec: Double = 25.0
    /// 最近多长时间内被检测为「不可用」的书源在搜索时直接跳过
    private static let unavailableSkipWindow: TimeInterval = 6 * 3600

    /// 推荐热搜词：方便用户进入搜索页即刻一键验证搜索功能
    static let suggestedKeywords: [String] = [
        "凡人修仙传", "郭德纲", "三体", "单田芳", "盗墓笔记", "鬼吹灯", "百家讲坛", "明朝那些事儿"
    ]

    /// 归一化去重合并算法（按 标题+作者 归一化合并多来源结果）
    nonisolated static func mergeBookResults(_ incoming: [BookRef], into existing: [MergedSearchItem]) -> [MergedSearchItem] {
        var result = existing
        var index: [String: Int] = [:]
        for (i, item) in result.enumerated() { index[item.primary.normalizedKey] = i }
        for book in incoming {
            let key = book.normalizedKey
            if let idx = index[key] {
                var item = result[idx]
                if item.primary.id != book.id && !item.alternatives.contains(where: { $0.id == book.id }) {
                    item.alternatives.append(book)
                    result[idx] = item
                }
            } else {
                index[key] = result.count
                result.append(MergedSearchItem(primary: book, alternatives: []))
            }
        }
        return result
    }

    /// 标题与关键词的相关度：3 精确 / 2 前缀 / 1 包含 / 0 其他
    nonisolated static func relevance(title: String, keyword: String) -> Int {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return 0 }
        if t == k { return 3 }
        if t.hasPrefix(k) { return 2 }
        if t.contains(k) { return 1 }
        return 0
    }

    private func mergeIncoming(_ books: [BookRef]) {
        for book in books {
            let key = book.normalizedKey
            if let idx = mergedIndex[key] {
                var item = mergedResults[idx]
                if item.primary.id != book.id && !item.alternatives.contains(where: { $0.id == book.id }) {
                    item.alternatives.append(book)
                    mergedResults[idx] = item
                }
            } else {
                mergedIndex[key] = mergedResults.count
                mergedResults.append(MergedSearchItem(primary: book, alternatives: []))
            }
        }
        resortResults()
    }

    private func resortResults() {
        let kw = searchedKeyword
        sortedResults = mergedResults.enumerated().sorted { a, b in
            let ra = Self.relevance(title: a.element.primary.title, keyword: kw)
            let rb = Self.relevance(title: b.element.primary.title, keyword: kw)
            if ra != rb { return ra > rb }
            let ca = a.element.alternatives.count
            let cb = b.element.alternatives.count
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func resetResults() {
        mergedResults = []
        sortedResults = []
        mergedIndex = [:]
        rawBySource = [:]
        failedSources = []
        completedSourcesCount = 0
        totalSourcesCount = 0
        skippedSourcesCount = 0
        elapsedSecondsText = ""
    }

    var displayedResults: [MergedSearchItem] {
        guard let filterID = selectedSourceFilterID else {
            return sortedResults
        }
        if let list = rawBySource[filterID] {
            return list.map { MergedSearchItem(primary: $0, alternatives: []) }
        }
        return []
    }

    func sourceFilterChips(plugins: [PluginRecord]) -> [SourceSearchFilterChip] {
        var nameMap: [String: String] = [:]
        for p in plugins {
            nameMap[p.id] = p.name
        }
        return rawBySource.compactMap { srcID, books in
            guard !books.isEmpty else { return nil }
            return SourceSearchFilterChip(
                sourceID: srcID,
                sourceName: nameMap[srcID] ?? srcID,
                count: books.count
            )
        }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.sourceName.localizedCompare(b.sourceName) == .orderedAscending
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func clearSearch() {
        cancelSearch()
        keyword = ""
        searchedKeyword = ""
        hasSearched = false
        selectedSourceFilterID = nil
        resetResults()
    }

    /// 参与本次搜索的书源：已启用、可搜索、符合分组范围，并预先剔除近期确认不可用的书源
    private func selectSearchablePlugins(_ plugins: [PluginRecord]) -> (active: [PluginRecord], skipped: Int) {
        var skipped = 0
        let now = Date()
        let active = plugins
            .filter { p in
                guard p.isEnabled && p.searchable else { return false }
                if let gid = selectedGroupID, p.groupID != gid { return false }
                if p.healthState == .unavailable,
                   let checked = p.lastCheckedAt,
                   now.timeIntervalSince(checked) < Self.unavailableSkipWindow {
                    skipped += 1
                    return false
                }
                return true
            }
            .sorted { $0.searchPriorityScore < $1.searchPriorityScore }
        return (active, skipped)
    }

    /// 并发滑动窗口流式搜索：优先跑高可用/置顶/低延迟源；每源独立超时；整体超过期限后不再启动新源
    func performSearch(plugins: [PluginRecord]) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searchTask?.cancel()
        searchGeneration &+= 1
        let currentGen = searchGeneration
        let startTime = CFAbsoluteTimeGetCurrent()

        let (activePlugins, skipped) = selectSearchablePlugins(plugins)

        resetResults()
        searchedKeyword = trimmed
        hasSearched = true
        selectedSourceFilterID = nil
        totalSourcesCount = activePlugins.count
        skippedSourcesCount = skipped

        guard !activePlugins.isEmpty else {
            isSearching = false
            return
        }

        isSearching = true
        let pluginSnapshots: [SearchPluginSnapshot] = activePlugins.map {
            SearchPluginSnapshot(id: $0.id, name: $0.name, siteURL: $0.siteURL)
        }
        let maxConcurrency = Self.maxConcurrency
        let launchDeadline = Self.launchDeadlineSec
        let perSourceTimeout = Self.perSourceTimeout
        let pluginByID: [String: PluginRecord] = Dictionary(
            activePlugins.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        searchTask = Task {
            let stream = AsyncStream<SingleSourceSearchEvent> { continuation in
                let producer = Task.detached(priority: .userInitiated) {
                    await withTaskGroup(of: SingleSourceSearchEvent.self) { group in
                        var nextIndex = 0
                        let total = pluginSnapshots.count

                        for _ in 0..<min(maxConcurrency, total) {
                            let snap = pluginSnapshots[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                await Self.searchSingleSource(
                                    sourceID: snap.id,
                                    sourceName: snap.name,
                                    siteURL: snap.siteURL,
                                    keyword: trimmed,
                                    timeoutSec: perSourceTimeout
                                )
                            }
                        }

                        for await item in group {
                            continuation.yield(item)
                            // 超过启动期限后不再启动新的书源
                            if !Task.isCancelled,
                               nextIndex < total,
                               CFAbsoluteTimeGetCurrent() - startTime < launchDeadline {
                                let snap = pluginSnapshots[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    await Self.searchSingleSource(
                                        sourceID: snap.id,
                                        sourceName: snap.name,
                                        siteURL: snap.siteURL,
                                        keyword: trimmed,
                                        timeoutSec: perSourceTimeout
                                    )
                                }
                            }
                        }
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
            }

            for await event in stream {
                guard !Task.isCancelled, currentGen == searchGeneration else { break }
                completedSourcesCount += 1
                elapsedSecondsText = String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - startTime)

                switch event.outcome {
                case .success(let books):
                    if !books.isEmpty {
                        rawBySource[event.sourceID] = books
                        mergeIncoming(books)
                    }
                    if let matched = pluginByID[event.sourceID] {
                        Self.applyHealth(
                            to: matched,
                            status: event.latencyMs <= 1500 ? .healthy : .slow,
                            latencyMs: event.latencyMs,
                            message: books.isEmpty ? nil : "搜索返回 \(books.count) 条"
                        )
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
                    if let matched = pluginByID[event.sourceID] {
                        switch err {
                        case .needLogin, .needVerify:
                            Self.applyHealth(to: matched, status: .needAuth, latencyMs: nil, message: err.localizedDescription)
                        default:
                            // 搜索失败（超时/网络/解析）：标记为不可用，之后的搜索会先跳过，直到重新检测或超过 6 小时
                            Self.applyHealth(to: matched, status: .unavailable, latencyMs: nil, message: err.localizedDescription)
                        }
                    }
                }
            }

            if !Task.isCancelled && currentGen == searchGeneration {
                isSearching = false
                // 因超过启动期限而未启动的书源，不再计入总数，避免进度停在 N-1/N
                if completedSourcesCount < totalSourcesCount {
                    skippedSourcesCount += totalSourcesCount - completedSourcesCount
                    totalSourcesCount = completedSourcesCount
                }
                elapsedSecondsText = String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - startTime)
            }
        }
    }

    /// 仅在值变化时写入，减少 SwiftData 触发的界面刷新
    private static func applyHealth(
        to plugin: PluginRecord,
        status: SourceHealthState,
        latencyMs: Int?,
        message: String?
    ) {
        if plugin.lastCheckStatus != status.rawValue { plugin.lastCheckStatus = status.rawValue }
        if let ms = latencyMs, plugin.lastLatencyMs != ms { plugin.lastLatencyMs = ms }
        if let msg = message, plugin.lastCheckMessage != msg { plugin.lastCheckMessage = msg }
        plugin.lastCheckedAt = .now
    }

    /// 单个失败/需验证源在完成就地登录或人机验证后单独重搜并合并入当前结果
    func retrySingleSource(sourceID: String, plugins: [PluginRecord]) {
        let kw = searchedKeyword.isEmpty ? keyword.trimmingCharacters(in: .whitespacesAndNewlines) : searchedKeyword
        guard !kw.isEmpty, let plugin = plugins.first(where: { $0.id == sourceID }) else { return }
        let sid = plugin.id
        let sName = plugin.name
        let sURL = plugin.siteURL

        Task {
            let res = await Self.searchSingleSource(
                sourceID: sid,
                sourceName: sName,
                siteURL: sURL,
                keyword: kw,
                timeoutSec: Self.perSourceTimeout
            )
            if case .success(let books) = res.outcome {
                failedSources.removeAll { $0.sourceID == sourceID }
                if !books.isEmpty {
                    rawBySource[sourceID] = books
                    mergeIncoming(books)
                }
                Self.applyHealth(
                    to: plugin,
                    status: res.latencyMs <= 1500 ? .healthy : .slow,
                    latencyMs: res.latencyMs,
                    message: "验证通过（返回 \(books.count) 条）"
                )
            }
        }
    }

    nonisolated private static func searchSingleSource(
        sourceID: String,
        sourceName: String,
        siteURL: String,
        keyword: String,
        timeoutSec: Double
    ) async -> SingleSourceSearchEvent {
        let start = CFAbsoluteTimeGetCurrent()
        func elapsedMs() -> Int { max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) }
        do {
            let dto = try await PluginRuntime.shared.search(
                sourceID: sourceID,
                keyword: keyword,
                page: 1,
                timeoutSec: timeoutSec
            )
            return SingleSourceSearchEvent(
                sourceID: sourceID, sourceName: sourceName, siteURL: siteURL,
                latencyMs: elapsedMs(), outcome: .success(dto.books)
            )
        } catch let pErr as PluginError {
            return SingleSourceSearchEvent(
                sourceID: sourceID, sourceName: sourceName, siteURL: siteURL,
                latencyMs: elapsedMs(), outcome: .failure(pErr)
            )
        } catch {
            return SingleSourceSearchEvent(
                sourceID: sourceID, sourceName: sourceName, siteURL: siteURL,
                latencyMs: elapsedMs(), outcome: .failure(.network(error.localizedDescription))
            )
        }
    }
}

/// 搜索页（固定底栏第 2 项）：常驻显式搜索栏、热搜与历史记录、滑动窗口并发流式搜索、按书源二次筛选与就地人机验证
struct SearchView: View {
    let onSelectMergedItem: (MergedSearchItem) -> Void
    let onNavigateToPluginManager: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]
    @Query(sort: [SortDescriptor(\SearchHistory.updatedAt, order: .reverse)]) private var histories: [SearchHistory]

    @Bindable var viewModel: SearchViewModel

    init(
        viewModel: SearchViewModel = SearchViewModel(),
        onSelectMergedItem: @escaping (MergedSearchItem) -> Void,
        onNavigateToPluginManager: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onSelectMergedItem = onSelectMergedItem
        self.onNavigateToPluginManager = onNavigateToPluginManager
    }
    @State private var showFailedDetails = false
    @State private var authSession: WebAuthSessionRequest?
    @FocusState private var isSearchFieldFocused: Bool

    private var searchableEnabledCount: Int {
        plugins.filter { $0.isEnabled && $0.searchable }.count
    }

    private var sourceNameByID: [String: String] {
        Dictionary(plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeCapsuleBar

            if viewModel.hasSearched {
                searchProgressBanner
                sourceResultFilterBar
                searchedContentBody
            } else {
                preSearchContentBody
            }
        }
        .background(DSColor.contentBackground)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onNavigateToPluginManager()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("书源(\(searchableEnabledCount))")
                            .font(.caption.weight(.medium))
                    }
                }
                .accessibilityLabel("前往书源管理")
            }
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
        .onAppear {
            BottomDockController.shared.onSubmitInlineSearch = { rawKeyword in
                submitSearch(rawKeyword)
            }
        }
    }

    // MARK: - 顶部常驻搜索栏（含搜索按钮与一键清空，彻底避免 .searchable 焦点丢失）

    private var searchInputHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索书名、作者、演播…", text: $viewModel.keyword)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        submitSearch(viewModel.keyword)
                    }

                if !viewModel.keyword.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索词")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DSColor.cardSurface)
            )

            if viewModel.isSearching {
                Button("停止") {
                    viewModel.cancelSearch()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            } else {
                Button {
                    submitSearch(viewModel.keyword)
                } label: {
                    Text("搜索")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(DSColor.primary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var scopeCapsuleBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let allSelected = viewModel.selectedGroupID == nil
                Button {
                    viewModel.selectedGroupID = nil
                    if viewModel.hasSearched && !viewModel.keyword.isEmpty {
                        viewModel.performSearch(plugins: plugins)
                    }
                } label: {
                    Text("全部书源")
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
                        if viewModel.hasSearched && !viewModel.keyword.isEmpty {
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
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var searchProgressBanner: some View {
        if viewModel.totalSourcesCount > 0 || viewModel.skippedSourcesCount > 0 {
            HStack(spacing: 8) {
                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在搜索 \(viewModel.completedSourcesCount)/\(viewModel.totalSourcesCount) 个书源 · 已合并 \(viewModel.mergedResults.count) 本")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("搜索完成：共 \(viewModel.mergedResults.count) 本 · 检索 \(viewModel.completedSourcesCount) 个源 (\(viewModel.elapsedSecondsText))\(viewModel.skippedSourcesCount > 0 ? " · 已跳过 \(viewModel.skippedSourcesCount) 个不可用源" : "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.hasSearched {
                    Button("重新搜索") {
                        viewModel.performSearch(plugins: plugins)
                    }
                    .font(.caption2.weight(.medium))
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sourceResultFilterBar: some View {
        let chips = viewModel.sourceFilterChips(plugins: plugins)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let allActive = viewModel.selectedSourceFilterID == nil
                    Button {
                        viewModel.selectedSourceFilterID = nil
                    } label: {
                        Text("合并去重 (\(viewModel.mergedResults.count))")
                            .font(.caption2.weight(allActive ? .semibold : .regular))
                            .foregroundStyle(allActive ? DSColor.primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .strokeBorder(allActive ? DSColor.primary : Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(chips) { chip in
                        let selected = viewModel.selectedSourceFilterID == chip.sourceID
                        Button {
                            viewModel.selectedSourceFilterID = selected ? nil : chip.sourceID
                        } label: {
                            Text("\(chip.sourceName) (\(chip.count))")
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? DSColor.primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .strokeBorder(selected ? DSColor.primary : Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - 搜索前视图（热搜推荐 + 搜索历史 + 书源状态引导）

    @ViewBuilder
    private var preSearchContentBody: some View {
        if plugins.isEmpty || searchableEnabledCount == 0 {
            ContentUnavailableView {
                Label(plugins.isEmpty ? "尚未安装任何书源" : "暂无已启用的可搜索书源", systemImage: "puzzlepiece.extension")
            } description: {
                Text("请先前往「书源管理」导入或启用书源，即可跨全网书源并发聚合搜索")
            } actions: {
                Button("前往书源管理") {
                    onNavigateToPluginManager()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                hotKeywordsSection
                if !histories.isEmpty {
                    searchHistorySection
                }
            }
            .listStyle(.insetGrouped)
            .dsAdaptiveBottomDockScroll()
        }
    }

    private var hotKeywordsSection: some View {
        Section("热门搜索推荐（点击即搜）") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(SearchViewModel.suggestedKeywords, id: \.self) { word in
                    Button {
                        submitSearch(word)
                    } label: {
                        Text(word)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(DSColor.cardSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var searchHistorySection: some View {
        Section {
            ForEach(histories) { item in
                Button {
                    submitSearch(item.keyword)
                } label: {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(item.keyword)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        modelContext.delete(item)
                        try? modelContext.save()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                Text("最近搜索")
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
    }

    // MARK: - 搜索结果流式视图

    @ViewBuilder
    private var searchedContentBody: some View {
        if viewModel.displayedResults.isEmpty && viewModel.isSearching {
            VStack(spacing: 14) {
                Spacer()
                ProgressView()
                Text("正在并发检索 \(viewModel.totalSourcesCount) 个书源…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("结果将随各书源响应实时流式呈现")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else if viewModel.displayedResults.isEmpty && !viewModel.isSearching {
            emptySearchedResultView
        } else {
            let names = sourceNameByID
            List {
                ForEach(viewModel.displayedResults) { merged in
                    searchResultRow(for: merged, names: names)
                }

                if !viewModel.failedSources.isEmpty {
                    failedSourcesSection
                }
            }
            .listStyle(.plain)
            .dsAdaptiveBottomDockScroll()
        }
    }

    private var emptySearchedResultView: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("未找到「\(viewModel.searchedKeyword)」的相关结果")
                        .font(.headline)
                    Text("可尝试更换关键词、切换「全部书源」，或在下方对需验证的书源完成人机验证后重试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("重新搜索") {
                            viewModel.performSearch(plugins: plugins)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("书源管理与测速") {
                            onNavigateToPluginManager()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            if !viewModel.failedSources.isEmpty {
                failedSourcesSection
            }
        }
        .listStyle(.insetGrouped)
    }

    private func searchResultRow(for merged: MergedSearchItem, names: [String: String]) -> some View {
        let primary = merged.primary
        let sourceName = names[primary.sourceID] ?? primary.sourceID

        return HStack(alignment: .top, spacing: 12) {
            CoverImageView(
                url: primary.cover,
                title: primary.title,
                width: 64,
                height: 86,
                cornerRadius: 6
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(primary.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !primary.author.isEmpty {
                    Text(primary.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !primary.intro.isEmpty {
                    Text(primary.intro)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text("来自 \(sourceName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DSColor.cardSurface)
                        .clipShape(Capsule())

                    if !merged.alternatives.isEmpty {
                        Text("另有 \(merged.alternatives.count) 个可用书源")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(DSColor.primary)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectMergedItem(merged)
        }
    }

    private var failedSourcesSection: some View {
        Section {
            Button {
                showFailedDetails.toggle()
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(viewModel.failedSources.count) 个书源未返回结果或需验证")
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
                                .lineLimit(2)
                        }
                        Spacer()
                        if case .needVerify(_, let vURL) = failed.error {
                            Button("去验证") {
                                openVerificationSheet(for: failed, fallbackURL: vURL)
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
                                        viewModel.retrySingleSource(sourceID: failed.sourceID, plugins: plugins)
                                    }
                                )
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("重试") {
                                viewModel.retrySingleSource(sourceID: failed.sourceID, plugins: plugins)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private func openVerificationSheet(for failed: FailedSourceSummary, fallbackURL: String) {
        let kw = viewModel.searchedKeyword.isEmpty ? viewModel.keyword : viewModel.searchedKeyword
        Task {
            let resolved = await PluginRuntime.shared.searchVerificationURL(sourceID: failed.sourceID, keyword: kw)
            let targetURL = resolved?.url ?? (fallbackURL.isEmpty ? failed.siteURL : fallbackURL)
            authSession = WebAuthSessionRequest(
                sourceID: failed.sourceID,
                title: "搜索验证 · \(failed.sourceName)",
                initialURL: targetURL,
                expectedCookieName: nil,
                onCompleted: {
                    viewModel.retrySingleSource(sourceID: failed.sourceID, plugins: plugins)
                }
            )
        }
    }

    private func submitSearch(_ rawKeyword: String) {
        let trimmed = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFieldFocused = false
        BottomDockController.shared.isSearchFieldFocused = false
        viewModel.keyword = trimmed
        recordHistory(trimmed)
        viewModel.performSearch(plugins: plugins)
    }

    private func recordHistory(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = histories.first(where: { $0.keyword == trimmed }) {
            existing.updatedAt = .now
        } else {
            modelContext.insert(SearchHistory(keyword: trimmed, updatedAt: .now))
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
