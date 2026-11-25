import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 播放页章节目录弹窗（第二版精修：书封顶栏 + 常驻搜索与排序/下载钮 + 分段/已下载底线切换 + 离线左滑单删）
struct ChapterListSheet: View {
    @Environment(\.dsEffectiveReduceMotion) var reduceMotion
    @Environment(AppContainer.self) var container
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(DSBannerCoordinator.self) var banner
    @State var model = PlayerChapterListModel()
    @State var locateRequestID = 0
    let onOpenBatchDownload: () -> Void
    private let onDismiss: () -> Void

    init(
        onOpenBatchDownload: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.onOpenBatchDownload = onOpenBatchDownload
        self.onDismiss = onDismiss
    }

    private func manualRecordsByChapterID() -> [String: DownloadRecordSnapshot] {
        guard let bookID = playback.currentBook?.id else { return [:] }
        var map: [String: DownloadRecordSnapshot] = [:]
        for rec in downloads.manualRecords where rec.bookID == bookID {
            map[rec.chapterID] = rec
        }
        return map
    }

    private func completedChapterIDs(from records: [String: DownloadRecordSnapshot]) -> Set<String> {
        var ids: Set<String> = []
        for (chapterID, rec) in records where rec.state == .completed {
            ids.insert(chapterID)
        }
        return ids
    }

    private func totalDownloadedBytes(from records: [String: DownloadRecordSnapshot]) -> Int64 {
        records.values.reduce(Int64(0)) { sum, rec in
            guard rec.state == .completed else { return sum }
            return sum + max(0, rec.totalBytes > 0 ? rec.totalBytes : rec.downloadedBytes)
        }
    }

    var body: some View {
        let recordMap = manualRecordsByChapterID()
        let downloadedIDs = completedChapterIDs(from: recordMap)
        let downloadedCount = downloadedIDs.count
        let totalBytes = totalDownloadedBytes(from: recordMap)
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
                        let record = recordMap[row.chapter.id]
                        let isCurrent = (row.physicalIndex == playback.currentChapterIndex)
                        ChapterListRow(
                            row: row,
                            isCurrent: isCurrent,
                            isPlaying: playback.state.isPlaying,
                            record: record,
                            isLast: row.id == rows.last?.id,
                            onSelect: { handleSelectRow(row, isCurrent: isCurrent) },
                            onDownload: { enqueueSingleChapter(row.chapter) }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(row.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let record, record.state == .completed {
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
}
