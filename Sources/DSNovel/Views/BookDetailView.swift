import SwiftUI

struct BookDetailView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    @State var book: BookItem
    let onOpenFullPlayer: () -> Void

    @State private var episodes: [EpisodeItem] = []
    @State private var isDirectoryIncomplete: Bool = false
    @State private var isLoadingEpisodes: Bool = true
    @State private var isAscending: Bool = true
    @State private var selectedPageSlice: Int = 0

    private let sliceSize: Int = 100

    private var totalSlices: Int {
        max(1, Int(ceil(Double(episodes.count) / Double(sliceSize))))
    }

    private var displayedEpisodes: [EpisodeItem] {
        guard !episodes.isEmpty else { return [] }
        let ordered = isAscending ? episodes : episodes.reversed()
        let start = min(selectedPageSlice * sliceSize, max(0, ordered.count - 1))
        let end = min(start + sliceSize, ordered.count)
        guard start < end else { return Array(ordered.prefix(sliceSize)) }
        return Array(ordered[start..<end])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. 书籍概览卡片（来源标注于封面上方角标，界面清爽统一）
                bookHeroCard

                // 2. 全量章节目录控制栏（自动定位上次收听所在的百集区间）
                directoryControlPanel

                // 3. 章节列表（ScrollView + LazyVStack，点击任一集即刻播放并衔接展开播放器）
                if isLoadingEpisodes {
                    HStack {
                        Spacer()
                        ProgressView("正在一次性并发拉取全部可用章节目录...")
                            .padding(.vertical, 40)
                        Spacer()
                    }
                } else if episodes.isEmpty {
                    VStack(spacing: 12) {
                        Text("正在尝试从备用线路同步章节...")
                            .font(.system(size: 14, weight: .semibold))
                        GlassPillButton(title: "重新加载目录", icon: "arrow.clockwise", isSelected: true, activeColor: .orange, minHeight: 40) {
                            Task { await loadAllChapters(force: true) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedEpisodes) { ep in
                            let isCurrent = (player.currentBook?.id == book.id && player.currentEpisode?.id == ep.id)
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                let realIndex = max(0, ep.index - 1)
                                Task {
                                    player.startPlayback(book: book, episodes: episodes, index: realIndex)
                                    onOpenFullPlayer()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(ep.index)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(isCurrent ? .orange : .secondary)
                                        .frame(width: 36, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(ep.displayTitle)
                                            .font(.system(size: 14, weight: isCurrent ? .bold : .medium))
                                            .foregroundStyle(isCurrent ? .orange : .primary)
                                            .lineLimit(1)

                                        HStack(spacing: 8) {
                                            Text(ep.isFree ? "免费畅听" : "VIP/试听")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(ep.isFree ? .green : .orange)
                                            Text(ep.formattedDuration)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: isCurrent && player.isPlaying ? "waveform" : "play.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(isCurrent ? .orange : Color.white.opacity(0.35))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(minHeight: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(isCurrent ? Color.orange.opacity(0.16) : Color(red: 0.11, green: 0.12, blue: 0.15))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ResponsivePressButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 130)
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            await loadAllChapters(force: false)
        }
    }

    private var bookHeroCard: some View {
        AppGlassContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    BookCoverView(
                        bookId: book.id,
                        urlString: book.coverURL,
                        title: book.title,
                        source: book.source,
                        width: 98,
                        height: 134,
                        cornerRadius: 12
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Text("演播 / 作者：\(book.author)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(episodes.isEmpty ? book.statusText : "已加载全量目录 · 共 \(episodes.count) 集")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)

                        Text(book.intro)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                // 核心双按钮（立即播放/续播 + 加入书架），界面干净直观
                HStack(spacing: 12) {
                    let saved = library.entry(for: book.id)
                    GlassPillButton(
                        title: saved != nil ? "续播第\((saved?.lastEpisodeIndex ?? 0) + 1)集" : "立即播放",
                        icon: "play.fill",
                        isSelected: true,
                        activeColor: .orange,
                        minHeight: 44
                    ) {
                        Task {
                            if !episodes.isEmpty {
                                let idx = min(saved?.lastEpisodeIndex ?? 0, episodes.count - 1)
                                player.startPlayback(book: book, episodes: episodes, index: idx, resumeTime: saved?.lastPlaybackTime ?? 0)
                            } else {
                                player.quickPlay(book: book)
                            }
                            onOpenFullPlayer()
                        }
                    }

                    let inShelf = library.isInBookshelf(book.id)
                    GlassPillButton(
                        title: inShelf ? "已在书架" : "加入书架",
                        icon: inShelf ? "checkmark.circle.fill" : "plus.circle.fill",
                        isSelected: inShelf,
                        activeColor: .green,
                        minHeight: 44
                    ) {
                        library.toggleBookshelf(book)
                    }
                }
            }
            .padding(16)
            .appGlassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }

    private var directoryControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部章节 (\(episodes.count)集)")
                    .font(.system(size: 15, weight: .bold))

                Spacer()

                GlassPillButton(
                    title: isAscending ? "正序" : "倒序",
                    icon: "arrow.up.arrow.down",
                    isSelected: false,
                    minHeight: 32
                ) {
                    isAscending.toggle()
                    selectedPageSlice = 0
                }

                GlassPillButton(
                    title: "刷新",
                    icon: "arrow.clockwise",
                    isSelected: false,
                    minHeight: 32
                ) {
                    Task { await loadAllChapters(force: true) }
                }
            }

            if totalSlices > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<totalSlices, id: \.self) { slice in
                            let startNum = slice * sliceSize + 1
                            let endNum = min((slice + 1) * sliceSize, episodes.count)
                            GlassPillButton(
                                title: "\(startNum)-\(endNum)集",
                                isSelected: selectedPageSlice == slice,
                                activeColor: .orange,
                                minHeight: 32
                            ) {
                                selectedPageSlice = slice
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadAllChapters(force: Bool) async {
        isLoadingEpisodes = true
        let result = await engine.fetchAllBookEpisodes(for: book, forceRefresh: force)
        episodes = result.episodes
        isDirectoryIncomplete = !result.isComplete
        if let saved = library.entry(for: book.id), !episodes.isEmpty {
            selectedPageSlice = min(max(0, saved.lastEpisodeIndex / sliceSize), max(0, totalSlices - 1))
        }
        isLoadingEpisodes = false
    }
}
