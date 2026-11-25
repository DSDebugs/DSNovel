import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 播放页章节目录弹窗（第二版精修：书封顶栏 + 常驻搜索与排序/下载钮 + 分段/已下载底线切换 + 离线左滑单删）
struct ChapterListSheet: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var model = PlayerChapterListModel()
    @State private var locateRequestID = 0
    private let onOpenBatchDownload: () -> Void
    private let onDismiss: () -> Void

    init(
        onOpenBatchDownload: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.onOpenBatchDownload = onOpenBatchDownload
        self.onDismiss = onDismiss
    }

    private func downloadedRecordsByChapterID() -> [String: DownloadRecordSnapshot] {
        guard let bookID = playback.currentBook?.id else { return [:] }
        var map: [String: DownloadRecordSnapshot] = [:]
        for rec in downloads.manualRecords where rec.bookID == bookID && rec.state == .completed { map[rec.chapterID] = rec }
        return map
    }

    private func totalDownloadedBytes(from records: [String: DownloadRecordSnapshot]) -> Int64 {
        records.values.reduce(Int64(0)) { $0 + max(0, $1.totalBytes > 0 ? $1.totalBytes : $1.downloadedBytes) }
    }

    var body: some View {
        let downloadedMap = downloadedRecordsByChapterID()
        let downloadedIDs = Set(downloadedMap.keys)
        let downloadedCount = downloadedIDs.count
        let totalBytes = totalDownloadedBytes(from: downloadedMap)
        let segments = PlayerChapterListModel.segments(for: playback.chapters.count)
        let rows = model.displayedRows(from: playback.chapters, downloadedChapterIDs: downloadedIDs, useSegments: true)

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                headerBar
                searchAndActionsBar
                filterAndLocateBar(segments: segments, downloadedCount: downloadedCount)

                Divider()
                    .overlay(DSColors.separator.opacity(0.32))

                if model.onlyDownloaded && downloadedCount > 0 {
                    downloadedSummaryStrip(count: downloadedCount, totalBytes: totalBytes)
                }

                if rows.isEmpty {
                    emptyStateView
                } else {
                    List(rows) { row in
                        let record = downloadedMap[row.chapter.id]
                        let isCurrent = (row.physicalIndex == playback.currentChapterIndex)
                        ChapterListRow(
                            row: row,
                            isCurrent: isCurrent,
                            isPlaying: playback.state.isPlaying,
                            record: record,
                            isLast: row.id == rows.last?.id,
                            onSelect: { handleSelectRow(row, isCurrent: isCurrent) }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(row.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let record {
                                Button(role: .destructive) {
                                    DSHaptics.lightImpact()
                                    Task {
                                        await downloads.cancelAndDelete(id: record.id)
                                        banner.show("已删除该章离线文件", tone: .info)
                                    }
                                } label: {
                                    Label("删除离线", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(DSColors.surfaceBase)
            .overlay(alignment: .top) {
                if let msg = banner.current {
                    DSBannerPill(message: msg)
                        .padding(.top, DSSpacing.xs)
                }
            }
            .onAppear {
                if let segIdx = PlayerChapterListModel.segmentIndex(for: playback.currentChapter?.id, in: playback.chapters) {
                    model.selectedSegmentIndex = segIdx
                }
                locateRequestID &+= 1
            }
            .task(id: locateRequestID) {
                guard let currentID = playback.currentChapter?.id else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func handleSelectRow(_ row: IndexedChapterRow, isCurrent: Bool) {
        DSHaptics.selection()
        if isCurrent {
            if !playback.state.isPlaying {
                playback.resume()
            }
        } else if let book = playback.currentBook {
            playback.play(book: book, chapters: playback.chapters, startIndex: row.physicalIndex, autoPlay: true)
        }
        onDismiss()
    }

    private var headerBar: some View {
        let total = playback.chapters.count
        let currentIndex = playback.currentChapterIndex + 1
        let statusSuffix = playback.state.isPlaying ? "播放中" : "已暂停"
        let subtitle = total > 0 && playback.currentChapter != nil
            ? "共 \(total) 章 · 第 \(currentIndex) 章\(statusSuffix)"
            : "共 \(total) 章"

        return HStack(spacing: DSSpacing.sm) {
            DSCover(
                url: playback.currentBook?.coverURL ?? "",
                title: playback.currentBook?.title ?? "有声书",
                pipeline: container.coverPipeline,
                side: 36,
                showsBorder: true,
                showsSoftShadow: false
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("章节目录")
                    .font(DSTypography.rowTitle.weight(.bold))
                    .foregroundStyle(DSColors.inkPrimary)
                Text(subtitle)
                    .font(DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DSColors.surfaceCard))
                    .overlay(Circle().strokeBorder(DSColors.separator.opacity(0.32), lineWidth: 0.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭章节目录")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.top, DSSpacing.sm)
        .padding(.bottom, DSSpacing.xs)
    }

    private var searchAndActionsBar: some View {
        HStack(spacing: DSSpacing.xs) {
            DSClearableSearchField(
                model.onlyDownloaded ? "搜索已下载章节" : "搜索章节号或标题",
                text: $model.keyword
            )

            Button {
                DSHaptics.selection()
                model.isDescending.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DSTypography.callout.weight(.medium))
                    .foregroundStyle(model.isDescending ? DSColors.accent : DSColors.inkPrimary.opacity(0.86))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(DSColors.surfaceCard))
                    .overlay(
                        Circle().strokeBorder(
                            model.isDescending ? DSColors.accent.opacity(0.45) : DSColors.separator.opacity(0.28),
                            lineWidth: 0.5
                        )
                    )
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isDescending ? "当前倒序，点击切换正序" : "当前正序，点击切换倒序")

            Button(action: onOpenBatchDownload) {
                Image(systemName: "arrow.down.to.line")
                    .font(DSTypography.callout.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(DSColors.surfaceCard))
                    .overlay(Circle().strokeBorder(DSColors.accent.opacity(0.30), lineWidth: 0.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("批量下载离线章节")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.bottom, DSSpacing.xs)
    }

    private func filterAndLocateBar(segments: [ChapterSegmentRange], downloadedCount: Int) -> some View {
        HStack(spacing: DSSpacing.md) {
            if segments.count > 1 {
                segmentTabMenu(segments: segments)
            } else {
                tabLabelButton(title: "全部章节", isSelected: !model.onlyDownloaded) {
                    DSHaptics.selection()
                    DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) { model.onlyDownloaded = false }
                }
            }

            tabLabelButton(
                title: downloadedCount > 0 ? "已下载 (\(downloadedCount))" : "已下载",
                isSelected: model.onlyDownloaded
            ) {
                DSHaptics.selection()
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) { model.onlyDownloaded = true }
            }

            Spacer(minLength: 4)

            if model.onlyDownloaded {
                actionOutlinePill(icon: nil, title: "管理离线", action: onOpenBatchDownload)
            } else {
                actionOutlinePill(icon: "pin.fill", title: "定位当前") {
                    locateCurrentChapter(segments: segments)
                }
                .disabled(playback.currentChapter == nil)
                .opacity(playback.currentChapter == nil ? 0.45 : 1)
            }
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.bottom, 6)
    }

    private func segmentTabMenu(segments: [ChapterSegmentRange]) -> some View {
        let currentLabel = segments.indices.contains(model.selectedSegmentIndex)
            ? segments[model.selectedSegmentIndex].label
            : "1–100"
        let active = !model.onlyDownloaded
        return Menu {
            ForEach(segments) { seg in
                Button {
                    DSHaptics.selection()
                    model.onlyDownloaded = false
                    model.selectedSegmentIndex = seg.index
                } label: {
                    HStack {
                        Text("第 \(seg.label) 章")
                        if seg.index == model.selectedSegmentIndex && active {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    Text("第 \(currentLabel) 章")
                        .font(DSTypography.subheadline.weight(active ? .semibold : .regular))
                    Image(systemName: "chevron.down")
                        .font(DSTypography.caption2.weight(.semibold))
                }
                .foregroundStyle(active ? DSColors.accent : DSColors.inkSecondary)

                Capsule()
                    .fill(active ? DSColors.accent : Color.clear)
                    .frame(width: 28, height: 2.5)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
    }

    private func tabLabelButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(DSTypography.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                Capsule()
                    .fill(isSelected ? DSColors.accent : Color.clear)
                    .frame(width: 28, height: 2.5)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionOutlinePill(icon: String?, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(DSTypography.caption2)
                }
                Text(title)
                    .font(DSTypography.caption.weight(.medium))
            }
            .foregroundStyle(DSColors.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(DSColors.accent.opacity(0.10)))
            .overlay(Capsule().strokeBorder(DSColors.accent.opacity(0.45), lineWidth: 0.6))
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func downloadedSummaryStrip(count: Int, totalBytes: Int64) -> some View {
        let sizeText = ChapterListRow.formatFileSize(totalBytes)
        let leftText = sizeText.isEmpty ? "已离线 \(count) 章" : "已离线 \(count) 章 · 约 \(sizeText)"
        return HStack {
            Text(leftText)
                .font(DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.inkSecondary)
            Spacer()
            Text("左滑可删单章")
                .font(DSTypography.caption2)
                .foregroundStyle(DSColors.inkSecondary.opacity(0.75))
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
        .padding(.vertical, 7)
        .background(DSColors.surfaceCard.opacity(0.45))
    }

    private var emptyStateView: some View {
        let isNoBook = playback.chapters.isEmpty
        let isEmptyDownloads = model.onlyDownloaded && model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return DSStateView(
            icon: isEmptyDownloads ? "arrow.down.circle" : (isNoBook ? "list.bullet.rectangle" : "magnifyingglass"),
            title: isEmptyDownloads ? "暂无已下载章节" : (isNoBook ? "暂无可播放章节" : "未找到匹配章节"),
            message: isEmptyDownloads ? "离线下载后即可无网秒播，支持单章左滑清理。" : (isNoBook ? "当前书籍尚未加载章节目录。" : "可清空关键词或切换筛选条件查看全部章节。"),
            actionTitle: isEmptyDownloads ? "去批量下载" : (isNoBook ? nil : "重置筛选"),
            action: isEmptyDownloads ? onOpenBatchDownload : (isNoBook ? nil : {
                model.keyword = ""
                model.onlyDownloaded = false
            })
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func locateCurrentChapter(segments: [ChapterSegmentRange]) {
        guard let targetID = playback.currentChapter?.id else { return }
        DSHaptics.selection()
        model.keyword = ""
        model.onlyDownloaded = false
        if let segIdx = PlayerChapterListModel.segmentIndex(for: targetID, in: playback.chapters),
           segments.indices.contains(segIdx) {
            model.selectedSegmentIndex = segIdx
        }
        locateRequestID &+= 1
    }
}
