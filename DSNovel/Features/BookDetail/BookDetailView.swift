import SwiftUI
import SwiftData
import UIKit

struct ChapterSegmentRange: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let startIndex: Int
    let endIndex: Int // inclusive
}

struct IndexedChapterSegment: Identifiable, Equatable {
    var id: String { "\(index)_\(segment.label)" }
    let index: Int
    let segment: ChapterSegmentRange
}

@MainActor
@Observable
final class BookDetailViewModel {
    var activeBook: BookRef
    var alternatives: [BookRef]
    var chapters: [ChapterDTO] = []
    var statusText: String = ""
    var isLoading: Bool = false
    var isLoadingRest: Bool = false
    var errorMessage: String?
    var pluginError: PluginError?
    var isAscending: Bool = true
    var selectedSegmentIndex: Int = 0 // 0 表示当前第 1 段（1-50），-1 表示全部

    init(book: BookRef, alternatives: [BookRef]) {
        self.activeBook = book
        self.alternatives = alternatives
    }

    /// 生成每段 50 章的分段区间
    nonisolated static func buildSegments(totalCount: Int, pageSize: Int = 50) -> [ChapterSegmentRange] {
        guard totalCount > 0 else { return [] }
        var segments: [ChapterSegmentRange] = []
        var start = 0
        while start < totalCount {
            let end = min(totalCount - 1, start + pageSize - 1)
            segments.append(
                ChapterSegmentRange(
                    label: "\(start + 1)–\(end + 1)",
                    startIndex: start,
                    endIndex: end
                )
            )
            start += pageSize
        }
        return segments
    }

    var segments: [ChapterSegmentRange] {
        Self.buildSegments(totalCount: chapters.count)
    }

    var indexedSegments: [IndexedChapterSegment] {
        segments.enumerated().map { IndexedChapterSegment(index: $0.offset, segment: $0.element) }
    }

    var displayedChapters: [ChapterDTO] {
        guard !chapters.isEmpty else { return [] }
        let currentSegments = segments
        let ordered = isAscending ? chapters : chapters.reversed()
        if selectedSegmentIndex == -1 || currentSegments.isEmpty {
            return Array(ordered.prefix(200))
        }
        let clamped = min(max(0, selectedSegmentIndex), currentSegments.count - 1)
        let seg = currentSegments[clamped]
        guard seg.startIndex >= 0, seg.endIndex < chapters.count, seg.startIndex <= seg.endIndex else {
            return Array(ordered.prefix(50))
        }
        let slice = Array(chapters[seg.startIndex...seg.endIndex])
        return isAscending ? slice : slice.reversed()
    }

