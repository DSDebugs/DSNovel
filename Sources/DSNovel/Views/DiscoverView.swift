import SwiftUI

struct DiscoverView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    let onOpenFullPlayer: () -> Void

    @State private var searchQuery: String = ""
    @State private var isSearchActive: Bool = false
    @State private var selectedBookForDetail: BookItem? = nil

    private let hotKeywords = [
        "凡人修仙传", "剑来", "庆余年", "盗墓笔记",
        "雪中悍刀行", "诡秘之主", "大奉打更人", "遮天",
        "三体", "明朝那些事儿", "郭德纲相声", "单田芳评书"
    ]

    private let categoryGridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
    private let bookGridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 书城顶部一体化液态玻璃控制舱（上方搜索栏 + 下方 2行×6列 全景分类矩阵）
                AppGlassContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        // 第一层：集成式全网搜索栏
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.orange)

                                TextField("搜书名、主角、主播（回车或点右侧搜索）", text: $searchQuery)
                                    .font(.system(size: 14))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.search)
                                    .onSubmit {
                                        triggerSearch(searchQuery)
                                    }

                                if !searchQuery.isEmpty || isSearchActive {
                                    Button {
                                        exitSearchMode()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ResponsivePressButtonStyle())
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 4)
                            .frame(height: 38)
                            .background(Capsule().fill(Color.white.opacity(0.09)))

                            if isSearchActive && searchQuery.isEmpty {
                                GlassPillButton(title: "返回书城", isSelected: false, minHeight: 38) {
                                    exitSearchMode()
                                }
                            } else {
                                GlassPillButton(
                                    title: "搜索",
                                    icon: "sparkle.magnifyingglass",
                                    isSelected: true,
                                    activeColor: .orange,
                                    minHeight: 38
                                ) {
                                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        withAnimation(.snappy) {
                                            isSearchActive.toggle()
                                        }
                                    } else {
                                        triggerSearch(searchQuery)
                                    }
                                }
                            }
                        }

                        // 第二层：当未处于搜索结果页时，直接展示美观整齐的 2行×6列 全景分类矩阵（无需左右滑动找分类）
                        if !isSearchActive {
                            LazyVGrid(columns: categoryGridColumns, spacing: 7) {
                                ForEach(UnifiedCategory.all) { category in
                                    let isSelected = (engine.activeCategory.id == category.id)
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        Task {
                                            await engine.loadDiscover(category: category)
                                        }
                                    } label: {
                                        Text(category.shortTitle)
                                            .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.88))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 30)
                                            .background(
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(isSelected ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.white.opacity(0.07)))
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ResponsivePressButtonStyle())
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .appGlassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 主体内容滚动区（保持 100% 纯净无模糊）
                ScrollView {
                    if isSearchActive {
                        searchContentArea
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 125)
                    } else {
                        bookstoreContentArea
                            .padding(.top, 12)
                            .padding(.bottom, 125)
                    }
                }
                .refreshable {
                    if !isSearchActive {
                        await engine.loadDiscover(forceRefresh: true)
                    }
                }
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedBookForDetail) { book in
                BookDetailView(book: book, onOpenFullPlayer: onOpenFullPlayer)
            }
            .task {
                if engine.discoverBooks.isEmpty {
                    await engine.loadDiscover()
                }
            }
        }
    }

    // MARK: - 书城精选浏览区
    private var bookstoreContentArea: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !engine.discoverBooks.isEmpty {
                featuredCarouselSection
            }

            HStack {
                Label(engine.activeCategory.title, systemImage: engine.activeCategory.icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                GlassPillButton(title: "换一批", icon: "arrow.clockwise", isSelected: false, minHeight: 30) {
                    Task {
                        await engine.loadDiscover(forceRefresh: true)
                    }
                }
            }
            .padding(.horizontal, 16)

            if let err = engine.discoverError, engine.discoverBooks.isEmpty {
                VStack(spacing: 12) {
                    Text(err).font(.system(size: 13)).foregroundStyle(.orange)
                    GlassPillButton(title: "重试", icon: "arrow.clockwise", isSelected: true, activeColor: .orange, minHeight: 36) {
                        Task { await engine.loadDiscover(forceRefresh: true) }
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 44)
            } else if engine.isDiscoverLoading && engine.discoverBooks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在同步精选有声书库...")
                        .padding(.vertical, 44)
                    Spacer()
                }
            } else {
                LazyVGrid(columns: bookGridColumns, spacing: 18) {
                    ForEach(engine.discoverBooks) { book in
                        StandardBookGridCard(
                            book: book,
                            onOpenDetail: {
                                selectedBookForDetail = book
                            },
                            onQuickPlay: {
                                Task {
                                    player.quickPlay(book: book)
                                    onOpenFullPlayer()
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 内嵌搜索结果与热搜面板
    private var searchContentArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.isSearching {
                HStack {
                    Spacer()
                    ProgressView("正在全网检索并聚合可用章节...")
                        .padding(.vertical, 48)
                    Spacer()
                }
            } else if !engine.searchResults.isEmpty {
                HStack {
                    Text("找到 \(engine.searchResults.count) 部匹配有声书")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                    Spacer()
                    GlassPillButton(title: "返回书城分类", icon: "chevron.left", isSelected: false, minHeight: 30) {
                        exitSearchMode()
                    }
                }

                LazyVStack(spacing: 12) {
                    ForEach(engine.searchResults) { book in
                        CleanBookRow(
                            book: book,
                            onOpenDetail: {
                                selectedBookForDetail = book
                            },
                            onQuickPlay: {
                                Task {
                                    player.quickPlay(book: book)
                                    onOpenFullPlayer()
                                }
                            }
                        )
                    }
                }
            } else {
                if let err = engine.searchError {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("全网热搜有声书（点击即搜）", systemImage: "flame.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.orange)
                        Spacer()
                        GlassPillButton(title: "返回书城", isSelected: false, minHeight: 28) {
                            exitSearchMode()
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(hotKeywords, id: \.self) { word in
                            GlassPillButton(title: word, isSelected: false, minHeight: 34) {
                                searchQuery = word
                                triggerSearch(word)
                            }
                        }
                    }
                }

                if !library.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("搜索历史", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            GlassPillButton(title: "清空历史", icon: "trash", isSelected: false, minHeight: 28) {
                                library.clearSearchHistory()
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                            ForEach(library.searchHistory, id: \.self) { word in
                                GlassPillButton(title: word, isSelected: false, minHeight: 34) {
                                    searchQuery = word
                                    triggerSearch(word)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var featuredCarouselSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日必听热播榜")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("封面上方标注来源 · 点击即听")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(engine.discoverBooks.prefix(6))) { book in
                        HStack(spacing: 12) {
                            Button {
                                selectedBookForDetail = book
                            } label: {
                                HStack(spacing: 12) {
                                    BookCoverView(
                                        bookId: book.id,
                                        urlString: book.coverURL,
                                        title: book.title,
                                        source: book.source,
                                        width: 66,
                                        height: 88,
                                        cornerRadius: 10
                                    )

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(book.title)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(book.author)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Text(book.statusText)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 136, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ResponsivePressButtonStyle())

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                Task {
                                    player.quickPlay(book: book)
                                    onOpenFullPlayer()
                                }
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(book.source.brandColor)
                                    .frame(width: 40, height: 40)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(ResponsivePressButtonStyle())
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(red: 0.11, green: 0.12, blue: 0.16))
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func triggerSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearchActive = true
        guard !trimmed.isEmpty else { return }
        library.recordSearch(trimmed)
        Task {
            await engine.performSearch(keyword: trimmed)
        }
    }

    private func exitSearchMode() {
        searchQuery = ""
        engine.clearSearchResults()
        withAnimation(.snappy) {
            isSearchActive = false
        }
    }
}
