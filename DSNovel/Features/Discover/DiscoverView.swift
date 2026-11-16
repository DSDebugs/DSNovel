import SwiftUI
import SwiftData

@MainActor
@Observable
final class DiscoverViewModel {
    var sections: [DiscoverSectionDTO] = []
    var selectedSectionIndex: Int = 0
    var selectedTabIndex: Int = 0
    var items: [BookRef] = []
    var nextPageURL: String?
    var currentPage: Int = 1
    var totalPage: Int = 1
    var isLoading: Bool = false
    var currentError: PluginError?
    var inSourceSearchKeyword: String = ""
    var isInSourceSearching: Bool = false

    private var sessionCache: [String: (sections: [DiscoverSectionDTO], items: [BookRef], nextURL: String?)] = [:]
    private var loadTask: Task<Void, Never>?

    var activeSection: DiscoverSectionDTO? {
        guard selectedSectionIndex < sections.count else { return nil }
        return sections[selectedSectionIndex]
    }

    var activeTab: DiscoverTabDTO? {
        guard let sec = activeSection, selectedTabIndex < sec.tabs.count else { return nil }
        return sec.tabs[selectedTabIndex]
    }

    func loadSource(sourceID: String, forceRefresh: Bool = false) {
        loadTask?.cancel()
        guard !sourceID.isEmpty else {
            sections = []
            items = []
            currentError = nil
            return
        }

        let cacheKey = "\(sourceID)_\(selectedSectionIndex)_\(selectedTabIndex)"
        if !forceRefresh, !isInSourceSearching, let cached = sessionCache[cacheKey] {
            sections = cached.sections
            items = cached.items
            nextPageURL = cached.nextURL
            currentError = nil
            return
        }

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
                    if Task.isCancelled { return }
                    items = pageDTO.books
                    currentPage = 1
                    totalPage = pageDTO.totalPage ?? 1
                    nextPageURL = nil
                } else {
                    if sections.isEmpty || forceRefresh {
                        let loadedSections = try await PluginRuntime.shared.discoverSections(sourceID: sourceID)
                        if Task.isCancelled { return }
                        sections = loadedSections
                        selectedSectionIndex = min(selectedSectionIndex, max(0, sections.count - 1))
                        selectedTabIndex = 0
                    }
                    if let tab = activeTab {
                        let pageDTO = try await PluginRuntime.shared.discoverList(sourceID: sourceID, tabURL: tab.url)
                        if Task.isCancelled { return }
                        items = pageDTO.books
                        nextPageURL = pageDTO.nextPageURL
                        sessionCache[cacheKey] = (sections, items, nextPageURL)
                    } else {
                        items = []
                    }
                }
            } catch let pErr as PluginError {
                if !Task.isCancelled { currentError = pErr }
            } catch {
                if !Task.isCancelled { currentError = .network(error.localizedDescription) }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    func loadNextPageIfNeeded(sourceID: String, currentItem: BookRef) {
        guard !isLoading, items.count >= 6 else { return }
        let thresholdIndex = max(0, items.count - 6)
        guard items[thresholdIndex].id == currentItem.id else { return }

        if isInSourceSearching {
            guard currentPage < totalPage else { return }
            let nextPage = currentPage + 1
            Task {
                isLoading = true
                if let dto = try? await PluginRuntime.shared.search(
                    sourceID: sourceID,
                    keyword: inSourceSearchKeyword,
                    page: nextPage
                ) {
                    currentPage = nextPage
                    items.append(contentsOf: dto.books)
                }
                isLoading = false
            }
        } else if let nextURL = nextPageURL, !nextURL.isEmpty {
            Task {
                isLoading = true
                if let dto = try? await PluginRuntime.shared.discoverList(sourceID: sourceID, tabURL: nextURL) {
                    nextPageURL = dto.nextPageURL
                    items.append(contentsOf: dto.books)
                }
                isLoading = false
            }
        }
    }
}

