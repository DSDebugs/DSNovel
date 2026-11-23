import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 7：播放器快捷下载（1:1 复刻 v2.8：空态保护 + 本书下载概览 + 快捷下载 当前/后10/后30/全部 + 跳转全局下载）
struct PlayerDownloadSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var isEnqueuing = false
    private let onOpenGlobalDownloads: () -> Void
    private let onDismiss: () -> Void

    init(
        onOpenGlobalDownloads: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.onOpenGlobalDownloads = onOpenGlobalDownloads
        self.onDismiss = onDismiss
    }

    private func bookDownloadStats() -> (completed: Int, bytes: Int64) {
        guard let bookID = playback.currentBook?.id else { return (0, 0) }
        var completed = 0
        var bytes: Int64 = 0
        for rec in downloads.manualRecords where rec.bookID == bookID && rec.state == .completed {
            completed += 1
            bytes += max(0, rec.totalBytes)
        }
        return (completed, bytes)
    }

    var body: some View {
        @Bindable var bindableSettings = settings
        let hasNoBook = (playback.currentBook == nil)
        let cannotDownload = hasNoBook || playback.chapters.isEmpty
        let total = max(1, playback.chapters.count)
        let curOneBased = min(total, max(1, playback.currentChapterIndex + 1))
        let stats = bookDownloadStats()

        DSSheetScaffold(title: "章节离线下载", banner: banner, onDismiss: onDismiss) {
            List {
                if cannotDownload {
                    Section {
                        Text(hasNoBook ? "请先选择书籍后再下载离线章节。" : "当前书籍暂无章节目录，无法加入下载队列。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .listRowBackground(DSColors.surfaceCard)
                    }
                } else {
                    Section("本书离线概览") {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            HStack {
                                Text(playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "当前书籍")
                                    .font(DSTypography.rowTitle)
                                    .lineLimit(1)
                                Spacer()
                                Text("已下载 \(stats.completed) / \(playback.chapters.count) 章")
                                    .font(DSTypography.numericCaption.weight(.semibold))
                                    .foregroundStyle(DSColors.accent)
                            }
                            Text("本书占用 \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)) · 全部离线 \(ByteCountFormatter.string(fromByteCount: downloads.totalDiskBytes, countStyle: .file))")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .padding(.vertical, DSSpacing.xxs)
                        .listRowBackground(DSColors.surfaceCard)

                        Toggle("仅在 Wi-Fi 下下载", isOn: $bindableSettings.wifiOnlyDownload)
                            .onChange(of: settings.wifiOnlyDownload) { _, _ in
                                container.syncSettingsToEngines()
                            }
                            .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section("快捷批量下载（从第 \(curOneBased) 章起）") {
                    quickDownloadRow("下载当前章节（第 \(curOneBased) 章）", icon: "arrow.down.circle", count: 1, disabled: cannotDownload)
                    quickDownloadRow("下载后续 10 章（第 \(curOneBased)–\(min(total, curOneBased + 9)) 章）", icon: "arrow.down.to.line", count: 10, disabled: cannotDownload)
                    quickDownloadRow("下载后续 30 章（第 \(curOneBased)–\(min(total, curOneBased + 29)) 章）", icon: "square.and.arrow.down.on.square", count: 30, disabled: cannotDownload)
                    quickDownloadRow("下载后续全部章节（第 \(curOneBased)–\(total) 章）", icon: "tray.and.arrow.down.fill", count: total, disabled: cannotDownload)
                }

                Section("全局管理") {
                    Button {
                        onDismiss()
                        onOpenGlobalDownloads()
                    } label: {
                        Label("打开全局下载与存储管理", systemImage: "internaldrive")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func quickDownloadRow(_ title: String, icon: String, count: Int, disabled: Bool) -> some View {
        Button {
            enqueue(count: count)
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isEnqueuing)
        .listRowBackground(DSColors.surfaceCard)
    }

    private func enqueue(count: Int) {
        guard !isEnqueuing, let book = playback.currentBook, !playback.chapters.isEmpty else { return }
        let start = min(max(0, playback.currentChapterIndex), playback.chapters.count - 1)
        let end = min(playback.chapters.count, start + max(1, count))
        guard start < end else { return }
        isEnqueuing = true
        let slice = Array(playback.chapters[start..<end])
        Task {
            defer { isEnqueuing = false }
            await downloads.enqueueManual(book: book, chapters: slice, quality: container.resolvedQuality(for: book))
            DSHaptics.selection()
            banner.show("已添加 \(slice.count) 章至下载队列", tone: .success)
            onDismiss()
        }
    }
}
