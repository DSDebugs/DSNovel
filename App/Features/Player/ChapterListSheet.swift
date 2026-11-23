import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 弹窗 1：章节目录（1:1 复刻 v2.8：100 章分段菜单 + 已下载筛选 + 正/倒序 + 搜索 + 右上定位当前）
struct ChapterListSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var model = PlayerChapterListModel()
    @State private var showSearchField = false
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

    private func downloadedChapterIDsForCurrentBook() -> Set<String> {
        guard let bookID = playback.currentBook?.id else { return [] }
        var ids = Set<String>()
        for rec in downloads.manualRecords where rec.bookID == bookID && rec.state == .completed {
            ids.insert(rec.chapterID)
        }
        return ids
    }

    var body: some View {
        let downloadedIDs = downloadedChapterIDsForCurrentBook()
        let segments = PlayerChapterListModel.segments(for: playback.chapters.count)
        let rows = model.displayedRows(from: playback.chapters, downloadedChapterIDs: downloadedIDs, useSegments: true)

        DSSheetScaffold(title: "章节目录（共 \(playback.chapters.count) 章）", banner: banner, onDismiss: onDismiss) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    controlBar(segments: segments, downloadedCount: downloadedIDs.count)

                    if showSearchField {
                        DSClearableSearchField("搜索章节号或标题关键词", text: $model.keyword)
                            .padding(.horizontal, DSSpacing.pageHorizontal)
                            .padding(.bottom, DSSpacing.xs)
                    }

                    if rows.isEmpty {
                        DSStateView(
                            icon: playback.chapters.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                            title: playback.chapters.isEmpty ? "暂无可播放章节" : "未找到匹配章节",
                            message: playback.chapters.isEmpty ? "当前书籍尚未加载章节目录。" : "可清空关键词或切换筛选条件查看全部章节。",
                            actionTitle: playback.chapters.isEmpty ? nil : "重置筛选",
                            action: playback.chapters.isEmpty ? nil : {
                                model.keyword = ""
                                model.onlyDownloaded = false
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(rows) { row in
                            chapterRow(row: row, isDownloaded: downloadedIDs.contains(row.chapter.id))
                                .listRowBackground(DSColors.surfaceCard)
                                .id(row.id)
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .background(DSColors.surfaceGrouped)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            locateCurrentChapter(segments: segments)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                Text("定位当前")
                            }
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                        }
                        .disabled(playback.currentChapter == nil)
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
                    withAnimation(DSMotion.snappy) {
                        proxy.scrollTo(currentID, anchor: .center)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func controlBar(segments: [ChapterSegmentRange], downloadedCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.xs) {
                Button {
                    DSHaptics.selection()
                    withAnimation(DSMotion.snappy) {
                        model.onlyDownloaded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.onlyDownloaded ? "checkmark.circle.fill" : "checkmark.circle")
                        Text(downloadedCount > 0 ? "已下载 (\(downloadedCount))" : "已下载")
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(model.onlyDownloaded ? DSColors.onAccent : DSColors.inkPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(model.onlyDownloaded ? DSColors.accent : DSColors.surfaceCard))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if segments.count > 1 && !model.onlyDownloaded {
                    segmentMenu(segments: segments, downloadedCount: downloadedCount)
                }

                Button {
                    DSHaptics.selection()
                    model.isDescending.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.isDescending ? "arrow.down.to.line" : "arrow.up.arrow.down")
                        Text(model.isDescending ? "倒序" : "正序")
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(DSColors.inkPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DSColors.surfaceCard))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    DSHaptics.selection()
                    showSearchField.toggle()
                    if !showSearchField { model.keyword = "" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索")
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(showSearchField ? DSColors.accent : DSColors.inkPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(showSearchField ? DSColors.accent.opacity(0.16) : DSColors.surfaceCard))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    onOpenBatchDownload()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.to.line.circle.fill")
                        Text("批量下载")
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DSColors.accent.opacity(0.16)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.vertical, DSSpacing.xxs)
        }
    }

    private func segmentMenu(segments: [ChapterSegmentRange], downloadedCount: Int) -> some View {
        let currentLabel = segments.indices.contains(model.selectedSegmentIndex)
            ? segments[model.selectedSegmentIndex].label
            : "1–100"
        return Menu {
            Button {
                model.onlyDownloaded = true
            } label: {
                Label("已下载章节（\(downloadedCount) 章）", systemImage: "checkmark.circle")
            }
            Divider()
            ForEach(segments) { seg in
                Button {
                    model.onlyDownloaded = false
                    model.selectedSegmentIndex = seg.index
                } label: {
                    HStack {
                        Text("第 \(seg.label) 章")
                        if seg.index == model.selectedSegmentIndex && !model.onlyDownloaded {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                Text("第 \(currentLabel) 章")
                Image(systemName: "chevron.down")
                    .font(DSTypography.caption2)
            }
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(DSColors.accent)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 6)
            .background(Capsule().fill(DSColors.accent.opacity(0.16)))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private func chapterRow(row: IndexedChapterRow, isDownloaded: Bool) -> some View {
        let isCurrent = (row.physicalIndex == playback.currentChapterIndex)
        return Button {
            DSHaptics.selection()
            if let book = playback.currentBook {
                playback.play(book: book, chapters: playback.chapters, startIndex: row.physicalIndex, autoPlay: true)
            }
            onDismiss()
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text("\(row.physicalIndex + 1)")
                    .font(DSTypography.numericCaption)
                    .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkSecondary)
                    .frame(minWidth: 32, alignment: .leading)

                Text(row.chapter.title)
                    .font(DSTypography.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? DSColors.accent : DSColors.inkPrimary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.success)
                }
                if isCurrent {
                    DSEqualizer(isPlaying: playback.state.isPlaying)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
