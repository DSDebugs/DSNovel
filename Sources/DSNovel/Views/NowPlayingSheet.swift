import SwiftUI

enum PlayerCenterStageMode: String, CaseIterable, Identifiable {
    case artwork = "封面"
    case chapters = "目录"
    case bookmarks = "书签"

    var id: String { rawValue }
}

struct NowPlayingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    var initialCenterMode: PlayerCenterStageMode = .artwork

    @State private var centerMode: PlayerCenterStageMode = .artwork
    @State private var isAscending: Bool = true
    @State private var selectedSlice: Int = 0
    @State private var bookmarkAddedToast: Bool = false

    private let sliceSize = 100

    private var totalSlices: Int {
        max(1, Int(ceil(Double(player.episodes.count) / Double(sliceSize))))
    }

    private var currentSliceEpisodes: [EpisodeItem] {
        guard !player.episodes.isEmpty else { return [] }
        let ordered = isAscending ? player.episodes : player.episodes.reversed()
        let start = min(selectedSlice * sliceSize, max(0, ordered.count - 1))
        let end = min(start + sliceSize, ordered.count)
        guard start < end else { return Array(ordered.prefix(sliceSize)) }
        return Array(ordered[start..<end])
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    (player.currentBook?.source.brandColor ?? .orange).opacity(0.28),
                    Color(red: 0.05, green: 0.06, blue: 0.09),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                // 1. 顶部栏（收起 + 封面/目录/书签三段切换 + 一键换源 + 收藏书架）
                topHeaderBar

                // 2. 中央舞台区（封面模式 / 全量章节目录模式 / 书签管理模式）
                Group {
                    switch centerMode {
                    case .artwork:
                        artworkStageView
                    case .chapters:
                        chaptersStageView
                    case .bookmarks:
                        bookmarksStageView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 3. 底部液态玻璃播放控制舱（进度条 + 五键主控 + 四键功能坞）
                bottomControlDock
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .onAppear {
            centerMode = initialCenterMode
            selectedSlice = player.currentEpisodeIndex / sliceSize
        }
    }

    // MARK: - 顶部控制栏
    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemName: "chevron.down", size: 38) {
                dismiss()
            }

            Spacer()

            // 三段模式切换胶囊
            HStack(spacing: 6) {
                ForEach(PlayerCenterStageMode.allCases) { mode in
                    GlassPillButton(
                        title: modeTitle(mode),
                        isSelected: centerMode == mode,
                        activeColor: .orange,
                        minHeight: 34
                    ) {
                        withAnimation(.snappy) {
                            centerMode = mode
                        }
                    }
                }
            }

            Spacer()



            // 书架收藏按钮
            if let book = player.currentBook {
                let inShelf = library.isInBookshelf(book.id)
                GlassIconButton(
                    systemName: inShelf ? "bookmark.fill" : "bookmark",
                    tint: inShelf ? .green : .primary,
                    size: 38
                ) {
                    library.toggleBookshelf(book)
                }
            }
        }
    }

    private func modeTitle(_ mode: PlayerCenterStageMode) -> String {
        switch mode {
        case .artwork: return "封面"
        case .chapters: return "目录(\(player.episodes.count))"
        case .bookmarks:
            let count = library.bookmarks(for: player.currentBook?.id ?? "").count
            return count > 0 ? "书签(\(count))" : "书签"
        }
    }

    // MARK: - 舞台1：封面模式
    private var artworkStageView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)

            if let book = player.currentBook {
                BookCoverView(
                    urlString: book.coverURL,
                    title: book.title,
                    source: book.source,
                    width: 220,
                    height: 290,
                    cornerRadius: 22
                )
                .shadow(color: .black.opacity(0.55), radius: 20, y: 10)

                VStack(spacing: 8) {
                    Text(player.currentEpisode?.displayTitle ?? book.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text("\(book.title) · \(book.author)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(player.statusBanner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }

                if let err = player.errorMessage {
                    HStack(spacing: 10) {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(2)

                        GlassPillButton(title: "一键换源播放", icon: "arrow.triangle.2.circlepath", isSelected: true, activeColor: .orange, minHeight: 34) {
                            Task { await player.switchSourceForCurrentBook() }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                }
            }

            Spacer(minLength: 4)
        }
    }

    // MARK: - 舞台2：全量章节目录模式（ScrollView + LazyVStack，秒切分页）
    private var chaptersStageView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("共 \(player.episodes.count) 集（已全量加载）")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                GlassPillButton(title: isAscending ? "正序" : "倒序", icon: "arrow.up.arrow.down", isSelected: false, minHeight: 32) {
                    isAscending.toggle()
                    selectedSlice = 0
                }
            }

            if totalSlices > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<totalSlices, id: \.self) { slice in
                            let startNum = slice * sliceSize + 1
                            let endNum = min((slice + 1) * sliceSize, player.episodes.count)
                            GlassPillButton(
                                title: "\(startNum)-\(endNum)集",
                                isSelected: selectedSlice == slice,
                                activeColor: .orange,
                                minHeight: 30
                            ) {
                                selectedSlice = slice
                            }
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(currentSliceEpisodes) { ep in
                        let isCurrent = (player.currentEpisode?.id == ep.id)
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if let book = player.currentBook {
                                Task {
                                    await player.startPlayback(book: book, episodes: player.episodes, index: max(0, ep.index - 1))
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(ep.index)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(isCurrent ? .orange : .secondary)
                                    .frame(width: 34, alignment: .leading)

                                Text(ep.displayTitle)
                                    .font(.system(size: 14, weight: isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? .orange : .white)
                                    .lineLimit(1)

                                Spacer()

                                if isCurrent {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frame(minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isCurrent ? Color.orange.opacity(0.20) : Color.white.opacity(0.07))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ResponsivePressButtonStyle())
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 舞台3：书签管理模式（添加时间点书签 + 点击书签秒跳进度）
    private var bookmarksStageView: some View {
        let bookId = player.currentBook?.id ?? ""
        let list = library.bookmarks(for: bookId)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收听书签 (\(list.count))")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                GlassPillButton(title: "添加当前书签", icon: "plus.circle.fill", isSelected: true, activeColor: .orange, minHeight: 34) {
                    addCurrentBookmark()
                }
            }

            if list.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("暂无书签，点击右上角或底部“书签”即可记录当前收听时间点")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list) { bm in
                            HStack(spacing: 12) {
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    if let book = player.currentBook {
                                        Task {
                                            await player.startPlayback(book: book, episodes: player.episodes, index: bm.episodeIndex, resumeTime: bm.timestamp)
                                            centerMode = .artwork
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(bm.episodeTitle)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text("时间点：\(bm.formattedTimestamp)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.orange)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(ResponsivePressButtonStyle())

                                GlassIconButton(systemName: "trash", tint: .red, size: 34) {
                                    library.removeBookmark(bm.id)
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底部液态玻璃控制舱
    private var bottomControlDock: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                // 进度条
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .tint(.orange)

                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        if bookmarkAddedToast {
                            Text("已添加书签")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(formatTime(max(0, player.duration - player.currentTime)))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                // 五键主控区（后退15秒、上一集、播放/暂停、下一集、前进15秒）
                HStack(spacing: 22) {
                    GlassIconButton(systemName: "gobackward.15", size: 42) {
                        player.skip(by: -15)
                    }

                    GlassIconButton(systemName: "backward.end.fill", size: 44) {
                        player.playPreviousEpisode()
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.orange.gradient))
                            .shadow(color: .orange.opacity(0.45), radius: 10, y: 4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())

                    GlassIconButton(systemName: "forward.end.fill", size: 44) {
                        player.playNextEpisode()
                    }

                    GlassIconButton(systemName: "goforward.15", size: 42) {
                        player.skip(by: 15)
                    }
                }

                // 四键功能坞（倍速、睡眠定时、添加/查看书签、展开目录）
                HStack(spacing: 10) {
                    GlassPillButton(
                        title: String(format: "%.2gx", player.playbackRate),
                        icon: "speedometer",
                        isSelected: player.playbackRate != 1.0,
                        activeColor: .orange,
                        minHeight: 38
                    ) {
                        player.cyclePlaybackRate()
                    }

                    GlassPillButton(
                        title: sleepTimerLabel,
                        icon: "moon.zzz.fill",
                        isSelected: player.sleepTimerRemainingSeconds != nil,
                        activeColor: .indigo,
                        minHeight: 38
                    ) {
                        player.cycleSleepTimer()
                    }

                    GlassPillButton(
                        title: "书签",
                        icon: "bookmark.fill",
                        isSelected: centerMode == .bookmarks,
                        activeColor: .orange,
                        minHeight: 38
                    ) {
                        addCurrentBookmark()
                        withAnimation(.snappy) {
                            centerMode = .bookmarks
                        }
                    }

                    GlassPillButton(
                        title: "目录",
                        icon: "list.bullet",
                        isSelected: centerMode == .chapters,
                        activeColor: .orange,
                        minHeight: 38
                    ) {
                        withAnimation(.snappy) {
                            centerMode = (centerMode == .chapters) ? .artwork : .chapters
                        }
                    }
                }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private var sleepTimerLabel: String {
        guard let rem = player.sleepTimerRemainingSeconds else { return "定时" }
        return "\(max(1, rem / 60))分"
    }

    private func addCurrentBookmark() {
        guard let book = player.currentBook, let ep = player.currentEpisode else { return }
        library.addBookmark(book: book, episodeIndex: player.currentEpisodeIndex, episodeTitle: ep.displayTitle, timestamp: player.currentTime)
        bookmarkAddedToast = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            bookmarkAddedToast = false
        }
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "00:00" }
        let total = Int(sec)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
