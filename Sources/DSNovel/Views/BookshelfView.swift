import SwiftUI

enum ShelfDisplayMode: String, CaseIterable, Identifiable {
    case favorites = "我的书架"
    case recent = "最近收听"

    var id: String { rawValue }
}

struct BookshelfView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerEngine.self) private var player

    let onSwitchTab: (MainTab) -> Void
    let onOpenFullPlayer: () -> Void
    let onOpenPlayerChapters: () -> Void

    @State private var displayMode: ShelfDisplayMode = .favorites
    @State private var isGridMode: Bool = true
    @State private var selectedBookForDetail: BookItem? = nil

    private var activeEntries: [BookshelfEntry] {
        switch displayMode {
        case .favorites: return library.favoriteEntries
        case .recent: return library.recentEntries
        }
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 单层极简液态玻璃顶栏（无冗余书源区分按钮，直达核心视图切换）
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(ShelfDisplayMode.allCases) { mode in
                            GlassPillButton(
                                title: mode.rawValue,
                                icon: mode == .favorites ? "books.vertical.fill" : "clock.fill",
                                isSelected: displayMode == mode,
                                activeColor: .orange,
                                minHeight: 36
                            ) {
                                withAnimation(.snappy) {
                                    displayMode = mode
                                }
                            }
                        }

                        Spacer()

                        GlassIconButton(systemName: "magnifyingglass", size: 36) {
                            onSwitchTab(.search)
                        }

                        GlassIconButton(systemName: isGridMode ? "list.bullet" : "square.grid.3x3.fill", size: 36) {
                            withAnimation(.snappy) {
                                isGridMode.toggle()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 书架主体滚动区（保持 100% 纯净无模糊）
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 顶部“继续收听”英雄衔接卡片（打开 App 一键续播上次进度）
                        if let recent = library.mostRecentEntry {
                            continueListeningCard(entry: recent)
                                .padding(.horizontal, 16)
                        }

                        if activeEntries.isEmpty {
                            emptyShelfCard
                                .padding(.top, 28)
                                .padding(.horizontal, 16)
                        } else if isGridMode {
                            LazyVGrid(columns: gridColumns, spacing: 18) {
                                ForEach(activeEntries) { entry in
                                    StandardBookGridCard(
                                        book: entry.book,
                                        progressBadge: "第\(entry.lastEpisodeIndex + 1)集",
                                        onOpenDetail: {
                                            selectedBookForDetail = entry.book
                                        },
                                        onQuickPlay: {
                                            Task {
                                                await player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                                                onOpenFullPlayer()
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(activeEntries) { entry in
                                    CleanBookRow(
                                        book: entry.book,
                                        subtitleOverride: "听到：\(entry.lastEpisodeTitle) · \(entry.formattedProgressTime)",
                                        onOpenDetail: {
                                            selectedBookForDetail = entry.book
                                        },
                                        onQuickPlay: {
                                            Task {
                                                await player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
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
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedBookForDetail) { book in
                BookDetailView(book: book, onOpenFullPlayer: onOpenFullPlayer)
            }
        }
    }

    private func continueListeningCard(entry: BookshelfEntry) -> some View {
        HStack(spacing: 14) {
            Button {
                selectedBookForDetail = entry.book
            } label: {
                HStack(spacing: 12) {
                    BookCoverView(
                        urlString: entry.book.coverURL,
                        title: entry.book.title,
                        source: entry.book.source,
                        width: 64,
                        height: 86,
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.orange)
                            Text("上次收听 · 一键续播")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.orange)
                        }

                        Text(entry.book.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(entry.lastEpisodeTitle) · \(entry.formattedProgressTime)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePressButtonStyle())

            GlassPillButton(
                title: "续播",
                icon: "play.fill",
                isSelected: true,
                activeColor: .orange,
                minHeight: 38
            ) {
                Task {
                    await player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                    onOpenFullPlayer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.9)
                )
        )
    }

    private var emptyShelfCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)

            Text("书架暂无藏书")
                .font(.system(size: 17, weight: .bold))

            Text("去书城或搜索页探索全网有声小说，封面上方自动标注来源，全集目录秒级加载")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                GlassPillButton(title: "逛逛书城", icon: "sparkles.rectangle.stack.fill", isSelected: true, activeColor: .orange, minHeight: 40) {
                    onSwitchTab(.discover)
                }

                GlassPillButton(title: "导入精选热书", icon: "plus.circle.fill", isSelected: false, minHeight: 40) {
                    library.seedStarterShelf()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15))
        )
    }
}
