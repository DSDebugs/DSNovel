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
    /// 每个书源的分类菜单缓存：切换书源时先秒出分类，只需再请求一次列表（原先每次都要两次串行请求）
    private var sectionsCache: [String: [DiscoverSectionDTO]] = [:]
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
        // 同一书源且正在加载或已有内容：不重复请求（菜单切换与 .task(id:) 会连续触发两次）
        if activeSourceID == sourceID && (isLoading || !items.isEmpty) && currentError == nil {
            return
        }
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
        isInSourceSearching = false
        loadSource(sourceID: sourceID)
    }

    func selectTab(_ index: Int, sourceID: String) {
        guard let sec = activeSection, sec.tabs.indices.contains(index) else { return }
        selectedTabIndex = index
        isInSourceSearching = false
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

        // 同步置位，保证紧随其后的重复调用能识别「正在加载」而不会重复发起请求
        isLoading = true
        currentError = nil
        loadTask = Task {
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
                    if sections.isEmpty, !forceRefresh, let cachedSections = sectionsCache[sourceID], !cachedSections.isEmpty {
                        sections = cachedSections
                        if !sections.indices.contains(selectedSectionIndex) { selectedSectionIndex = 0 }
                        if let sec = activeSection, !sec.tabs.indices.contains(selectedTabIndex) { selectedTabIndex = 0 }
                    }
                    if sections.isEmpty || forceRefresh {
                        let loadedSections = try await PluginRuntime.shared.discoverSections(sourceID: sourceID)
                        guard !Task.isCancelled, currentGen == requestGeneration else { return }
                        sections = loadedSections
                        if !loadedSections.isEmpty { sectionsCache[sourceID] = loadedSections }
                        if !sections.indices.contains(selectedSectionIndex) {
                            selectedSectionIndex = 0
                        }
                        if let sec = activeSection, !sec.tabs.indices.contains(selectedTabIndex) {
                            selectedTabIndex = 0
                        }
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

// MARK: - 发现页（重构版：左对齐书源大标题 + 右侧搜索/布局/刷新三键 + 半屏首字徽标书源切换抽屉 + 一级下划线/二级胶囊分类栏 + 三列等比网格/紧凑列表）

struct DiscoverView: View {
    let onNavigateToImportPlugins: () -> Void
    let onSwitchToSearch: () -> Void
    let onSwitchToSearchWithKeyword: (String) -> Void
    let onSelectBook: (BookRef) -> Void

    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    init(
        onNavigateToImportPlugins: @escaping () -> Void,
        onSwitchToSearch: @escaping () -> Void = {},
        onSwitchToSearchWithKeyword: @escaping (String) -> Void = { _ in },
        onSelectBook: @escaping (BookRef) -> Void
    ) {
        self.onNavigateToImportPlugins = onNavigateToImportPlugins
        self.onSwitchToSearch = onSwitchToSearch
        self.onSwitchToSearchWithKeyword = onSwitchToSearchWithKeyword
        self.onSelectBook = onSelectBook
    }

    @State private var viewModel = DiscoverViewModel()
    @State private var settings = AppSettingsStore.shared
    @State private var authSession: WebAuthSessionRequest?
    @State private var showInSourceSearch = false
    @State private var showSourcePickerSheet = false
    @FocusState private var isInSourceSearchFocused: Bool
    @Namespace private var categoryUnderlineNS

    private static let threeColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
        count: 3
    )

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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSourcePickerSheet) {
            DiscoverSourcePickerSheet(
                plugins: enabledDiscoverPlugins,
                groups: groups,
                activePluginID: currentPlugin?.id ?? "",
                onSelect: { selected in
                    settings.currentDiscoverSourceID = selected.id
                    if showInSourceSearch {
                        showInSourceSearch = false
                        isInSourceSearchFocused = false
                        viewModel.isInSourceSearching = false
                        viewModel.inSourceSearchKeyword = ""
                    }
                    viewModel.switchSourceIfNeeded(to: selected.id)
                },
                onManageSources: {
                    onNavigateToImportPlugins()
                }
            )
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

    // MARK: - 1. 顶部沉浸式标题栏（左对齐书源大标题 + 右侧搜索/布局切换/刷新三键）

    private var discoverTopBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                isInSourceSearchFocused = false
                showSourcePickerSheet = true
            } label: {
                HStack(spacing: 6) {
                    Text(currentPlugin?.name ?? "发现")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showSourcePickerSheet ? 180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: showSourcePickerSheet)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换听书源，当前为\(currentPlugin?.name ?? "发现")")

            Spacer(minLength: 8)

            if !enabledDiscoverPlugins.isEmpty {
                // ① 源内搜索切换按钮（magnifyingglass <-> xmark，对齐参考截图 2）
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showInSourceSearch.toggle()
                    }
                    if showInSourceSearch {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(90))
                            isInSourceSearchFocused = true
                        }
                    } else {
                        isInSourceSearchFocused = false
                        let wasSearching = viewModel.isInSourceSearching
                        viewModel.isInSourceSearching = false
                        viewModel.inSourceSearchKeyword = ""
                        if wasSearching, let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id)
                        }
                    }
                } label: {
                    Image(systemName: showInSourceSearch ? "xmark" : "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showInSourceSearch ? "关闭源内搜索" : "在当前书源内搜索")

                // ② 布局切换按钮（网格态显示列表图标 list.bullet，列表态显示网格图标 square.grid.2x2，对齐参考截图 3/4）
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.discoverLayout = settings.discoverLayout == .grid ? .list : .grid
                    }
                } label: {
                    Image(systemName: settings.discoverLayout == .grid ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.discoverLayout == .grid ? "切换为列表视图" : "切换为三列网格视图")

                // ③ 显式强制刷新按钮（加载中自动旋转，对齐参考截图右上角刷新图标）
                Button {
                    if let id = currentPlugin?.id {
                        viewModel.loadSource(sourceID: id, forceRefresh: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(
                            viewModel.isLoading
                                ? .linear(duration: 0.85).repeatForever(autoreverses: false)
                                : .default,
                            value: viewModel.isLoading
                        )
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新当前分类")
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 2. 源内搜索输入框（平滑展开于顶栏下方，同时保留分类栏与列表内容）

    @ViewBuilder
    private var inSourceSearchBar: some View {
        if showInSourceSearch, let plugin = currentPlugin {
            HStack(spacing: 8) {
                TextField("在“\(plugin.name)”里搜索", text: $viewModel.inSourceSearchKeyword)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($isInSourceSearchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        triggerInSourceSearch(pluginID: plugin.id)
                    }

                if !viewModel.inSourceSearchKeyword.isEmpty {
                    Button {
                        viewModel.inSourceSearchKeyword = ""
                        if viewModel.isInSourceSearching {
                            viewModel.isInSourceSearching = false
                            viewModel.loadSource(sourceID: plugin.id)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空源内搜索词")

                    Button {
                        isInSourceSearchFocused = false
                        triggerInSourceSearch(pluginID: plugin.id)
                    } label: {
                        Text("搜索")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DSColor.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                    )
            )
            .padding(.horizontal, DSSpacing.lg)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func triggerInSourceSearch(pluginID: String) {
        let trimmed = viewModel.inSourceSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.isInSourceSearching = true
        viewModel.loadSource(sourceID: pluginID, forceRefresh: true)
    }

    // MARK: - 3. 双层差异化分类导航栏（一级文字+下划线横条 · 二级描边/填充胶囊）

    private var categoryHierarchyBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            let indexedSecs = viewModel.indexedSections
            if !indexedSecs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(indexedSecs) { entry in
                            let selected = entry.index == viewModel.selectedSectionIndex && !viewModel.isInSourceSearching
                            let rawTitle = entry.section.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            Button {
                                if let id = currentPlugin?.id {
                                    isInSourceSearchFocused = false
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        viewModel.selectSection(entry.index, sourceID: id)
                                    }
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    Text(rawTitle.isEmpty ? "推荐" : rawTitle)
                                        .font(.system(size: 16, weight: selected ? .bold : .medium))
                                        .foregroundStyle(selected ? DSColor.primary : .secondary)

                                    ZStack {
                                        Capsule()
                                            .fill(Color.clear)
                                            .frame(width: 18, height: 3)
                                        if selected {
                                            Capsule()
                                                .fill(DSColor.primary)
                                                .frame(width: 18, height: 3)
                                                .matchedGeometryEffect(id: "discover_sec_underline", in: categoryUnderlineNS)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
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
                    HStack(spacing: 10) {
                        ForEach(indexedTabs) { entry in
                            let selected = entry.index == viewModel.selectedTabIndex && !viewModel.isInSourceSearching
                            Button {
                                if let id = currentPlugin?.id {
                                    isInSourceSearchFocused = false
                                    viewModel.selectTab(entry.index, sourceID: id)
                                }
                            } label: {
                                Text(entry.tab.title)
                                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? DSColor.primary : .secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? DSColor.primary.opacity(0.16) : Color.clear)
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(
                                                selected ? DSColor.primary.opacity(0.45) : Color.primary.opacity(0.18),
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.lg)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(DSColor.contentBackground)
    }

    // MARK: - 4. 主内容区域（三列等比网格 / 单列详情列表）

    @ViewBuilder
    private var contentBody: some View {
        VStack(spacing: 0) {
            discoverTopBar
            inSourceSearchBar

            if !viewModel.sections.isEmpty {
                categoryHierarchyBar
            }

            if let err = viewModel.currentError, let plugin = currentPlugin {
                inlineErrorView(error: err, plugin: plugin)
            } else if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("正在加载「\(currentPlugin?.name ?? "")」内容…")
                Spacer()
            } else if viewModel.items.isEmpty {
                emptyDiscoverStateView
            } else {
                if settings.discoverLayout == .grid {
                    ScrollView {
                        LazyVGrid(columns: Self.threeColumns, spacing: 18) {
                            ForEach(viewModel.items) { book in
                                DiscoverGridCell(book: book)
                                    .onTapGesture {
                                        isInSourceSearchFocused = false
                                        onSelectBook(book)
                                    }
                                    .onAppear {
                                        if let id = currentPlugin?.id {
                                            viewModel.loadNextPageIfNeeded(sourceID: id, currentItem: book)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .dsAdaptiveBottomDockScroll()
                    .refreshable {
                        if let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id, forceRefresh: true)
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(viewModel.items) { book in
                                DiscoverListRow(book: book)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        isInSourceSearchFocused = false
                                        onSelectBook(book)
                                    }
                                    .onAppear {
                                        if let id = currentPlugin?.id {
                                            viewModel.loadNextPageIfNeeded(sourceID: id, currentItem: book)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .dsAdaptiveBottomDockScroll()
                    .refreshable {
                        if let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id, forceRefresh: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyDiscoverStateView: some View {
        let keyword = viewModel.inSourceSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        ContentUnavailableView {
            Label(viewModel.isInSourceSearching ? "未在「\(currentPlugin?.name ?? "")」找到匹配结果" : "暂无内容",
                  systemImage: viewModel.isInSourceSearching ? "magnifyingglass" : "book.closed")
        } description: {
            if viewModel.isInSourceSearching && !keyword.isEmpty {
                Text("当前书源没有返回与“\(keyword)”相关的有声书，可尝试跨全网书源聚合搜索")
            } else {
                Text("请尝试切换上方分类、点击右上角刷新或点击左上方书源名称切换其他听书源")
            }
        } actions: {
            HStack(spacing: 12) {
                if viewModel.isInSourceSearching && !keyword.isEmpty {
                    Button("全网搜索“\(keyword)”") {
                        isInSourceSearchFocused = false
                        onSwitchToSearchWithKeyword(keyword)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("返回分类浏览") {
                        viewModel.isInSourceSearching = false
                        viewModel.inSourceSearchKeyword = ""
                        if let id = currentPlugin?.id {
                            viewModel.loadSource(sourceID: id)
                        }
                    }
                    .buttonStyle(.bordered)
                } else if let plugin = currentPlugin {
                    Button("刷新当前分类") {
                        viewModel.loadSource(sourceID: plugin.id, forceRefresh: true)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("切换听书源") {
                        showSourcePickerSheet = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
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
                                plugin.loggedIn = CookieSync.isSourceLoggedIn(plugin.id)
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

                Button("切换听书源") {
                    showSourcePickerSheet = true
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - 5. 切换听书源半屏抽屉（还原参考截图 1：圆角矩形首字徽标 + 听书副标题 + 延迟/VIP 增强）

struct DiscoverSourcePickerSheet: View {
    let plugins: [PluginRecord]
    let groups: [PluginGroup]
    let activePluginID: String
    let onSelect: (PluginRecord) -> Void
    let onManageSources: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let pinned = plugins.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section("置顶书源") {
                        ForEach(pinned) { item in
                            sourceRow(for: item)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                    }
                }

                ForEach(groups) { group in
                    let inGroup = plugins.filter { !$0.isPinned && $0.groupID == group.id }
                    if !inGroup.isEmpty {
                        Section(group.name) {
                            ForEach(inGroup) { item in
                                sourceRow(for: item)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                let validGroupIDs = Set(groups.map(\.id))
                let ungrouped = plugins.filter { p in
                    guard !p.isPinned else { return false }
                    guard let gid = p.groupID, !gid.isEmpty else { return true }
                    return !validGroupIDs.contains(gid)
                }
                if !ungrouped.isEmpty {
                    Section(pinned.isEmpty && groups.isEmpty ? "" : "其他书源") {
                        ForEach(ungrouped) { item in
                            sourceRow(for: item)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DSColor.contentBackground)
            .navigationTitle("切换听书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onManageSources()
                    } label: {
                        HStack(spacing: 3) {
                            Text("书源管理")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private func sourceRow(for item: PluginRecord) -> some View {
        let isSelected = item.id == activePluginID
        return Button {
            onSelect(item)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                // 左侧圆角矩形首字徽标（对齐参考图 1）
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? DSColor.primary.opacity(0.24) : DSColor.primary.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Text(Self.firstCharacter(of: item.name))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DSColor.primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(DSColor.primary)
                        }

                        if item.loggedIn {
                            Text("已登录")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.14), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Text("听书")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if item.lastLatencyMs > 0 && item.isHealthyOrSlow {
                            Text("· \(item.lastLatencyMs)ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        } else if item.healthState == .unavailable {
                            Text("· 不可用")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if !item.summary.isEmpty {
                            Text("· \(item.summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DSColor.primary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func firstCharacter(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "源" }
        return String(first)
    }
}

// MARK: - 6. 三列等比网格卡片与紧凑单列列表行（对齐参考图 3 / 图 4）

struct DiscoverGridCell: View, Equatable {
    let book: BookRef

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let w = max(80, geo.size.width)
                let h = w * 1.34
                CoverImageView(
                    url: book.cover,
                    title: book.title,
                    width: w,
                    height: h,
                    cornerRadius: 8
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
                )
            }
            .aspectRatio(1.0 / 1.34, contentMode: .fit)

            Text(book.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 1)

            Text(book.discoverSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiscoverListRow: View, Equatable {
    let book: BookRef

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CoverImageView(
                url: book.cover,
                title: book.title,
                width: 62,
                height: 84,
                cornerRadius: 7
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(book.discoverSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !book.intro.isEmpty && book.intro != book.discoverSubtitle {
                    Text(book.intro)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(DSColor.contentBackground)
    }
}