    func loadBookDetails(forceRefresh: Bool = false) async {
        let bookID = activeBook.id
        let sourceID = activeBook.sourceID
        let bookURL = activeBook.bookURL

        if !forceRefresh, let cached = ChapterCacheStore.loadChapters(for: bookID), !cached.isEmpty {
            chapters = cached
        }
        isLoading = chapters.isEmpty
        isLoadingRest = false
        errorMessage = nil
        pluginError = nil

        if !forceRefresh, !chapters.isEmpty,
           let age = ChapterCacheStore.cacheAge(for: bookID), age < 600 {
            return
        }

        if !forceRefresh, !chapters.isEmpty {
            if let updated = try? await PluginRuntime.shared.updateEpisodes(
                sourceID: sourceID,
                bookURL: bookURL,
                knownChapters: chapters
            ), !updated.chapters.isEmpty {
                applyDetailInfo(updated)
                chapters = updated.chapters
                ChapterCacheStore.saveChapters(updated.chapters, for: bookID)
                isLoading = false
                return
            }
        }

        let isMultiPage = await PluginRuntime.shared.supportsMultipleEpisodePages(sourceID: sourceID)

        if isMultiPage && chapters.isEmpty {
            do {
                let firstPageDetail = try await PluginRuntime.shared.bookDetail(
                    sourceID: sourceID,
                    bookURL: bookURL,
                    loadEpisodes: true,
                    loadFullPages: false
                )
                applyDetailInfo(firstPageDetail)
                if !firstPageDetail.chapters.isEmpty {
                    chapters = firstPageDetail.chapters
                    isLoading = false
                    isLoadingRest = true
                }
            } catch {}
        }

        do {
            let fullDetail = try await PluginRuntime.shared.bookDetail(
                sourceID: sourceID,
                bookURL: bookURL,
                loadEpisodes: true,
                loadFullPages: true
            )
            applyDetailInfo(fullDetail)
            if !fullDetail.chapters.isEmpty {
                chapters = fullDetail.chapters
                ChapterCacheStore.saveChapters(fullDetail.chapters, for: bookID)
                UnplayableBookStore.shared.unmark(bookID)
            } else if chapters.isEmpty {
                errorMessage = "没有获取到章节"
                UnplayableBookStore.shared.mark(bookID)
            }
        } catch let pErr as PluginError {
            if chapters.isEmpty {
                pluginError = pErr
                errorMessage = pErr.localizedDescription
            }
        } catch {
            if chapters.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        isLoadingRest = false
    }

    private func applyDetailInfo(_ detail: BookDetailDTO) {
        if !detail.title.isEmpty { activeBook.title = detail.title }
        if !detail.author.isEmpty { activeBook.author = detail.author }
        if !detail.coverURL.isEmpty { activeBook.cover = detail.coverURL }
        if !detail.intro.isEmpty { activeBook.intro = detail.intro }
        if !detail.status.isEmpty { statusText = detail.status }
    }

    func switchSource(to newBook: BookRef, currentLastChapterIndex: Int?) async {
        let oldBook = activeBook
        var updatedAlts = alternatives.filter { $0.id != newBook.id }
        updatedAlts.append(oldBook)
        activeBook = newBook
        alternatives = updatedAlts
        chapters = []
        selectedSegmentIndex = 0
        await loadBookDetails(forceRefresh: true)
        ToastManager.shared.show("已切换至新书源")
    }
}

/// 书籍详情页（重构版：右上角心形加书架 + 紫色胶囊「继续播放」+ 居中上次收听提示 + 靶心定位/章节搜索/正倒序 + 行级直下按钮与单章听至进度）
struct BookDetailView: View {
    let onJumpToDiscoverSource: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var allBooks: [Book]
    @Query private var plugins: [PluginRecord]
    @Query private var downloads: [DownloadItem]

    @State private var viewModel: BookDetailViewModel
    @State private var isIntroExpanded = false
    @State private var showRangeDownloadSheet = false
    @State private var showSwitchSourceSheet = false
    @State private var showChapterSearch = false
    @State private var chapterSearchKeyword = ""
    @State private var chapterProgressMap: [String: Int] = [:]
    @State private var authSession: WebAuthSessionRequest?

    private var player = PlayerEngine.shared

    init(bookRef: BookRef, alternatives: [BookRef] = [], onJumpToDiscoverSource: @escaping (String) -> Void) {
        _viewModel = State(initialValue: BookDetailViewModel(book: bookRef, alternatives: alternatives))
        self.onJumpToDiscoverSource = onJumpToDiscoverSource
    }

    private var savedBook: Book? {
        allBooks.first(where: { $0.id == viewModel.activeBook.id })
    }

    private var isInShelf: Bool {
        savedBook?.inShelf == true
    }

    private var downloadStateByID: [String: String] {
        var map: [String: String] = [:]
        for item in downloads where item.bookID == viewModel.activeBook.id && item.kind == "manual" {
            map[item.id] = item.state
        }
        return map
    }

    private var currentPlugin: PluginRecord? {
        plugins.first(where: { $0.id == viewModel.activeBook.sourceID })
    }

    private var sourceName: String {
        currentPlugin?.name ?? viewModel.activeBook.sourceID
    }

    private var filteredOrSegmentedChapters: [ChapterDTO] {
        let kw = chapterSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if showChapterSearch && !kw.isEmpty {
            let matches = viewModel.chapters.filter { $0.title.localizedCaseInsensitiveContains(kw) }
            return viewModel.isAscending ? matches : matches.reversed()
        }
        return viewModel.displayedChapters
    }

