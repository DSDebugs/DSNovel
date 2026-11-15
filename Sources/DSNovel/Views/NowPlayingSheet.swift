import SwiftUI

enum PlayerCenterStageMode: String, CaseIterable, Identifiable {
    case artwork = "封面舞台"
    case chapters = "全集目录"

    var id: String { rawValue }
}

/// 独立进度条子视图：隔离每秒 2 次的 `currentTime` 更新，拖动时防止 seek 洪水与滑块回弹抖动 (M-07, M-08)
private struct PlayerProgressSliderView: View {
    @Environment(AudioPlayerEngine.self) private var player
    @State private var isDragging: Bool = false
    @State private var dragValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : player.currentTime },
                    set: { newVal in
                        dragValue = newVal
                        if !isDragging {
                            player.seek(to: newVal)
                        }
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing {
                        dragValue = player.currentTime
                    } else {
                        player.seek(to: dragValue)
                    }
                }
            )
            .tint(.orange)
            .accessibilityLabel("播放进度条")

            HStack {
                Text(formatTime(isDragging ? dragValue : player.currentTime))
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
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "00:00" }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
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

    private var orderedEpisodes: [EpisodeItem] {
        isAscending ? player.episodes : Array(player.episodes.reversed())
    }

    private var currentSliceEpisodes: [EpisodeItem] {
        let ordered = orderedEpisodes
        guard !ordered.isEmpty else { return [] }
        let start = min(selectedSlice * sliceSize, max(0, ordered.count - 1))
        let end = min(start + sliceSize, ordered.count)
        guard start < end else { return Array(ordered.prefix(sliceSize)) }
        return Array(ordered[start..<end])
    }

    var body: some View {
        ZStack {
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
                topHeaderBar

                Group {
                    switch centerMode {
                    case .artwork:
                        artworkStageView
                    case .chapters:
                        chaptersStageView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemName: "chevron.down", accessibilityTitle: "收起播放器", size: 40) {
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
                    width: 230,
                    height: 306,
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

                    Text("\(book.title)\(book.author.isEmpty ? "" : " · \(book.author)")")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if player.isLoadingStream {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(player.isPlaying ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                        }
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
            } else {
                ProgressView("正在准备播放...")
            }

            Spacer(minLength: 6)
        }
    }

    private var chaptersStageView: some View {
        let ordered = orderedEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("全部章节（共 \(player.episodes.count) 集）")
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
                            let startIdx = slice * sliceSize
                            let endIdx = min((slice + 1) * sliceSize - 1, max(0, ordered.count - 1))
                            let firstNum = ordered.indices.contains(startIdx) ? ordered[startIdx].index : (startIdx + 1)
                            let lastNum = ordered.indices.contains(endIdx) ? ordered[endIdx].index : (endIdx + 1)
                            GlassPillButton(
                                title: "\(firstNum)-\(lastNum)集",
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(currentSliceEpisodes) { ep in
                            let isCurrent = (player.currentEpisode?.id == ep.id)
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                if let book = player.currentBook,
                                   let realIdx = player.episodes.firstIndex(where: { $0.id == ep.id }) {
                                    player.startPlayback(book: book, episodes: player.episodes, index: realIdx)
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
                            .id(ep.id)
                            .buttonStyle(ResponsivePressButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    if let currentId = player.currentEpisode?.id {
                        proxy.scrollTo(currentId, anchor: .center)
                    }
                }
            }
        }
    }

    private var bottomControlDock: some View {
        AppGlassContainer(spacing: 14) {
            VStack(spacing: 16) {
                PlayerProgressSliderView()

                HStack(spacing: 24) {
                    GlassIconButton(systemName: "gobackward.15", accessibilityTitle: "快退15秒", size: 44) {
                        player.skip(by: -15)
                    }

                    GlassIconButton(systemName: "backward.end.fill", accessibilityTitle: "上一集", size: 46) {
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
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                    GlassIconButton(systemName: "forward.end.fill", accessibilityTitle: "下一集", size: 46) {
                        player.playNextEpisode()
                    }

                    GlassIconButton(systemName: "goforward.15", accessibilityTitle: "快进15秒", size: 44) {
                        player.skip(by: 15)
                    }
                }

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
                        isSelected: player.sleepTimerPreset != .off,
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
            .appGlassEffect(.regular, in: .rect(cornerRadius: 26))
        }
    }

    private var sleepTimerLabel: String {
        if let rem = player.sleepTimerRemainingSeconds, player.sleepTimerPreset != .off, player.sleepTimerPreset != .endOfEpisode {
            return "\(max(1, rem / 60))分"
        }
        return player.sleepTimerPreset.rawValue
    }
}
