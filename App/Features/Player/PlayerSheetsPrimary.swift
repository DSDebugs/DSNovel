import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import Observation
import SwiftUI

struct IndexedChapterRow: Identifiable {
    let physicalIndex: Int
    let chapter: ChapterDTO
    var id: String { chapter.id }
}

/// 目录弹窗状态模型（将筛选与倒序计算彻底移出 View body 并缓存派生结果，符合规则 #8）
@Observable
@MainActor
final class PlayerChapterListModel {
    private struct CacheKey: Equatable {
        let keyword: String
        let isDescending: Bool
        let count: Int
        let firstID: String?
        let lastID: String?
    }

    var keyword: String = ""
    var isDescending: Bool = false

    @ObservationIgnored private var cachedKey: CacheKey?
    @ObservationIgnored private var cachedRows: [IndexedChapterRow] = []

    func displayedRows(from source: [ChapterDTO]) -> [IndexedChapterRow] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = CacheKey(
            keyword: trimmed,
            isDescending: isDescending,
            count: source.count,
            firstID: source.first?.id,
            lastID: source.last?.id
        )
        if cachedKey == key {
            return cachedRows
        }
        var rows: [IndexedChapterRow] = []
        rows.reserveCapacity(source.count)
        for (idx, ch) in source.enumerated() {
            if trimmed.isEmpty || ch.title.localizedCaseInsensitiveContains(trimmed) {
                rows.append(IndexedChapterRow(physicalIndex: idx, chapter: ch))
            }
        }
        let result = isDescending ? Array(rows.reversed()) : rows
        cachedKey = key
        cachedRows = result
        return result
    }
}

/// 弹窗 1：章节目录
struct ChapterListSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var model = PlayerChapterListModel()
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        let rows = model.displayedRows(from: playback.chapters)
        DSSheetScaffold(title: "章节目录（\(playback.chapters.count)）", banner: banner, onDismiss: onDismiss) {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.xs) {
                    DSClearableSearchField("筛选章节名", text: $model.keyword)
                    Button(model.isDescending ? "倒序" : "正序") {
                        model.isDescending.toggle()
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)

                if rows.isEmpty {
                    DSStateView(
                        icon: playback.chapters.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                        title: playback.chapters.isEmpty ? "暂无可播放章节" : "未找到匹配章节",
                        message: playback.chapters.isEmpty ? "当前书籍尚未加载章节目录。" : "请尝试缩短关键词或清空筛选条件。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List(rows) { row in
                            let isCurrent = (row.physicalIndex == playback.currentChapterIndex)
                            Button {
                                if let book = playback.currentBook {
                                    playback.play(book: book, chapters: playback.chapters, startIndex: row.physicalIndex, autoPlay: true)
                                }
                                onDismiss()
                            } label: {
                                HStack {
                                    Text(row.chapter.title)
                                        .font(DSTypography.subheadline)
                                        .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(DSColors.accent)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        .onAppear {
                            if let currentID = playback.currentChapter?.id,
                               rows.contains(where: { $0.id == currentID }) {
                                proxy.scrollTo(currentID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 弹窗 2：睡眠定时（墙钟分钟 + 按章停播，严格使用「章」禁用「集」）
struct SleepTimerSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    private let minutePresets = [15, 30, 45, 60, 90]
    private let chapterPresets = [1, 2, 3, 5]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "睡眠定时", banner: banner, onDismiss: onDismiss) {
            List {
                if playback.sleepTimer.isActive {
                    Section("当前定时") {
                        HStack {
                            Text(playback.sleepTimer.displayBadge ?? "")
                                .font(DSTypography.headline)
                            Spacer()
                            Button("取消定时", role: .destructive) {
                                playback.sleepTimer.cancel()
                                banner.show("已取消睡眠定时", tone: .info)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                Section("按时间关闭（墙钟防漂移）") {
                    ForEach(minutePresets, id: \.self) { min in
                        Button("\(min) 分钟后暂停") {
                            playback.sleepTimer.startCountdown(
                                minutes: min,
                                onFadeFactor: { playback.applySleepFade(factor: $0) },
                                onFire: { playback.pause() }
                            )
                            banner.show("已设定 \(min) 分钟后自动暂停", tone: .success)
                            onDismiss()
                        }
                        .frame(minHeight: 44)
                    }
                }

                Section("按章节关闭（播完自动预定位下章片头）") {
                    ForEach(chapterPresets, id: \.self) { count in
                        Button("播完 \(count) 章后暂停") {
                            playback.sleepTimer.startAfterChapters(count)
                            banner.show("已设定播完 \(count) 章后暂停", tone: .success)
                            onDismiss()
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// 弹窗 3：倍速调节
struct SpeedSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", banner: banner, onDismiss: onDismiss) {
            List {
                Section("快捷倍速") {
                    ForEach(presets, id: \.self) { rate in
                        Button {
                            playback.playbackRate = rate
                            settings.playbackRate = rate
                            onDismiss()
                        } label: {
                            HStack {
                                Text(PlayerSpeedFormatter.format(rate))
                                    .font(DSTypography.headline)
                                Spacer()
                                if abs(playback.playbackRate - rate) < 0.01 {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DSColors.accent)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// 弹窗 4：单本跳过片头/片尾（规则 #17：仅对当前书籍生效）
struct SkipSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    @State private var introSec: Int = 0
    @State private var outroSec: Int = 0
    @State private var hasUserEdited = false
    @State private var boundBookID: String?

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        let hasNoBook = (playback.currentBook == nil)
        DSSheetScaffold(title: "本书跳过片头片尾", banner: banner, onDismiss: onDismiss) {
            Form {
                if hasNoBook {
                    Section {
                        Text("请先选择书籍后再配置跳过片头片尾。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }
                Section("仅对当前书籍生效") {
                    Stepper(
                        "跳过片头：\(introSec) 秒",
                        value: Binding(
                            get: { introSec },
                            set: {
                                introSec = $0
                                hasUserEdited = true
                            }
                        ),
                        in: 0...600,
                        step: 5
                    )
                    .disabled(hasNoBook)
                    Stepper(
                        "跳过片尾：\(outroSec) 秒",
                        value: Binding(
                            get: { outroSec },
                            set: {
                                outroSec = $0
                                hasUserEdited = true
                            }
                        ),
                        in: 0...600,
                        step: 5
                    )
                    .disabled(hasNoBook)
                }
                Section {
                    Button("保存设置") {
                        guard let currentBookID = playback.currentBook?.id,
                              boundBookID == nil || boundBookID == currentBookID else { return }
                        playback.updateBookSkipConfig(SkipConfigDTO(introSeconds: introSec, outroSeconds: outroSec))
                        banner.show("已保存本书跳过片头片尾设置", tone: .success)
                        onDismiss()
                    }
                    .disabled(hasNoBook)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .task(id: playback.currentBook?.id) {
                boundBookID = playback.currentBook?.id
                hasUserEdited = false
                introSec = playback.bookSkipConfig.introSeconds
                outroSec = playback.bookSkipConfig.outroSeconds
            }
            .onChange(of: playback.bookSkipConfig) { _, next in
                guard !hasUserEdited else { return }
                introSec = next.introSeconds
                outroSec = next.outroSeconds
            }
        }
    }
}
