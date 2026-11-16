import SwiftUI
import SwiftData

struct IndexedDiscoverSection: Identifiable, Equatable {
    var id: String { "\(index)_\(section.title)" }
    let index: Int
    let section: DiscoverSectionDTO
}

struct IndexedDiscoverTab: Identifiable, Equatable {
    var id: String { "\(index)_\(tab.id)" }
    let index: Int
    let tab: DiscoverTabDTO
}

@MainActor
@Observable
final class DiscoverViewModel {
    var activeSourceID: String = ""
    var sections: [DiscoverSectionDTO] = []
    var selectedSectionIndex: Int = 0
    var selectedTabIndex: Int = 0
    var items: [BookRef] = []
    var nextPageURL: String?
    var currentPage: Int = 1
    var totalPage: Int = 1
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var currentError: PluginError?
    var inSourceSearchKeyword: String = ""
    var isInSourceSearching: Bool = false

    private var sessionCache: [String: (sections: [DiscoverSectionDTO], items: [BookRef], nextURL: String?)] = [:]
    private var loadTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0

    var indexedSections: [IndexedDiscoverSection] {
        sections.enumerated().map { IndexedDiscoverSection(index: $0.offset, section: $0.element) }
    }

    var activeSection: DiscoverSectionDTO? {
        guard sections.indices.contains(selectedSectionIndex) else { return nil }
        return sections[selectedSectionIndex]
    }

    var indexedActiveTabs: [IndexedDiscoverTab] {
        guard let sec = activeSection else { return [] }
        return sec.tabs.enumerated().map { IndexedDiscoverTab(index: $0.offset, tab: $0.element) }
    }

    var activeTab: DiscoverTabDTO? {
        guard let sec = activeSection, sec.tabs.indices.contains(selectedTabIndex) else { return nil }
        return sec.tabs[selectedTabIndex]
    }

    func switchSourceIfNeeded(to sourceID: String) {
        if activeSourceID != sourceID {
            loadTask?.cancel()
            loadMoreTask?.cancel()
            activeSourceID = sourceID
            sections = []
            items = []
            selectedSectionIndex = 0
            selectedTabIndex = 0
            nextPageURL = nil
            currentPage = 1
            totalPage = 1
            currentError = nil
            isLoading = false
            isLoadingMore = false
        }
        loadSource(sourceID: sourceID)
    }

    func selectSection(_ index: Int, sourceID: String) {
        guard sections.indices.contains(index) else { return }
        selectedSectionIndex = index
        selectedTabIndex = 0
        loadSource(sourceID: sourceID)
    }

    func selectTab(_ index: Int, sourceID: String) {
        guard let sec = activeSection, sec.tabs.indices.contains(index) else { return }
        selectedTabIndex = index
        loadSource(sourceID: sourceID)
    }

