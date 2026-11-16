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

    /// 生成每段 50 章的分段区间（5.4 节）
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

        // 1. 先读 LZFSE 压缩缓存立即渲染（5.4 节步骤 1）
        if !forceRefresh, let cached = ChapterCacheStore.loadChapters(for: bookID), !cached.isEmpty {
            chapters = cached
        }
        isLoading = chapters.isEmpty
        isLoadingRest = false
        errorMessage = nil
        pluginError = nil

        // 1.5 缓存足够新鲜（10 分钟内）就直接使用，不再整本重拉：
        // 原实现每次打开详情页都会在后台发起 loadFullPages=true 的全量请求（最长 45 秒），长期占用 JS 上下文，拖慢随后选章播放
        if !forceRefresh, !chapters.isEmpty,
           let age = ChapterCacheStore.cacheAge(for: bookID), age < 600 {
            return
        }

        // 2. 若已有缓存章节且插件支持增量更新 updateEpisodes，优先尝试增量拉取
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

        // 3. 检查源是否声明了 multipleEpisodePages（McpGuide.md 第 6 节：先用 loadFullPages=false 快速取第一页，再用 true 全量加载）
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
            } catch {
                // 首屏快速拉取失败时继续尝试全量拉取
            }
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
                // 书源正常响应但没有任何章节：记为无法播放，今后搜索/发现不再展示
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

