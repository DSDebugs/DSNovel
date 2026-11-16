import SwiftUI
import SwiftData
import AVKit

/// 迷你播放条（5.5 节）：控制层玻璃封装、左封面、中章节与书名、右播放/暂停与下一章、底部 2pt 进度线
struct MiniPlayerBar: View {
    let onTapExpand: () -> Void
    private var player = PlayerEngine.shared

    init(onTapExpand: @escaping () -> Void) {
        self.onTapExpand = onTapExpand
    }

    var body: some View {
        if let book = player.currentBook, let chapter = player.currentChapter {
            GlassEffectContainer(cornerRadius: 20) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        CoverImageView(
                            url: book.cover,
                            title: book.title,
                            width: 40,
                            height: 40,
                            cornerRadius: 8
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if case .failed(let errMsg) = player.state {
                                Text(errMsg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else if player.state == .buffering {
                                Text("正在缓冲音频… · \(book.title)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(book.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()

                        GlassButton {
                            player.togglePlayPause()
                        } label: {
                            if player.state == .buffering {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 36, height: 36)
                            } else {
                                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                            }
                        }
                        .accessibilityLabel(player.state == .playing ? "暂停" : "播放")

                        GlassButton {
                            player.playNextChapter()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.subheadline)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("下一章")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    MiniPlayerProgressLine(clock: player.clock)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTapExpand()
            }
        }
    }
}

/// 独立订阅 PlaybackClock 的 2pt 细进度线，避免迷你条主体每秒重绘
private struct MiniPlayerProgressLine: View {
    var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                Rectangle()
                    .fill(DSColor.primary)
                    .frame(width: geo.size.width * clock.progressFraction)
            }
        }
        .frame(height: 2)
    }
}