    func loadSource(sourceID: String, forceRefresh: Bool = false) {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        isLoadingMore = false

        guard !sourceID.isEmpty else {
            sections = []
            items = []
            currentError = nil
            isLoading = false
            return
        }

        if activeSourceID != sourceID {
            activeSourceID = sourceID
            sections = []
            items = []
            selectedSectionIndex = 0
            selectedTabIndex = 0
            nextPageURL = nil
        }

        let cacheKey = "\(sourceID)_\(selectedSectionIndex)_\(selectedTabIndex)"
        if !forceRefresh, !isInSourceSearching, let cached = sessionCache[cacheKey] {
            sections = cached.sections
            if !sections.indices.contains(selectedSectionIndex) {
                selectedSectionIndex = 0
            }
            if let sec = activeSection, !sec.tabs.indices.contains(selectedTabIndex) {
                selectedTabIndex = 0
            }
            items = cached.items
            nextPageURL = cached.nextURL
            currentError = nil
            isLoading = false
            return
        }

        requestGeneration &+= 1
        let currentGen = requestGeneration

        loadTask = Task {
            isLoading = true
            currentError = nil
            do {
                if isInSourceSearching && !inSourceSearchKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
                    let pageDTO = try await PluginRuntime.shared.search(
                        sourceID: sourceID,
                        keyword: inSourceSearchKeyword.trimmingCharacters(in: .whitespaces),
                        page: 1
                    )
                    guard !Task.isCancelled, currentGen == requestGeneration else { return }
                    items = pageDTO.books
                    currentPage = 1
                    totalPage = pageDTO.totalPage ?? 1
                    nextPageURL = nil
                } else {
                    if sections.isEmpty || forceRefresh {
                        let loadedSections = try await PluginRuntime.shared.discoverSections(sourceID: sourceID)
                        guard !Task.isCancelled, currentGen == requestGeneration else { return }
                        sections = loadedSections
                        if !sections.indices.contains(selectedSectionIndex) {
                            selectedSectionIndex = 0
                        }
                        selectedTabIndex = 0
                    }
                    if let tab = activeTab {
                        let resolvedCacheKey = "\(sourceID)_\(selectedSectionIndex)_\(selectedTabIndex)"
                        let pageDTO = try await PluginRuntime.shared.discoverList(sourceID: sourceID, tabURL: tab.url)
                        guard !Task.isCancelled, currentGen == requestGeneration else { return }
                        items = pageDTO.books
                        nextPageURL = pageDTO.nextPageURL
                        sessionCache[resolvedCacheKey] = (sections, items, nextPageURL)
                    } else {
                        items = []
                        nextPageURL = nil
                    }
                }
            } catch let pErr as PluginError {
                if !Task.isCancelled && currentGen == requestGeneration {
                    currentError = pErr
                }
            } catch {
                if !Task.isCancelled && currentGen == requestGeneration {
                    currentError = .network(error.localizedDescription)
                }
            }
            if !Task.isCancelled && currentGen == requestGeneration {
                isLoading = false
            }
        }
    }

    func loadNextPageIfNeeded(sourceID: String, currentItem: BookRef) {
        guard !isLoading, !isLoadingMore, items.count >= 6 else { return }
        let thresholdIndex = max(0, items.count - 6)
        guard items.indices.contains(thresholdIndex), items[thresholdIndex].id == currentItem.id else { return }

        let currentGen = requestGeneration
        if isInSourceSearching {
            guard currentPage < totalPage else { return }
            let nextPage = currentPage + 1
            isLoadingMore = true
            loadMoreTask = Task {
                defer { isLoadingMore = false }
                if let dto = try? await PluginRuntime.shared.search(
                    sourceID: sourceID,
                    keyword: inSourceSearchKeyword,
                    page: nextPage
                ), !Task.isCancelled, currentGen == requestGeneration {
                    currentPage = nextPage
                    appendUniqueBooks(dto.books)
                }
            }
        } else if let nextURL = nextPageURL, !nextURL.isEmpty {
            isLoadingMore = true
            loadMoreTask = Task {
                defer { isLoadingMore = false }
                if let dto = try? await PluginRuntime.shared.discoverList(sourceID: sourceID, tabURL: nextURL),
                   !Task.isCancelled, currentGen == requestGeneration {
                    nextPageURL = dto.nextPageURL
                    appendUniqueBooks(dto.books)
                }
            }
        }
    }

    private func appendUniqueBooks(_ incoming: [BookRef]) {
        var existingIDs = Set(items.map(\.id))
        for b in incoming where !existingIDs.contains(b.id) {
            existingIDs.insert(b.id)
            items.append(b)
        }
    }
}

/// 发现页（5.1 节）：书源切换器 Menu（含延迟提示与书源管理快捷入口）、网格/列表切换、纯色横向分类胶囊、就地登录/验证弹层与无书源引导
struct DiscoverView: View {
    let onNavigateToImportPlugins: () -> Void
    let onSwitchToSearch: () -> Void
    let onSelectBook: (BookRef) -> Void

    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    init(
        onNavigateToImportPlugins: @escaping () -> Void,
        onSwitchToSearch: @escaping () -> Void = {},
        onSelectBook: @escaping (BookRef) -> Void
    ) {
        self.onNavigateToImportPlugins = onNavigateToImportPlugins
        self.onSwitchToSearch = onSwitchToSearch
        self.onSelectBook = onSelectBook
    }

    @State private var viewModel = DiscoverViewModel()
    @State private var settings = AppSettingsStore.shared
    @State private var authSession: WebAuthSessionRequest?
    @State private var showInSourceSearch = false