    var body: some View {
        ScrollViewReader { proxy in
            detailListContent(proxy: proxy)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 右上角心形加书架按钮（对齐参考截图 1）
                Button {
                    toggleShelfMembership()
                } label: {
                    Image(systemName: isInShelf ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isInShelf ? DSColor.primary : .primary)
                }
                .accessibilityLabel(isInShelf ? "已在书架，点击移出" : "加入书架")

                Menu {
                    Button {
                        Task { await viewModel.loadBookDetails(forceRefresh: true) }
                    } label: {
                        Label("刷新章节", systemImage: "arrow.clockwise")
                    }

                    Button {
                        showRangeDownloadSheet = true
                    } label: {
                        Label("区间下载", systemImage: "arrow.down.circle")
                    }

                    Button {
                        showSwitchSourceSheet = true
                    } label: {
                        Label("换源（\(viewModel.alternatives.count)）", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if let plugin = currentPlugin, (!plugin.loginURL.isEmpty || plugin.requiresLogin) {
                        Button {
                            openAuthSheet(initialURL: plugin.loginURL.isEmpty ? plugin.siteURL : plugin.loginURL, isLogin: true) {
                                Task { await viewModel.loadBookDetails(forceRefresh: true) }
                            }
                        } label: {
                            Label("书源网页登录", systemImage: "person.badge.key")
                        }
                    }

                    Button {
                        UIPasteboard.general.string = viewModel.activeBook.bookURL
                        ToastManager.shared.show("已复制书籍源链接")
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("更多操作")
            }
        }
        .task(id: viewModel.activeBook.id) {
            chapterProgressMap = ChapterProgressStore.loadAll(for: viewModel.activeBook.id)
            await viewModel.loadBookDetails()
            syncTotalChaptersToDatabase()
        }
        .onChange(of: viewModel.chapters.count) { _, _ in
            syncTotalChaptersToDatabase()
        }
        .onChange(of: player.currentChapter?.id) { _, _ in
            if player.currentBookID == viewModel.activeBook.id {
                chapterProgressMap = ChapterProgressStore.loadAll(for: viewModel.activeBook.id)
            }
        }
        .onChange(of: player.state) { _, _ in
            if player.currentBookID == viewModel.activeBook.id {
                chapterProgressMap = ChapterProgressStore.loadAll(for: viewModel.activeBook.id)
            }
        }
        .sheet(isPresented: $showRangeDownloadSheet) {
            rangeDownloadSheetView
        }
        .sheet(isPresented: $showSwitchSourceSheet) {
            switchSourceSheetView
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
    }

    private func detailListContent(proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                headerBlock
                playPrimaryBanner
                playbackFailureBanner
                if savedBook?.sourceUnavailable == true {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("当前来源不可用，建议点击右上角「⋯ → 换源」切换来源")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(DSColor.contentBackground)

            Section {
                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("正在加载章节…")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else if let err = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            if let pErr = viewModel.pluginError {
                                switch pErr {
                                case .needLogin(_, let loginURL):
                                    Button("去登录书源账号") {
                                        openAuthSheet(initialURL: loginURL, isLogin: true) {
                                            Task { await viewModel.loadBookDetails(forceRefresh: true) }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                case .needVerify(_, let verifyURL):
                                    Button("去完成安全验证") {
                                        openAuthSheet(initialURL: verifyURL, isLogin: false) {
                                            Task { await viewModel.loadBookDetails(forceRefresh: true) }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                default:
                                    EmptyView()
                                }
                            }
                            Button("重试") {
                                Task { await viewModel.loadBookDetails(forceRefresh: true) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    let states = downloadStateByID
                    ForEach(filteredOrSegmentedChapters) { chapter in
                        chapterRow(for: chapter, downloadStates: states)
                            .id(chapter.id)
                    }
                }
            } header: {
                chapterSectionHeader(proxy: proxy)
            }
        }
        .listStyle(.plain)
        .dsAdaptiveBottomDockScroll()
        .background(DSColor.contentBackground)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CoverImageView(
                    url: viewModel.activeBook.cover,
                    title: viewModel.activeBook.title,
                    width: 96,
                    height: 128,
                    cornerRadius: 8
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(viewModel.activeBook.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if !viewModel.activeBook.author.isEmpty && viewModel.activeBook.author != "未知作者" {
                            Text(viewModel.activeBook.author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !viewModel.statusText.isEmpty {
                            Text(viewModel.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !viewModel.chapters.isEmpty {
                            Text("共 \(viewModel.chapters.count) 章")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        if plugins.contains(where: { $0.id == viewModel.activeBook.sourceID }) {
                            onJumpToDiscoverSource(viewModel.activeBook.sourceID)
                        } else {
                            ToastManager.shared.show("该书源已被移除")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sourceName)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DSColor.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DSColor.primary.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            let cleanIntro = HTMLTokenizer.stripTagsAndDecodeEntities(viewModel.activeBook.intro)
            if !cleanIntro.isEmpty {
                Text(cleanIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(isIntroExpanded ? nil : 3)
                    .onTapGesture {
                        isIntroExpanded.toggle()
                    }
            }
        }
    }

    // 全宽大胶囊「▶ 继续播放 / 开始收听」+ 居中上次听到提示（对齐参考截图 1）
    private var playPrimaryBanner: some View {
        VStack(spacing: 8) {
            Button {
                guard !viewModel.chapters.isEmpty else { return }
                let startChap = viewModel.chapters.first(where: { $0.id == savedBook?.lastChapterID }) ?? viewModel.chapters[0]
                let pos = savedBook?.lastPositionMs ?? 0
                player.startPlayback(
                    book: viewModel.activeBook,
                    chapters: viewModel.chapters,
                    startChapter: startChap,
                    initialPositionMs: pos
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                    Text(savedBook?.lastChapterID != nil ? "继续播放" : "开始收听")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule(style: .continuous)
                        .fill(viewModel.chapters.isEmpty ? Color.gray.opacity(0.4) : DSColor.primary)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.chapters.isEmpty)

            if let record = savedBook, let lastChap = record.lastChapterTitle, !lastChap.isEmpty {
                Text("上次听到：\(lastChap)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var playbackFailureBanner: some View {
        if player.currentBookID == viewModel.activeBook.id,
           case .failed(let msg) = player.state {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                if let pErr = player.lastPluginError {
                    switch pErr {
                    case .needLogin(_, let loginURL):
                        Button("去登录") {
                            openAuthSheet(initialURL: loginURL, isLogin: true) {
                                player.retryCurrentChapter()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                    case .needVerify(_, let verifyURL):
                        Button("去验证") {
                            openAuthSheet(initialURL: verifyURL, isLogin: false) {
                                player.retryCurrentChapter()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                    default:
                        if let jumpTitle = pErr.builtinParserJumpTitle {
                            Button(jumpTitle) {
                                AppRouter.shared.openBuiltinParser(sourceID: viewModel.activeBook.sourceID)
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                        } else {
                            EmptyView()
                        }
                    }
                }
                Button("重试") {
                    player.retryCurrentChapter()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    private func openAuthSheet(initialURL: String, isLogin: Bool, onDone: @escaping () -> Void) {
        let plugin = currentPlugin
        let fallback = plugin?.loginURL.isEmpty == false ? (plugin?.loginURL ?? "") : (plugin?.siteURL ?? viewModel.activeBook.bookURL)
        let targetURL = initialURL.isEmpty ? fallback : initialURL
        authSession = WebAuthSessionRequest(
            sourceID: viewModel.activeBook.sourceID,
            title: "\(isLogin ? "登录" : "安全验证") · \(sourceName)",
            initialURL: targetURL,
            expectedCookieName: nil,
            onCompleted: {
                let isLogged = CookieSync.isSourceLoggedIn(viewModel.activeBook.sourceID)
                if isLogin {
                    plugin?.loggedIn = isLogged
                }
                if (isLogged || !isLogin), plugin?.healthState == .needAuth {
                    plugin?.lastCheckStatus = SourceHealthState.healthy.rawValue
                    plugin?.lastCheckMessage = isLogin ? "已完成登录" : "已完成安全验证"
                }
                try? modelContext.save()
                onDone()
            }
        )
    }

    private func chapterSectionHeader(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("共 \(viewModel.chapters.count) 集")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                if viewModel.isLoadingRest {
                    ProgressView()
                        .controlSize(.mini)
                    Text("加载其余章节…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 靶心定位按钮：一键定位到上次收听章节并滚动
                if savedBook?.lastChapterID != nil {
                    Button {
                        scrollToLastPlayedChapter(proxy: proxy)
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("定位到上次收听章节")
                }

                // 章节搜索过滤按钮
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChapterSearch.toggle()
                        if !showChapterSearch { chapterSearchKeyword = "" }
                    }
                } label: {
                    Image(systemName: showChapterSearch ? "xmark" : "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索章节")

                // 正序/倒序按钮
                Button {
                    viewModel.isAscending.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isAscending ? "切换为倒序" : "切换为正序")
            }

            if showChapterSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索章节名称或集数…", text: $chapterSearchKeyword)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !chapterSearchKeyword.isEmpty {
                        Button {
                            chapterSearchKeyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DSColor.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            let indexedSegs = viewModel.indexedSegments
            if indexedSegs.count > 1 && !(showChapterSearch && !chapterSearchKeyword.trimmingCharacters(in: .whitespaces).isEmpty) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let allActive = viewModel.selectedSegmentIndex == -1
                        Button {
                            viewModel.selectedSegmentIndex = -1
                        } label: {
                            Text("全部")
                                .font(.caption2.weight(allActive ? .semibold : .regular))
                                .foregroundStyle(allActive ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(allActive ? DSColor.primary : DSColor.cardSurface)
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(indexedSegs) { entry in
                            let active = viewModel.selectedSegmentIndex == entry.index
                            Button {
                                viewModel.selectedSegmentIndex = entry.index
                            } label: {
                                Text(entry.segment.label)
                                    .font(.caption2.weight(active ? .semibold : .regular))
                                    .foregroundStyle(active ? .white : .primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(active ? DSColor.primary : DSColor.cardSurface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(DSColor.contentBackground)
    }

    private func chapterRow(for chapter: ChapterDTO, downloadStates: [String: String]) -> some View {
        let isCurrent = player.currentBookID == viewModel.activeBook.id && player.currentChapter?.id == chapter.id
        let itemID = "\(viewModel.activeBook.id)::\(chapter.id)"
        let dlState = downloadStates[itemID]
        let isLastListened = savedBook?.lastChapterID == chapter.id

        // 读取单章收听历史秒数
        let chapterPosMs: Int = {
            if let recorded = chapterProgressMap[chapter.id], recorded > 0 {
                return recorded
            }
            if isLastListened, let rec = savedBook, rec.lastPositionMs > 0 {
                return rec.lastPositionMs
            }
            return 0
        }()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title)
                    .font(.subheadline.weight((isCurrent || isLastListened) ? .semibold : .regular))
                    .foregroundStyle((isCurrent || isLastListened) ? DSColor.primary : .primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if chapterPosMs > 0 {
                        Text("听至 \(ChapterProgressStore.formattedPosition(ms: chapterPosMs))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let dur = chapter.normalizedDurationSec {
                        Text(PlaybackClock.formatSeconds(Double(dur)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            // 行级直下状态按钮（对齐参考截图 1：紫色已下载对勾 / 转圈下载中 / 灰色下载箭头）
            Button {
                if dlState == nil || dlState == "failed" {
                    DownloadManager.shared.enqueueChapters([chapter], for: viewModel.activeBook, kind: "manual")
                    ToastManager.shared.show("已加入下载队列")
                }
            } label: {
                Group {
                    switch dlState {
                    case "completed":
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(DSColor.primary)
                    case "downloading", "queued":
                        ProgressView()
                            .controlSize(.small)
                    default:
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dlState == "completed" ? "已下载" : "下载此章")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            let resumePos = chapterPosMs > 0 ? chapterPosMs : ((savedBook?.lastChapterID == chapter.id) ? (savedBook?.lastPositionMs ?? 0) : 0)
            player.startPlayback(
                book: viewModel.activeBook,
                chapters: viewModel.chapters,
                startChapter: chapter,
                initialPositionMs: resumePos
            )
        }
        .contextMenu {
            Button {
                DownloadManager.shared.enqueueChapters([chapter], for: viewModel.activeBook, kind: "manual")
                ToastManager.shared.show("已加入下载队列")
            } label: {
                Label("下载此章", systemImage: "arrow.down.circle")
            }

            Button {
                if let idx = viewModel.chapters.firstIndex(where: { $0.id == chapter.id }) {
                    let remaining = Array(viewModel.chapters[idx...])
                    DownloadManager.shared.enqueueChapters(remaining, for: viewModel.activeBook, kind: "manual")
                    ToastManager.shared.show("已将后续 \(remaining.count) 章加入下载队列")
                }
            } label: {
                Label("从此章开始下载", systemImage: "arrow.down.to.line")
            }
        }
    }

    private func scrollToLastPlayedChapter(proxy: ScrollViewProxy) {
        guard let lastID = savedBook?.lastChapterID,
              let targetIndex = viewModel.chapters.firstIndex(where: { $0.id == lastID }) else { return }
        showChapterSearch = false
        chapterSearchKeyword = ""
        viewModel.selectedSegmentIndex = targetIndex / 50
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(lastID, anchor: .center)
            }
        }
    }

    private func syncTotalChaptersToDatabase() {
        guard !viewModel.chapters.isEmpty, let existing = savedBook else { return }
        var changed = false
        if existing.totalChapters != viewModel.chapters.count {
            existing.totalChapters = viewModel.chapters.count
            changed = true
        }
        if let lastID = existing.lastChapterID,
           let idx = viewModel.chapters.firstIndex(where: { $0.id == lastID }),
           existing.lastChapterIndex != idx + 1 {
            existing.lastChapterIndex = idx + 1
            changed = true
        }
        if changed {
            try? modelContext.save()
        }
    }

    private var rangeDownloadSheetView: some View {
        NavigationStack {
            List {
                Section("选择要离线下载的章节分段") {
                    Button("下载全部章节（共 \(viewModel.chapters.count) 章）") {
                        DownloadManager.shared.enqueueChapters(viewModel.chapters, for: viewModel.activeBook, kind: "manual")
                        ToastManager.shared.show("已将全部章节加入下载")
                        showRangeDownloadSheet = false
                    }
                    ForEach(viewModel.segments) { seg in
                        Button("下载第 \(seg.label) 章") {
                            if seg.startIndex >= 0, seg.endIndex < viewModel.chapters.count, seg.startIndex <= seg.endIndex {
                                let slice = Array(viewModel.chapters[seg.startIndex...seg.endIndex])
                                DownloadManager.shared.enqueueChapters(slice, for: viewModel.activeBook, kind: "manual")
                                ToastManager.shared.show("已将 \(seg.label) 章加入下载")
                            }
                            showRangeDownloadSheet = false
                        }
                    }
                }
            }
            .navigationTitle("区间下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showRangeDownloadSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var switchSourceSheetView: some View {
        NavigationStack {
            List {
                if viewModel.alternatives.isEmpty {
                    ContentUnavailableView(
                        "暂无其他匹配来源",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("从搜索页聚合结果进入时会自动携带同名可切换来源")
                    )
                } else {
                    ForEach(viewModel.alternatives) { alt in
                        let altSourceName = plugins.first(where: { $0.id == alt.sourceID })?.name ?? alt.sourceID
                        Button {
                            let currentIdx = viewModel.chapters.firstIndex(where: { $0.id == savedBook?.lastChapterID })
                            Task {
                                await viewModel.switchSource(to: alt, currentLastChapterIndex: currentIdx)
                                showSwitchSourceSheet = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(altSourceName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(alt.bookURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("切换书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSwitchSourceSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func toggleShelfMembership() {
        if let existing = savedBook {
            if existing.inShelf {
                if existing.lastPlayedAt != nil {
                    existing.inShelf = false
                    existing.isPinned = false
                    existing.categoryID = nil
                } else {
                    modelContext.delete(existing)
                }
                try? modelContext.save()
                ToastManager.shared.show("已从书架移除")
            } else {
                existing.inShelf = true
                existing.addedAt = .now
                if !viewModel.chapters.isEmpty {
                    existing.totalChapters = viewModel.chapters.count
                }
                try? modelContext.save()
                ToastManager.shared.show("已加入书架")
            }
        } else {
            let newBook = Book(
                id: viewModel.activeBook.id,
                sourceID: viewModel.activeBook.sourceID,
                bookURL: viewModel.activeBook.bookURL,
                title: viewModel.activeBook.title,
                author: viewModel.activeBook.author,
                cover: viewModel.activeBook.cover,
                intro: viewModel.activeBook.intro,
                inShelf: true,
                totalChapters: viewModel.chapters.count
            )
            modelContext.insert(newBook)
            try? modelContext.save()
            ToastManager.shared.show("已加入书架")
        }
    }
}