/// 书籍详情页（5.4 节）：1–50 章节分段、正序/倒序、区间下载、一键换源、来源跳转及就地登录/验证（已彻底移除书签并严格分离「加入书架」与「最近播放」）
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
    @State private var authSession: WebAuthSessionRequest?

    private var player = PlayerEngine.shared

    init(bookRef: BookRef, alternatives: [BookRef] = [], onJumpToDiscoverSource: @escaping (String) -> Void) {
        _viewModel = State(initialValue: BookDetailViewModel(book: bookRef, alternatives: alternatives))
        self.onJumpToDiscoverSource = onJumpToDiscoverSource
    }

    /// 书籍在数据库中的记录（无论是「书架」还是「最近播放」均共用同一条记录，保存最后播放章节与时间）
    private var savedBook: Book? {
        allBooks.first(where: { $0.id == viewModel.activeBook.id })
    }

    /// 严格判断该书是否由用户主动加入了「书架」
    private var isInShelf: Bool {
        savedBook?.inShelf == true
    }

    /// 已完成下载的条目 ID 集合：每次 body 只算一次（原实现每一行都遍历整个 downloads 数组，O(行数×下载数)）
    private var downloadedItemIDs: Set<String> {
        Set(downloads.lazy.filter { $0.state == "completed" }.map(\.id))
    }

    private var currentPlugin: PluginRecord? {
        plugins.first(where: { $0.id == viewModel.activeBook.sourceID })
    }

    private var sourceName: String {
        currentPlugin?.name ?? viewModel.activeBook.sourceID
    }

    var body: some View {
        detailListContent
            .navigationTitle(viewModel.activeBook.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: viewModel.activeBook.id) {
                await viewModel.loadBookDetails()
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

    private var detailListContent: some View {
        List {
            Section {
                headerBlock
                actionRow
                lastPlayedProgressBanner
                playbackFailureBanner
                if savedBook?.sourceUnavailable == true {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("当前来源不可用，建议点击右上角或「更多 → 换源」切换来源")
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
                    let doneIDs = downloadedItemIDs
                    ForEach(viewModel.displayedChapters) { chapter in
                        chapterRow(for: chapter, downloadedIDs: doneIDs)
                    }
                }
            } header: {
                chapterSectionHeader
            }
        }
        .listStyle(.plain)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.activeBook.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    Text(viewModel.activeBook.author.isEmpty ? "未知作者" : viewModel.activeBook.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        if plugins.contains(where: { $0.id == viewModel.activeBook.sourceID }) {
                            onJumpToDiscoverSource(viewModel.activeBook.sourceID)
                        } else {
                            ToastManager.shared.show("该书源已被移除")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(sourceName)
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DSColor.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DSColor.cardSurface)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if !viewModel.statusText.isEmpty {
                        Text(viewModel.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                guard !viewModel.chapters.isEmpty else { return }
                // 点击开始/继续收听仅记录到「最近播放」（若已在书架则同步更新书架进度），绝不强行把未收藏书籍塞入书架
                let startChap = viewModel.chapters.first(where: { $0.id == savedBook?.lastChapterID }) ?? viewModel.chapters[0]
                let pos = savedBook?.lastPositionMs ?? 0
                player.startPlayback(
                    book: viewModel.activeBook,
                    chapters: viewModel.chapters,
                    startChapter: startChap,
                    initialPositionMs: pos
                )
            } label: {
                Label(
                    savedBook?.lastChapterID != nil ? "继续收听" : "开始收听",
                    systemImage: "play.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.chapters.isEmpty)

            Button {
                toggleShelfMembership()
            } label: {
                Label(
                    isInShelf ? "已在书架" : "加入书架",
                    systemImage: isInShelf ? "checkmark" : "plus"
                )
                .font(.subheadline)
            }
            .buttonStyle(.bordered)

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
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .padding(.horizontal, 6)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.top, 4)
    }

    /// 展示本书最后播放章节、播放进度时间点与最后播放时间
    @ViewBuilder
    private var lastPlayedProgressBanner: some View {
        if let record = savedBook, let lastChap = record.lastChapterTitle, !lastChap.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(DSColor.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上次听到：\(lastChap)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("播放进度 \(record.formattedPositionText) · \(record.formattedLastPlayedAtText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let targetIndex = viewModel.chapters.firstIndex(where: { $0.id == record.lastChapterID }) {
                    Button("定位章节") {
                        let targetSegment = targetIndex / 50
                        viewModel.selectedSegmentIndex = targetSegment
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DSColor.primary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DSColor.cardSurface)
            )
        }
    }

    /// 若当前正在播放本书且遇到登录/验证或网络错误，直接在详情页展示一键「去登录 / 重试」横幅
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
                        EmptyView()
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

    private var chapterSectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("共 \(viewModel.chapters.count) 章")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if viewModel.isLoadingRest {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在加载其余章节…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button {
                    viewModel.isAscending.toggle()
                } label: {
                    Label(
                        viewModel.isAscending ? "正序" : "倒序",
                        systemImage: "arrow.up.arrow.down"
                    )
                    .font(.caption)
                }
            }

            let indexedSegs = viewModel.indexedSegments
            if indexedSegs.count > 1 {
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

    private func chapterRow(for chapter: ChapterDTO, downloadedIDs: Set<String>) -> some View {
        let isCurrent = player.currentBookID == viewModel.activeBook.id && player.currentChapter?.id == chapter.id
        let itemID = "\(viewModel.activeBook.id)::\(chapter.id)"
        let isDownloaded = downloadedIDs.contains(itemID)
        let isLastListened = savedBook?.lastChapterID == chapter.id

        return HStack(spacing: 10) {
            if isCurrent {
                Image(systemName: player.state == .playing ? "waveform" : "speaker.wave.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DSColor.primary)
            } else if isLastListened {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(DSColor.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .font(.subheadline.weight((isCurrent || isLastListened) ? .semibold : .regular))
                    .foregroundStyle((isCurrent || isLastListened) ? DSColor.primary : .primary)
                    .lineLimit(1)

                if isLastListened, let rec = savedBook, rec.lastPositionMs > 0 {
                    Text("上次播至 \(rec.formattedPositionText) · \(rec.formattedLastPlayedAtText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let dur = chapter.normalizedDurationSec {
                Text(PlaybackClock.formatSeconds(Double(dur)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(DSColor.primary)
                    .accessibilityLabel("已下载")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let resumePos = (savedBook?.lastChapterID == chapter.id) ? (savedBook?.lastPositionMs ?? 0) : 0
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

    /// 切换「书架」归属状态：
    /// - 只有点击「加入书架」才会使 `inShelf = true`；
    /// - 点击「已在书架」移除时，若该书有播放历史（`lastPlayedAt != nil`），仅将 `inShelf` 置为 `false` 保留在「最近播放」中。
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
                addedAt: .now,
                skipIntroSec: AppSettingsStore.shared.defaultSkipIntroSec,
                skipOutroSec: AppSettingsStore.shared.defaultSkipOutroSec,
                speed: AppSettingsStore.shared.defaultSpeed
            )
            modelContext.insert(newBook)
            try? modelContext.save()
            ToastManager.shared.show("已加入书架")
        }
    }
}