    private var enabledDiscoverPlugins: [PluginRecord] {
        plugins
            .filter { $0.isEnabled && $0.discoverable }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
                return a.order < b.order
            }
    }

    private var currentPlugin: PluginRecord? {
        if let matched = enabledDiscoverPlugins.first(where: { $0.id == settings.currentDiscoverSourceID }) {
            return matched
        }
        return enabledDiscoverPlugins.first
    }

    var body: some View {
        Group {
            if plugins.isEmpty {
                ContentUnavailableView {
                    Label("尚未安装书源", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("导入书源插件包（.zip 或在线地址）后即可浏览分类与收听有声内容")
                } actions: {
                    Button("前往书源管理导入") {
                        onNavigateToImportPlugins()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if enabledDiscoverPlugins.isEmpty {
                ContentUnavailableView {
                    Label("暂无可用发现书源", systemImage: "eye.slash")
                } description: {
                    Text("请在「设置 → 书源管理」中启用至少一个支持分类浏览的书源")
                } actions: {
                    Button("前往书源管理") {
                        onNavigateToImportPlugins()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                contentBody
            }
        }
        .background(DSColor.contentBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let active = currentPlugin {
                    sourceSwitcherMenu(active: active)
                } else {
                    Text("发现").font(.headline)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !enabledDiscoverPlugins.isEmpty {
                    Button {
                        showInSourceSearch.toggle()
                        if !showInSourceSearch {
                            viewModel.isInSourceSearching = false
                            viewModel.inSourceSearchKeyword = ""
                            if let id = currentPlugin?.id {
                                viewModel.loadSource(sourceID: id)
                            }
                        }
                    } label: {
                        Image(systemName: showInSourceSearch ? "xmark.circle" : "magnifyingglass")
                    }
                    .accessibilityLabel("源内搜索")

                    Button {
                        settings.discoverLayout = settings.discoverLayout == .grid ? .list : .grid
                    } label: {
                        Image(systemName: settings.discoverLayout == .grid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(settings.discoverLayout == .grid ? "切换为列表" : "切换为网格")
                }
            }
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
        .task(id: currentPlugin?.id ?? "") {
            if let plugin = currentPlugin {
                if settings.currentDiscoverSourceID != plugin.id {
                    settings.currentDiscoverSourceID = plugin.id
                }
                viewModel.switchSourceIfNeeded(to: plugin.id)
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        VStack(spacing: 0) {
            if showInSourceSearch, let plugin = currentPlugin {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("在「\(plugin.name)」内搜索…", text: $viewModel.inSourceSearchKeyword)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .onSubmit {
                            viewModel.isInSourceSearching = true
                            viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                        }
                    if !viewModel.inSourceSearchKeyword.isEmpty {
                        Button("搜索") {
                            viewModel.isInSourceSearching = true
                            viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DSColor.primary)
                    }
                }
                .padding(10)
                .background(DSColor.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)
            }

            if !viewModel.sections.isEmpty && !viewModel.isInSourceSearching {
                categoryCapsuleBar
            }

            if let err = viewModel.currentError, let plugin = currentPlugin {
                inlineErrorView(error: err, plugin: plugin)
            } else if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("正在加载「\(currentPlugin?.name ?? "")」内容…")
                Spacer()
            } else if viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label("暂无内容", systemImage: "book.closed")
                } description: {
                    Text("请尝试切换上方分类、下拉刷新或点击顶部标题切换其他书源")
                } actions: {
                    if let plugin = currentPlugin {
                        Button("刷新当前分类") {
                            viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                if settings.discoverLayout == .grid {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
                            spacing: 16
                        ) {
                            ForEach(viewModel.items) { book in
                                DiscoverGridCell(book: book)
                                    .onTapGesture {
                                        onSelectBook(book)
                                    }
                                    .onAppear {
                                        if let id = currentPlugin?.id {
                                            viewModel.loadNextPageIfNeeded(sourceID: id, currentItem: book)
                                        }
                                    }
                            }
                        }
                        .padding(DSSpacing.lg)
                    }
                    .refreshable {
                        if let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id, forceRefresh: true)
                        }
                    }
                } else {
                    List(viewModel.items) { book in
                        DiscoverListRow(book: book)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectBook(book)
                            }
                            .onAppear {
                                if let id = currentPlugin?.id {
                                    viewModel.loadNextPageIfNeeded(sourceID: id, currentItem: book)
                                }
                            }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        if let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id, forceRefresh: true)
                        }
                    }
                }
            }
        }
    }

    private func menuTitle(for item: PluginRecord) -> String {
        if item.lastLatencyMs > 0 && item.isHealthyOrSlow {
            return "\(item.name) (\(item.lastLatencyMs)ms)"
        }
        if item.healthState == .unavailable {
            return "\(item.name) (不可用)"
        }
        return item.name
    }

    private func sourceSwitcherMenu(active: PluginRecord) -> some View {
        Menu {
            let pinned = enabledDiscoverPlugins.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("置顶书源") {
                    ForEach(pinned) { item in
                        Button {
                            settings.currentDiscoverSourceID = item.id
                            viewModel.switchSourceIfNeeded(to: item.id)
                        } label: {
                            Label(menuTitle(for: item), systemImage: item.id == active.id ? "checkmark" : "pin.fill")
                        }
                    }
                }
            }
            ForEach(groups) { group in
                let inGroup = enabledDiscoverPlugins.filter { $0.groupID == group.id && !$0.isPinned }
                if !inGroup.isEmpty {
                    Section(group.name) {
                        ForEach(inGroup) { item in
                            Button {
                                settings.currentDiscoverSourceID = item.id
                                viewModel.switchSourceIfNeeded(to: item.id)
                            } label: {
                                if item.id == active.id {
                                    Label(menuTitle(for: item), systemImage: "checkmark")
                                } else {
                                    Text(menuTitle(for: item))
                                }
                            }
                        }
                    }
                }
            }
            let ungrouped = enabledDiscoverPlugins.filter { ($0.groupID == nil || $0.groupID == "") && !$0.isPinned }
            if !ungrouped.isEmpty {
                Section("未分组") {
                    ForEach(ungrouped) { item in
                        Button {
                            settings.currentDiscoverSourceID = item.id
                            viewModel.switchSourceIfNeeded(to: item.id)
                        } label: {
                            if item.id == active.id {
                                Label(menuTitle(for: item), systemImage: "checkmark")
                            } else {
                                Text(menuTitle(for: item))
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    onNavigateToImportPlugins()
                } label: {
                    Label("书源管理与延迟检测…", systemImage: "bolt.horizontal.circle")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(active.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if active.lastLatencyMs > 0 && active.isHealthyOrSlow {
                    Text("\(active.lastLatencyMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("切换书源，当前为\(active.name)")
    }

    private var categoryCapsuleBar: some View {
        VStack(spacing: 8) {
            let indexedSecs = viewModel.indexedSections
            if indexedSecs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(indexedSecs) { entry in
                            let selected = entry.index == viewModel.selectedSectionIndex
                            Button {
                                if let id = currentPlugin?.id {
                                    viewModel.selectSection(entry.index, sourceID: id)
                                }
                            } label: {
                                Text(entry.section.title)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .white : .primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? DSColor.primary : DSColor.cardSurface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                }
            }

            let indexedTabs = viewModel.indexedActiveTabs
            if !indexedTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(indexedTabs) { entry in
                            let selected = entry.index == viewModel.selectedTabIndex
                            Button {
                                if let id = currentPlugin?.id {
                                    viewModel.selectTab(entry.index, sourceID: id)
                                }
                            } label: {
                                Text(entry.tab.title)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .white : .primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? DSColor.primary : DSColor.cardSurface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                }
            }
        }
        .padding(.vertical, 8)
        .background(DSColor.contentBackground)
    }

    @ViewBuilder
    private func inlineErrorView(error: PluginError, plugin: PluginRecord) -> some View {
        ContentUnavailableView {
            Label("「\(plugin.name)」加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            HStack(spacing: 12) {
                switch error {
                case .needLogin(_, let loginURL):
                    Button("去登录") {
                        authSession = WebAuthSessionRequest(
                            sourceID: plugin.id,
                            title: "登录 \(plugin.name)",
                            initialURL: loginURL.isEmpty ? plugin.siteURL : loginURL,
                            expectedCookieName: nil,
                            onCompleted: {
                                plugin.loggedIn = true
                                viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                            }
                        )
                    }
                    .buttonStyle(.borderedProminent)
                case .needVerify(_, let verifyURL):
                    Button("去验证") {
                        authSession = WebAuthSessionRequest(
                            sourceID: plugin.id,
                            title: "安全验证 · \(plugin.name)",
                            initialURL: verifyURL.isEmpty ? plugin.siteURL : verifyURL,
                            expectedCookieName: nil,
                            onCompleted: {
                                viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                            }
                        )
                    }
                    .buttonStyle(.borderedProminent)
                default:
                    Button("重试") {
                        viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("书源管理") {
                    onNavigateToImportPlugins()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct DiscoverGridCell: View, Equatable {
    let book: BookRef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImageView(
                url: book.cover,
                title: book.title,
                width: 104,
                height: 138,
                cornerRadius: 8
            )
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
    }
}

struct DiscoverListRow: View, Equatable {
    let book: BookRef

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImageView(
                url: book.cover,
                title: book.title,
                width: 64,
                height: 86,
                cornerRadius: 6
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(book.intro.isEmpty ? "点击查看章节详情" : book.intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .background(DSColor.contentBackground)
    }
}
