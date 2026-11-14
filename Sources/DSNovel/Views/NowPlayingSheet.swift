import SwiftUI

enum PlayerCenterStageMode: String, CaseIterable, Identifiable {
    case artwork = "封面舞台"
    case chapters = "全集目录"

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
            // 全屏沉浸式深色动态背景
            LinearGradient(
                colors: [
                    (player.currentBook?.source.brandColor ?? .orange).opacity(0.32),
                    Color(red: 0.05, green: 0.06, blue: 0.09),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                // 1. 顶部全屏导航栏（左侧收起 + 中央“封面/目录”切换 + 右侧一键“加入书架”）
                topHeaderBar

                // 2. 中央全屏主舞台（封面舞台 / 全量章节目录舞台）
                Group {
                    switch centerMode {
                    case .artwork:
                        artworkStageView
                    case .chapters:
                        chaptersStageView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 3. 底部液态玻璃播放控制舱（进度条 + 五键主控 + 四键功能坞：倍速 / 定时 / 加入书架 / 章节目录）
                bottomControlDock
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .onAppear {
            centerMode = initialCenterMode
            selectedSlice = player.currentEpisodeIndex / sliceSize
        }
    }

    // MARK: - 顶部全屏控制栏
    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemName: "chevron.down", size: 40) {
                dismiss()
            }

            Spacer()

            HStack(spacing: 8) {
                ForEach(PlayerCenterStageMode.allCases) { mode in
                    let title = (mode == .chapters) ? "目录(\(player.episodes.count))" : mode.rawValue
                    GlassPillButton(
                        title: title,
                        isSelected: centerMode == mode,
                        activeColor: .orange,
                        minHeight: 36
                    ) {
                        withAnimation(.snappy) {
                            centerMode = mode
                        }
                    }
                }
            }

            Spacer()

            // 右上角直接加入/移出书架按钮
            if let book = player.currentBook {
                let inShelf = library.isInBookshelf(book.id)
                GlassPillButton(
                    title: inShelf ? "已在书架" : "加书架",
                    icon: inShelf ? "checkmark.circle.fill" : "plus.circle.fill",
                    isSelected: inShelf,
                    activeColor: .green,
                    minHeight: 36
                ) {
                    library.toggleBookshelf(
                        book,
                        currentEpisodeIndex: player.currentEpisodeIndex,
                        currentEpisodeTitle: player.currentEpisode?.displayTitle,
                        currentTime: player.currentTime
                    )
                }
            }
        }
    }

    // MARK: - 舞台 1：全屏沉浸式封面舞台
    private var artworkStageView: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 6)

            if let book = player.currentBook {
                BookCoverView(
                    bookId: book.id,
                    urlString: book.coverURL,
                    title: book.title,
                    source: book.source,
                    progressBadge: "第\(player.currentEpisodeIndex + 1)集",
                    width: 236,
                    height: 316,
                    cornerRadius: 24
                )
                .shadow(color: .black.opacity(0.6), radius: 22, y: 12)

                VStack(spacing: 10) {
                    Text(player.currentEpisode?.displayTitle ?? book.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)

                    Text("\(book.title) · \(book.author)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(player.isPlaying ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(player.statusBanner)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }

                if let err = player.errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                }
            }

            Spacer(minLength: 6)
        }
    }

    // MARK: - 舞台 2：全屏章节目录舞台
    private var chaptersStageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("全部章节（共 \(player.episodes.count) 集已就绪）")
                    .font(.system(size: 15, weight: .bold))
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
                                minHeight: 32
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
                                    .frame(width: 36, alignment: .leading)

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
                            .padding(.vertical, 12)
                            .frame(minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isCurrent ? Color.orange.opacity(0.22) : Color.white.opacity(0.07))
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

    // MARK: - 底部液态玻璃播放控制舱（移除书签，改为一键“加入书架”）
    private var bottomControlDock: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 16) {
                // 进度条与时间
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
                        if let ep = player.currentEpisode {
                            Text("第 \(ep.index) / \(max(1, player.episodes.count)) 集")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatTime(max(0, player.duration)))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                // 五键主控区
                HStack(spacing: 24) {
                    GlassIconButton(systemName: "gobackward.15", size: 44) {
                        player.skip(by: -15)
                    }

                    GlassIconButton(systemName: "backward.end.fill", size: 46) {
                        player.playPreviousEpisode()
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(Circle().fill(Color.orange.gradient))
                            .shadow(color: .orange.opacity(0.45), radius: 12, y: 4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())

                    GlassIconButton(systemName: "forward.end.fill", size: 46) {
                        player.playNextEpisode()
                    }

                    GlassIconButton(systemName: "goforward.15", size: 44) {
                        player.skip(by: 15)
                    }
                }

                // 底部四键功能坞（倍速 / 定时 / 加入书架 / 章节目录）
                HStack(spacing: 10) {
                    GlassPillButton(
                        title: String(format: "%.2gx", player.playbackRate),
                        icon: "speedometer",
                        isSelected: player.playbackRate != 1.0,
                        activeColor: .orange,
                        minHeight: 40
                    ) {
                        player.cyclePlaybackRate()
                    }

                    GlassPillButton(
                        title: sleepTimerLabel,
                        icon: "moon.zzz.fill",
                        isSelected: player.sleepTimerRemainingSeconds != nil,
                        activeColor: .indigo,
                        minHeight: 40
                    ) {
                        player.cycleSleepTimer()
                    }

                    if let book = player.currentBook {
                        let inShelf = library.isInBookshelf(book.id)
                        GlassPillButton(
                            title: inShelf ? "已加书架" : "加入书架",
                            icon: inShelf ? "checkmark.circle.fill" : "plus.circle.fill",
                            isSelected: inShelf,
                            activeColor: .green,
                            minHeight: 40
                        ) {
                            library.toggleBookshelf(
                                book,
                                currentEpisodeIndex: player.currentEpisodeIndex,
                                currentEpisodeTitle: player.currentEpisode?.displayTitle,
                                currentTime: player.currentTime
                            )
                        }
                    }

                    GlassPillButton(
                        title: centerMode == .chapters ? "返回封面" : "章节目录",
                        icon: "list.bullet",
                        isSelected: centerMode == .chapters,
                        activeColor: .orange,
                        minHeight: 40
                    ) {
                        withAnimation(.snappy) {
                            centerMode = (centerMode == .chapters) ? .artwork : .chapters
                        }
                    }
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
    }

    private var sleepTimerLabel: String {
        guard let rem = player.sleepTimerRemainingSeconds else { return "定时" }
        return "\(max(1, rem / 60))分"
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "00:00" }
        let total = Int(sec)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