/// 全屏播放页（5.5 节）：封面主色静态渐变、单个 GlassEffectContainer 主控制组、独立时钟进度条与次级控制行（已完整移除书签并支持一键加入书架与就地网页登录）
struct PlayerFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allBooks: [Book]
    @Query private var plugins: [PluginRecord]

    private var player = PlayerEngine.shared
    private var settings = AppSettingsStore.shared

    @State private var dominantColor: Color = Color(red: 0.14, green: 0.22, blue: 0.36)
    @State private var showSkipSheet = false
    @State private var showChapterSheet = false
    @State private var showVolumeSheet = false
    @State private var authSession: WebAuthSessionRequest?

    private var currentBookRecord: Book? {
        guard let bookID = player.currentBook?.id else { return nil }
        return allBooks.first(where: { $0.id == bookID })
    }

    private var isInShelf: Bool {
        currentBookRecord?.inShelf == true
    }

    var body: some View {
        ZStack {
            // 一次性计算并缓存的封面主色静态渐变，不使用实时模糊（2.4 节）
            LinearGradient(
                colors: [dominantColor, Color.black.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                // 顶部下拉收起栏
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                    }
                    .accessibilityLabel("收起播放页")
                    Spacer()
                    if player.sleepOption != .off {
                        Text(sleepStatusBadgeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                }
                .padding(.horizontal, DSSpacing.xl)

                Spacer(minLength: 4)

                // 上部：封面大图（圆角，带轻微阴影，阴影仅给封面 - 5.5 节）
                if let book = player.currentBook {
                    CoverImageView(
                        url: book.cover,
                        title: book.title,
                        width: 256,
                        height: 256,
                        cornerRadius: 18,
                        onImageLoaded: { uiImage in
                            dominantColor = DominantColorExtractor.extractPrimaryColor(
                                from: uiImage,
                                cacheKey: book.id
                            )
                        }
                    )
                    .shadow(color: .black.opacity(0.38), radius: 18, x: 0, y: 10)
                }

                // 中部：章节名、书名与独立时钟进度条
                VStack(spacing: 6) {
                    Text(player.currentChapter?.title ?? "未选择章节")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(player.currentBook?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(.horizontal, DSSpacing.xl)

                PlayerClockSliderSection(clock: player.clock) { targetSec in
                    player.seek(to: targetSec)
                }
                .padding(.horizontal, DSSpacing.xl)

                // 行内错误提示（支持就地打开网页登录/验证并在完成后自动重播）
                if case .failed(let msg) = player.state {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let pErr = player.lastPluginError {
                            switch pErr {
                            case .needLogin(_, let loginURL):
                                Button("去登录") {
                                    openAuthForCurrentSource(url: loginURL, isLogin: true)
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.24)))
                                .foregroundStyle(.white)
                            case .needVerify(_, let verifyURL):
                                Button("去验证") {
                                    openAuthForCurrentSource(url: verifyURL, isLogin: false)
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.24)))
                                .foregroundStyle(.white)
                            default:
                                // VIP 章节：唯一提示出口 —— 跳到「书源管理 → 内置解析」
                                if let jumpTitle = pErr.builtinParserJumpTitle {
                                    Button(jumpTitle) {
                                        AppRouter.shared.openBuiltinParser(sourceID: player.currentBook?.sourceID)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.24)))
                                    .foregroundStyle(.white)
                                } else {
                                    EmptyView()
                                }
                            }
                        }
                        Button("重试") {
                            player.retryCurrentChapter()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, DSSpacing.xl)
                }

                // 主控制组：单个 GlassEffectContainer 包裹 5 个主控按钮（2.4 & 5.5 节）
                GlassEffectContainer(cornerRadius: 34) {
                    HStack(spacing: 26) {
                        GlassButton {
                            player.playPreviousChapter()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("上一章")

                        GlassButton {
                            player.skipBackward(15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("快退 15 秒")

                        GlassButton {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel(player.state == .playing ? "暂停" : "播放")

                        GlassButton {
                            player.skipForward(30)
                        } label: {
                            Image(systemName: "goforward.30")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("快进 30 秒")

                        GlassButton {
                            player.playNextChapter()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("下一章")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                }

                // 次级控制行（纯图标，系统样式 - 已移除书签并替换为「加入书架 / 已在书架」快捷开关）
                secondaryControlRow
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.bottom, DSSpacing.lg)

                Spacer(minLength: 8)
            }
        }
        .sheet(isPresented: $showSkipSheet) {
            skipIntroOutroSheet
        }
        .sheet(isPresented: $showChapterSheet) {
            chapterListSheet
        }
        .sheet(isPresented: $showVolumeSheet) {
            volumeAndChannelSheet
        }
        .sheet(item: $authSession) { session in
            WebAuthSheet(session: session)
        }
    }

    private func openAuthForCurrentSource(url: String, isLogin: Bool) {
        guard let book = player.currentBook else { return }
        let plugin = plugins.first(where: { $0.id == book.sourceID })
        let fallback = plugin?.loginURL.isEmpty == false ? (plugin?.loginURL ?? "") : (plugin?.siteURL ?? book.bookURL)
        authSession = WebAuthSessionRequest(
            sourceID: book.sourceID,
            title: "\(isLogin ? "登录" : "安全验证") · \(plugin?.name ?? book.sourceID)",
            initialURL: url.isEmpty ? fallback : url,
            expectedCookieName: nil,
            onCompleted: {
                plugin?.loggedIn = true
                try? modelContext.save()
                player.retryCurrentChapter()
            }
        )
    }

    private var sleepStatusBadgeText: String {
        switch player.sleepOption {
        case .off:
            return ""
        case .minutes:
            return "定时 \(PlaybackClock.formatSeconds(Double(player.sleepRemainingSec)))"
        case .endOfChapter:
            return "本章结束暂停"
        case .chaptersRemaining(let c):
            return "\(c) 集后暂停"
        }
    }

    private var secondaryControlRow: some View {
        HStack(spacing: 0) {
            // 1. 倍速 Menu
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                    Button {
                        player.speed = rate
                        player.saveBookAudioSettings()
                    } label: {
                        if abs(player.speed - rate) < 0.01 {
                            Label(String(format: "%.2gx", rate), systemImage: "checkmark")
                        } else {
                            Text(String(format: "%.2gx", rate))
                        }
                    }
                }
                Divider()
                Button("加速 +0.1x") {
                    player.speed = min(3.0, (player.speed + 0.1).rounded(toPlaces: 2))
                    player.saveBookAudioSettings()
                }
                Button("减速 -0.1x") {
                    player.speed = max(0.5, (player.speed - 0.1).rounded(toPlaces: 2))
                    player.saveBookAudioSettings()
                }
            } label: {
                VStack(spacing: 4) {
                    Text(String(format: "%.2gx", player.speed))
                        .font(.subheadline.weight(.semibold))
                    Text("倍速")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("播放倍速")

            // 2. 睡眠定时 Menu
            Menu {
                Button("关闭定时") { player.setSleepTimer(.off) }
                Button("15 分钟") { player.setSleepTimer(.minutes(15)) }
                Button("30 分钟") { player.setSleepTimer(.minutes(30)) }
                Button("60 分钟") { player.setSleepTimer(.minutes(60)) }
                Button("本章结束") { player.setSleepTimer(.endOfChapter) }
                Button("播完 2 集后") { player.setSleepTimer(.chaptersRemaining(2)) }
                Button("播完 5 集后") { player.setSleepTimer(.chaptersRemaining(5)) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: player.sleepOption == .off ? "moon" : "moon.fill")
                        .font(.body)
                    Text("定时")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("睡眠定时")

            // 3. 跳过片头片尾
            Button {
                showSkipSheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "forward.frame")
                        .font(.body)
                    Text("跳过")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("跳过片头片尾")

            // 4. 加入书架 / 已在书架（替代原书签按钮，方便收听过程中一键收藏到书架）
            Button {
                ToastManager.shared.triggerHaptic(.medium)
                toggleCurrentBookShelfState()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: isInShelf ? "checkmark.circle.fill" : "plus.square.on.square")
                        .font(.body)
                    Text(isInShelf ? "已在书架" : "加书架")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(isInShelf ? "已在书架" : "加入书架")

            // 5. 章节列表
            Button {
                showChapterSheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.body)
                    Text("目录")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("章节目录")

            // 6. 更多（本书音量、播放通道、AirPlay）
            Button {
                showVolumeSheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                    Text("更多")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("音量与音频通道")
        }
    }

    private func toggleCurrentBookShelfState() {
        guard let book = player.currentBook else { return }
        if let existing = currentBookRecord {
            existing.inShelf.toggle()
            if existing.inShelf {
                existing.addedAt = .now
                ToastManager.shared.show("已加入书架")
            } else {
                existing.isPinned = false
                existing.categoryID = nil
                ToastManager.shared.show("已移出书架（保留在最近播放）")
            }
            try? modelContext.save()
        } else {
            let newBook = Book(
                id: book.id,
                sourceID: book.sourceID,
                bookURL: book.bookURL,
                title: book.title,
                author: book.author,
                cover: book.cover,
                intro: book.intro,
                inShelf: true,
                addedAt: .now,
                lastChapterID: player.currentChapter?.id,
                lastChapterTitle: player.currentChapter?.title,
                lastPositionMs: Int(player.clock.currentTimeSec * 1000),
                lastPlayedAt: .now,
                volume: player.bookVolume,
                skipIntroSec: player.skipIntroSec,
                skipOutroSec: player.skipOutroSec,
                speed: player.speed
            )
            modelContext.insert(newBook)
            try? modelContext.save()
            ToastManager.shared.show("已加入书架")
        }
    }

    private var skipIntroOutroSheet: some View {
        NavigationStack {
            Form {
                Section("本书跳过片头片尾（秒）") {
                    Stepper("跳过片头：\(player.skipIntroSec) 秒", value: Bindable(player).skipIntroSec, in: 0...300, step: 5)
                        .onChange(of: player.skipIntroSec) { _, _ in
                            player.saveBookAudioSettings()
                        }

                    Button("把当前播放位置（\(Int(player.clock.currentTimeSec)) 秒）设为片头结束") {
                        player.skipIntroSec = min(300, max(0, Int(player.clock.currentTimeSec)))
                        player.saveBookAudioSettings()
                        ToastManager.shared.show("已将片头跳过设为 \(player.skipIntroSec) 秒")
                    }

                    Stepper("跳过片尾：\(player.skipOutroSec) 秒", value: Bindable(player).skipOutroSec, in: 0...300, step: 5)
                        .onChange(of: player.skipOutroSec) { _, _ in
                            player.saveBookAudioSettings()
                        }
                }
            }
            .navigationTitle("跳过片头片尾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSkipSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var chapterListSheet: some View {
        NavigationStack {
            List(player.chapterQueue) { ch in
                let isCurrent = player.currentChapter?.id == ch.id
                Button {
                    if let book = player.currentBook {
                        player.startPlayback(
                            book: book,
                            chapters: player.chapterQueue,
                            startChapter: ch,
                            initialPositionMs: 0
                        )
                        showChapterSheet = false
                    }
                } label: {
                    HStack {
                        Text(ch.title)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? DSColor.primary : .primary)
                        Spacer()
                        if isCurrent {
                            Image(systemName: "waveform")
                                .foregroundStyle(DSColor.primary)
                        }
                    }
                }
            }
            .navigationTitle("章节列表（\(player.chapterQueue.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showChapterSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var volumeAndChannelSheet: some View {
        NavigationStack {
            Form {
                Section("本书独立音量") {
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Bindable(player).bookVolume, in: 0.1...1.0)
                            .onChange(of: player.bookVolume) { _, _ in
                                player.saveBookAudioSettings()
                            }
                        Image(systemName: "speaker.wave.3.fill")
                    }
                }

                Section {
                    Picker("播放通道", selection: Bindable(settings).audioChannel) {
                        ForEach(AudioChannelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("播放通道")
                } footer: {
                    Text(settings.audioChannel.subtitle)
                }

                Section("隔空播放（AirPlay）") {
                    HStack {
                        Text("选择音频输出设备")
                        Spacer()
                        AirPlayRoutePickerRepresentable()
                            .frame(width: 36, height: 36)
                    }
                }
            }
            .navigationTitle("音频与输出设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showVolumeSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 独立订阅 PlaybackClock 的进度滑块组件（支持 VoiceOver accessibilityAdjustableAction - 5.8 节）
private struct PlayerClockSliderSection: View {
    var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var isDragging = false
    @State private var dragSeconds: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragSeconds : clock.currentTimeSec },
                    set: { newVal in
                        isDragging = true
                        dragSeconds = newVal
                    }
                ),
                in: 0...max(clock.durationSec, 1),
                onEditingChanged: { editing in
                    if !editing {
                        isDragging = false
                        onSeek(dragSeconds)
                    }
                }
            )
            .tint(.white)
            .accessibilityLabel("播放进度")
            .accessibilityValue(clock.formattedCurrent)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onSeek(min(clock.durationSec, clock.currentTimeSec + 15))
                case .decrement:
                    onSeek(max(0, clock.currentTimeSec - 15))
                @unknown default:
                    break
                }
            }

            HStack {
                Text(isDragging ? PlaybackClock.formatSeconds(dragSeconds) : clock.formattedCurrent)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(clock.formattedRemaining)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
