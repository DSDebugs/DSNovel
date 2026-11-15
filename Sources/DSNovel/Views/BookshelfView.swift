import SwiftUI

enum ShelfSegmentMode: String, CaseIterable, Identifiable {
    case myShelf = "我的书籍"
    case recentRecord = "最近收听"

    var id: String { rawValue }
}

struct BookshelfView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerEngine.self) private var player

    let onSwitchTab: (MainTab) -> Void
    let onOpenFullPlayer: () -> Void

    @State private var segment: ShelfSegmentMode = .myShelf
    @State private var isGridMode: Bool = false
    @State private var isManageMode: Bool = false
    @State private var selectedBookForDetail: BookItem? = nil

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部液态玻璃控制栏：严格分离“我的书籍（仅主动加入书架）”与“最近收听（历史记录）”
                AppGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(ShelfSegmentMode.allCases) { mode in
                            let count = (mode == .myShelf) ? library.shelfBooks.count : library.recentHistory.count
                            GlassPillButton(
                                title: "\(mode.rawValue) (\(count))",
                                icon: mode == .myShelf ? "books.vertical.fill" : "clock.arrow.circlepath",
                                isSelected: segment == mode,
                                activeColor: .orange,
                                minHeight: 36
                            ) {
                                withAnimation(.snappy) {
                                    segment = mode
                                }
                            }
                        }

                        Spacer()

                        if segment == .myShelf && !library.shelfBooks.isEmpty {
                            GlassPillButton(
                                title: isManageMode ? "完成" : "管理",
                                icon: isManageMode ? "checkmark" : "trash",
                                isSelected: isManageMode,
                                activeColor: .red,
                                minHeight: 34
                            ) {
                                withAnimation(.snappy) {
                                    isManageMode.toggle()
                                }
                            }
                        } else if segment == .recentRecord && !library.recentHistory.isEmpty {
                            GlassPillButton(
                                title: "清空记录",
                                icon: "trash",
                                isSelected: false,
                                minHeight: 34
                            ) {
                                library.clearRecentHistory()
                            }
                        }

                        GlassIconButton(systemName: isGridMode ? "list.bullet" : "square.grid.3x3.fill", size: 36) {
                            withAnimation(.snappy) {
                                isGridMode.toggle()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .appGlassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 主体内容区（纯净滚动区）
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch segment {
                        case .myShelf:
                            myShelfSection
                        case .recentRecord:
                            recentRecordSection
                        }
                    }
                    .padding(.top, 14)
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

    // MARK: - 1. 我的书籍（仅展示主动加入书架的藏书，含最新收听章节与时间记录及删除功能）
    @ViewBuilder
    private var myShelfSection: some View {
        if library.shelfBooks.isEmpty {
            emptyStateCard(
                icon: "books.vertical.circle.fill",
                title: "我的书架暂无书籍",
                subtitle: "只有你在书籍详情页或播放页面点击“加入书架”的书籍才会在此展示；收听历史可在上方“最近收听”查看。"
            )
            .padding(.horizontal, 16)
            .padding(.top, 30)
        } else if isGridMode {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(library.shelfBooks) { entry in
                    StandardBookGridCard(
                        book: entry.book,
                        progressBadge: "第\(entry.lastEpisodeIndex + 1)集",
                        recordText: "\(entry.lastEpisodeTitle)\n\(entry.formattedDateRecord)",
                        onDelete: {
                            library.removeFromBookshelf(entry.book.id)
                        },
                        onOpenDetail: {
                            selectedBookForDetail = entry.book
                        },
                        onQuickPlay: {
                            Task {
                                player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                                onOpenFullPlayer()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(library.shelfBooks) { entry in
                    CleanBookRow(
                        book: entry.book,
                        subtitleOverride: "最新收听：\(entry.lastEpisodeTitle)（进度 \(entry.formattedProgressTime)）",
                        timeRecordOverride: "记录时间：\(entry.formattedDateRecord)",
                        onDelete: {
                            library.removeFromBookshelf(entry.book.id)
                        },
                        onOpenDetail: {
                            selectedBookForDetail = entry.book
                        },
                        onQuickPlay: {
                            Task {
                                player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                                onOpenFullPlayer()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 2. 最近收听（纯历史记录，与我的书籍严格分离）
    @ViewBuilder
    private var recentRecordSection: some View {
        if library.recentHistory.isEmpty {
            emptyStateCard(
                icon: "clock.badge.checkmark.fill",
                title: "暂无最近收听记录",
                subtitle: "你在书城播放过的任何有声书都会在此自动记录最新收听章节与时间，方便随时回溯续听。"
            )
            .padding(.horizontal, 16)
            .padding(.top, 30)
        } else if isGridMode {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(library.recentHistory) { entry in
                    StandardBookGridCard(
                        book: entry.book,
                        progressBadge: "第\(entry.lastEpisodeIndex + 1)集",
                        recordText: "\(entry.lastEpisodeTitle)\n\(entry.formattedDateRecord)",
                        onDelete: {
                            library.removeFromRecentHistory(entry.book.id)
                        },
                        onOpenDetail: {
                            selectedBookForDetail = entry.book
                        },
                        onQuickPlay: {
                            Task {
                                player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                                onOpenFullPlayer()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(library.recentHistory) { entry in
                    CleanBookRow(
                        book: entry.book,
                        subtitleOverride: "听到章节：\(entry.lastEpisodeTitle)（进度 \(entry.formattedProgressTime)）",
                        timeRecordOverride: "收听时间：\(entry.formattedDateRecord)",
                        onDelete: {
                            library.removeFromRecentHistory(entry.book.id)
                        },
                        onOpenDetail: {
                            selectedBookForDetail = entry.book
                        },
                        onQuickPlay: {
                            Task {
                                player.quickPlay(book: entry.book, startEpisodeIndex: entry.lastEpisodeIndex)
                                onOpenFullPlayer()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func emptyStateCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text(title)
                .font(.system(size: 17, weight: .bold))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GlassPillButton(
                title: "前往书城探索",
                icon: "sparkles.rectangle.stack.fill",
                isSelected: true,
                activeColor: .orange,
                minHeight: 40
            ) {
                onSwitchTab(.discover)
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