/// 发现页（5.1 节）：源切换器 Menu、网格/列表切换、纯色横向分类胶囊、就地登录/验证弹层与无插件引导
struct DiscoverView: View {
    let onNavigateToImportPlugins: () -> Void
    let onSelectBook: (BookRef) -> Void

    @Query(sort: [SortDescriptor(\PluginRecord.order)]) private var plugins: [PluginRecord]
    @Query(sort: [SortDescriptor(\PluginGroup.order)]) private var groups: [PluginGroup]

    init(
        onNavigateToImportPlugins: @escaping () -> Void,
        onSelectBook: @escaping (BookRef) -> Void
    ) {
        self.onNavigateToImportPlugins = onNavigateToImportPlugins
        self.onSelectBook = onSelectBook
    }
    @State private var viewModel = DiscoverViewModel()
    @State private var settings = AppSettingsStore.shared
    @State private var authSession: WebAuthSessionRequest?
    @State private var showInSourceSearch = false

    private var enabledDiscoverPlugins: [PluginRecord] {
        plugins.filter { $0.isEnabled && $0.discoverable }
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
                    Label("尚未安装听书源", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("导入听书源插件包（.zip 或在线地址）后即可浏览分类与收听有声内容")
                } actions: {
                    Button("去设置导入听书源") {
                        onNavigateToImportPlugins()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if enabledDiscoverPlugins.isEmpty {
                ContentUnavailableView(
                    "暂无可用发现源",
                    systemImage: "eye.slash",
                    description: Text("请在「设置 → 听书源」中启用至少一个支持分类浏览的插件")
                )
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
                viewModel.sections = []
                viewModel.loadSource(sourceID: plugin.id)
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
                ProgressView("正在加载内容…")
                Spacer()
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "暂无内容",
                    systemImage: "book.closed",
                    description: Text("请尝试切换上方分类或下拉刷新")
                )
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

    private func sourceSwitcherMenu(active: PluginRecord) -> some View {
        Menu {
            let pinned = enabledDiscoverPlugins.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("置顶听书源") {
                    ForEach(pinned) { item in
                        Button {
                            settings.currentDiscoverSourceID = item.id
                        } label: {
                            Label(item.name, systemImage: item.id == active.id ? "checkmark" : "pin.fill")
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
                            } label: {
                                if item.id == active.id {
                                    Label(item.name, systemImage: "checkmark")
                                } else {
                                    Text(item.name)
                                }
                            }
                        }
                    }
                }
            }
            let ungrouped = enabledDiscoverPlugins.filter { ($0.groupID == nil || $0.groupID == "") && !$0.isPinned }
            if !ungrouped.isEmpty {
                Section("默认分组") {
                    ForEach(ungrouped) { item in
                        Button {
                            settings.currentDiscoverSourceID = item.id
                        } label: {
                            if item.id == active.id {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(active.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("切换听书源，当前为\(active.name)")
    }

    private var categoryCapsuleBar: some View {
        VStack(spacing: 8) {
            if viewModel.sections.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.sections.indices, id: \.self) { idx in
                            let sec = viewModel.sections[idx]
                            let selected = idx == viewModel.selectedSectionIndex
                            Button {
                                viewModel.selectedSectionIndex = idx
                                viewModel.selectedTabIndex = 0
                                if let id = currentPlugin?.id {
                                    viewModel.loadSource(sourceID: id)
                                }
                            } label: {
                                Text(sec.title)
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

            if let sec = viewModel.activeSection, !sec.tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sec.tabs.indices, id: \.self) { idx in
                            let tab = sec.tabs[idx]
                            let selected = idx == viewModel.selectedTabIndex
                            Button {
                                viewModel.selectedTabIndex = idx
                                if let id = currentPlugin?.id {
                                    viewModel.loadSource(sourceID: id)
                                }
                            } label: {
                                Text(tab.title)
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
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
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
