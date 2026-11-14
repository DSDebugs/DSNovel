import SwiftUI

struct DiscoverView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player

    let onSwitchToSearch: () -> Void
    let onOpenFullPlayer: () -> Void

    @State private var selectedBookForDetail: BookItem? = nil
    @State private var isCategoryGridExpanded: Bool = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 单层纯净液态玻璃分类导航栏（无需手动切源，后台自动融合喜马拉雅+番茄畅听）
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(UnifiedCategory.all) { category in
                                        GlassPillButton(
                                            title: category.title,
                                            icon: category.icon,
                                            isSelected: engine.activeCategory.id == category.id,
                                            activeColor: .orange,
                                            minHeight: 36
                                        ) {
                                            isCategoryGridExpanded = false
                                            Task {
                                                await engine.loadDiscover(category: category)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            // 展开全部分类四列面板按钮
                            GlassIconButton(
                                systemName: isCategoryGridExpanded ? "chevron.up" : "square.grid.2x2.fill",
                                tint: isCategoryGridExpanded ? .orange : .primary,
                                size: 36
                            ) {
                                withAnimation(.snappy) {
                                    isCategoryGridExpanded.toggle()
                                }
                            }

                            // 快捷跳转全网搜索按钮
                            GlassIconButton(systemName: "magnifyingglass", size: 36) {
                                onSwitchToSearch()
                            }
                        }

                        if isCategoryGridExpanded {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                ForEach(UnifiedCategory.all) { category in
                                    GlassPillButton(
                                        title: category.title,
                                        isSelected: engine.activeCategory.id == category.id,
                                        activeColor: .orange,
                                        minHeight: 34
                                    ) {
                                        withAnimation(.snappy) {
                                            isCategoryGridExpanded = false
                                        }
                                        Task {
                                            await engine.loadDiscover(category: category)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 书城主体内容滚动区（保持 100% 纯净无模糊，120Hz 顺滑滚动）
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 顶部热播推荐横滑卡片（封面顶部自带书源角标）
                        if !engine.discoverBooks.isEmpty {
                            featuredCarouselSection
                        }

                        // 当前频道标题与快捷刷新
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

                        if engine.isDiscoverLoading && engine.discoverBooks.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView("正在同步精选有声书库...")
                                    .padding(.vertical, 44)
                                Spacer()
                            }
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 18) {
                                ForEach(engine.discoverBooks) { book in
                                    StandardBookGridCard(
                                        book: book,
                                        onOpenDetail: {
                                            selectedBookForDetail = book
                                        },
                                        onQuickPlay: {
                                            Task {
                                                await player.quickPlay(book: book)
                                                onOpenFullPlayer()
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 125)
                }
                .refreshable {
                    await engine.loadDiscover(forceRefresh: true)
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

    private var featuredCarouselSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全网热播精选")
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
                                    await player.quickPlay(book: book)
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
}
