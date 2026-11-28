import DSDesignSystem
import SwiftUI

/// 章节目录区（1:1 复刻 v2.8：标题工具行 + 全部/已下载双模胶囊 + 100 章分段 Menu + 内联搜索 + 长按菜单）
struct ChapterSection: View {
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.dsReduceMotion) var appReduceMotion

    let totalCount: Int
    let downloadedCount: Int
    let activeDownloadCount: Int
    let failedDownloadCount: Int
    let segments: [ChapterSegmentItem]
    @Binding var selectedSegmentIndex: Int
    @Binding var isShowingDownloadedOnly: Bool
    @Binding var isAscending: Bool
    @Binding var searchKeyword: String
    @Binding var showInlineSearch: Bool
    let snapshots: [ChapterRowSnapshot]
    let onLocateCurrent: () -> Void
    let onSelectSnapshot: (ChapterRowSnapshot) -> Void
    let onDownloadAction: (ChapterRowSnapshot) -> Void
    let onSwipeDelete: (ChapterRowSnapshot) -> Void
    let onRetryAllFailed: () -> Void
    let onClearAllDownloads: () -> Void
    let onDownloadNext10: () -> Void
    let onToggleFinished: (ChapterRowSnapshot) -> Void
    let onCopyTitle: (ChapterRowSnapshot) -> Void

    var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    init(
        totalCount: Int,
        downloadedCount: Int = 0,
        activeDownloadCount: Int = 0,
        failedDownloadCount: Int = 0,
        segments: [ChapterSegmentItem],
        selectedSegmentIndex: Binding<Int>,
        isShowingDownloadedOnly: Binding<Bool>,
        isAscending: Binding<Bool>,
        searchKeyword: Binding<String>,
        showInlineSearch: Binding<Bool>,
        snapshots: [ChapterRowSnapshot],
        onLocateCurrent: @escaping () -> Void,
        onSelectSnapshot: @escaping (ChapterRowSnapshot) -> Void,
        onDownloadAction: @escaping (ChapterRowSnapshot) -> Void,
        onSwipeDelete: @escaping (ChapterRowSnapshot) -> Void = { _ in },
        onRetryAllFailed: @escaping () -> Void = {},
        onClearAllDownloads: @escaping () -> Void = {},
        onDownloadNext10: @escaping () -> Void = {},
        onToggleFinished: @escaping (ChapterRowSnapshot) -> Void,
        onCopyTitle: @escaping (ChapterRowSnapshot) -> Void
    ) {
        self.totalCount = totalCount
        self.downloadedCount = downloadedCount
        self.activeDownloadCount = activeDownloadCount
        self.failedDownloadCount = failedDownloadCount
        self.segments = segments
        self._selectedSegmentIndex = selectedSegmentIndex
        self._isShowingDownloadedOnly = isShowingDownloadedOnly
        self._isAscending = isAscending
        self._searchKeyword = searchKeyword
        self._showInlineSearch = showInlineSearch
        self.snapshots = snapshots
        self.onLocateCurrent = onLocateCurrent
        self.onSelectSnapshot = onSelectSnapshot
        self.onDownloadAction = onDownloadAction
        self.onSwipeDelete = onSwipeDelete
        self.onRetryAllFailed = onRetryAllFailed
        self.onClearAllDownloads = onClearAllDownloads
        self.onDownloadNext10 = onDownloadNext10
        self.onToggleFinished = onToggleFinished
        self.onCopyTitle = onCopyTitle
    }

    private var hasDownloadedBanner: Bool {
        isShowingDownloadedOnly && (activeDownloadCount > 0 || failedDownloadCount > 0)
    }

    private var bottomSectionHairline: some View {
        Rectangle()
            .fill(DSColors.separator.opacity(0.28))
            .frame(height: 0.5)
            .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Rectangle()
                .fill(DSColors.separator.opacity(0.26))
                .frame(height: 0.5)
                .padding(.horizontal, DSSpacing.pageHorizontal)

            headerTitleAndToolsRow
            modeAndSegmentControlRow
        }
        .padding(.top, DSSpacing.xxs)
        .padding(.bottom, DSSpacing.xs)
        .overlay(alignment: .bottom) {
            if !showInlineSearch && !hasDownloadedBanner {
                bottomSectionHairline
            }
        }
        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)

        if showInlineSearch {
            inlineSearchBar
                .padding(.bottom, DSSpacing.xs)
                .overlay(alignment: .bottom) {
                    if !hasDownloadedBanner {
                        bottomSectionHairline
                    }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }

        if hasDownloadedBanner {
            downloadedStatusBanners
                .padding(.bottom, DSSpacing.xs)
                .overlay(alignment: .bottom) {
                    bottomSectionHairline
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }

        if snapshots.isEmpty {
            emptyChaptersStateView
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            let indexColWidth = ChapterRow.columnWidth(forMaxIndex: snapshots.reduce(0) { max($0, $1.displayIndex) })
            ForEach(snapshots) { snap in
                ChapterRow(
                    snapshot: snap,
                    indexColumnWidth: indexColWidth,
                    onSelect: { onSelectSnapshot(snap) },
                    onDownloadAction: { onDownloadAction(snap) }
                )
                .equatable()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .id(snap.arrayIndex)
                .contextMenu {
                    chapterContextMenu(for: snap)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if snap.downloadState == .completed {
                        Button(role: .destructive) {
                            onSwipeDelete(snap)
                        } label: {
                            Label("删除离线", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chapterContextMenu(for snap: ChapterRowSnapshot) -> some View {
        Button {
            onSelectSnapshot(snap)
        } label: {
            Label("从此处连续播放", systemImage: "play.fill")
        }
        if snap.downloadState == .completed {
            Button(role: .destructive) {
                onDownloadAction(snap)
            } label: {
                Label("删除离线音频…", systemImage: "trash")
            }
        } else if snap.downloadState == .failed {
            Button {
                onDownloadAction(snap)
            } label: {
                Label("重试下载此章", systemImage: "arrow.clockwise")
            }
        } else {
            Button {
                onDownloadAction(snap)
            } label: {
                Label("下载此章", systemImage: "arrow.down.circle")
            }
        }
        Button {
            onToggleFinished(snap)
        } label: {
            Label(snap.isFinished ? "标为未听" : "标为已听", systemImage: "checkmark.circle")
        }
        Button {
            onCopyTitle(snap)
        } label: {
            Label("复制章节标题", systemImage: "doc.on.doc")
        }
    }

    private var inlineSearchBar: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DSColors.inkSecondary)
            TextField("搜索章节号或标题关键词…", text: $searchKeyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchKeyword.isEmpty {
                Button {
                    searchKeyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索词")
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                .fill(DSColors.surfaceGrouped)
        )
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    private var headerTitleAndToolsRow: some View {
        HStack(spacing: DSSpacing.xxs) {
            Text(isShowingDownloadedOnly ? "已下载章节" : "章节目录")
                .font(DSTypography.sectionHeader)
                .foregroundStyle(DSColors.inkPrimary)

            Text(isShowingDownloadedOnly ? "共 \(downloadedCount) 章" : "共 \(totalCount) 章")
                .font(DSTypography.numericFootnote)
                .foregroundStyle(DSColors.inkSecondary)

            Spacer()

            Button {
                DSHaptics.selection()
                isAscending.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DSColors.surfaceGrouped))
                    .frame(minWidth: 38, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换正序倒序，当前为\(isAscending ? "正序" : "倒序")")

            Button {
                DSHaptics.selection()
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                    showInlineSearch.toggle()
                    if !showInlineSearch { searchKeyword = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(showInlineSearch ? DSColors.accent.opacity(0.18) : DSColors.surfaceGrouped)
                    )
                    .frame(minWidth: 38, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索章节")

            Button(action: onLocateCurrent) {
                Image(systemName: "scope")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DSColors.surfaceGrouped))
                    .frame(minWidth: 38, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定位当前播放章节")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
