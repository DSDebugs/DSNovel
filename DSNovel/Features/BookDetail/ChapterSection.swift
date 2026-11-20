import SwiftUI

struct ChapterSection: View {
    let totalCount: Int
    let downloadedCount: Int
    let activeDownloadCount: Int
    let failedDownloadCount: Int
    let downloadedBytesText: String
    let segments: [ChapterSegmentItem]
    @Binding var selectedSegmentIndex: Int
    @Binding var isShowingDownloadedOnly: Bool
    @Binding var isAscending: Bool
    @Binding var searchKeyword: String
    @Binding var showInlineSearch: Bool
    let snapshots: [ChapterRowSnapshot]
    private let onLocateCurrent: () -> Void
    private let onSelectSnapshot: (ChapterRowSnapshot) -> Void
    private let onDownloadAction: (ChapterRowSnapshot) -> Void
    private let onRetryAllFailed: () -> Void
    private let onClearAllDownloads: () -> Void
    private let onDownloadNext10: () -> Void
    private let onToggleFinished: (ChapterRowSnapshot) -> Void
    private let onCopyTitle: (ChapterRowSnapshot) -> Void

    init(
        totalCount: Int,
        downloadedCount: Int = 0,
        activeDownloadCount: Int = 0,
        failedDownloadCount: Int = 0,
        downloadedBytesText: String = "",
        segments: [ChapterSegmentItem],
        selectedSegmentIndex: Binding<Int>,
        isShowingDownloadedOnly: Binding<Bool> = .constant(false),
        isAscending: Binding<Bool>,
        searchKeyword: Binding<String>,
        showInlineSearch: Binding<Bool>,
        snapshots: [ChapterRowSnapshot],
        onLocateCurrent: @escaping () -> Void,
        onSelectSnapshot: @escaping (ChapterRowSnapshot) -> Void,
        onDownloadAction: @escaping (ChapterRowSnapshot) -> Void,
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
        self.downloadedBytesText = downloadedBytesText
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
        self.onRetryAllFailed = onRetryAllFailed
        self.onClearAllDownloads = onClearAllDownloads
        self.onDownloadNext10 = onDownloadNext10
        self.onToggleFinished = onToggleFinished
        self.onCopyTitle = onCopyTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            headerTitleAndToolsRow
            modeAndSegmentControlRow

            if showInlineSearch {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
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
                .padding(.horizontal, Spacing.s3)
                .frame(minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                        .fill(Color.dsSurfaceGrouped)
                )
                .padding(.horizontal, Spacing.pageHorizontal)
            }

            if isShowingDownloadedOnly {
                downloadedStatusBanners
            }

            if snapshots.isEmpty {
                emptyChaptersStateView
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(snapshots) { snap in
                        ChapterRow(
                            snapshot: snap,
                            onSelect: { onSelectSnapshot(snap) },
                            onDownloadAction: { onDownloadAction(snap) }
                        )
                        .equatable()
                        .id(snap.id)
                        .contextMenu {
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
                    }
                }
            }
        }
    }

    // MARK: - 1. 章节标题与右侧工具栏（排序 / 搜索 / 定位当前章节）

    private var headerTitleAndToolsRow: some View {
        HStack(spacing: Spacing.s1) {
            Text(isShowingDownloadedOnly ? "已下载章节" : "章节目录")
                .font(DSTypography.sectionHeader)
                .foregroundStyle(.primary)

            Text(isShowingDownloadedOnly ? "\(downloadedCount) 章" : "\(totalCount) 章")
                .font(DSTypography.numericFootnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                DSHapticPolicy.fire(.selection)
                isAscending.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.dsSurfaceGrouped))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换正序倒序，当前为\(isAscending ? "正序" : "倒序")")

            Button {
                DSHapticPolicy.fire(.selection)
                showInlineSearch.toggle()
                if !showInlineSearch {
                    searchKeyword = ""
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(showInlineSearch ? Color.dsAccent : .primary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(showInlineSearch ? Color.dsAccent.opacity(0.15) : Color.dsSurfaceGrouped)
                    )
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索章节")

            Button(action: onLocateCurrent) {
                HStack(spacing: 3) {
                    Image(systemName: "scope")
                    Text("定位")
                }
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
                .padding(.horizontal, Spacing.s3)
                .frame(minHeight: 34)
                .background(Capsule().fill(Color.dsAccent.opacity(0.14)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定位当前播放章节")
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    // MARK: - 2. 「已下载章节」与「全部章节分段」双模切换栏

    private var modeAndSegmentControlRow: some View {
        HStack(spacing: Spacing.s3) {
            modeSegmentedControl

            // 区间菜单只在「全部」模式下出现；「已下载」模式下换成清空入口
            if !isShowingDownloadedOnly, segments.count > 1 {
                BookChapterSegmentMenu(
                    segments: segments,
                    selectedSegmentIndex: selectedSegmentIndex,
                    onSelectSegment: { idx in
                        DSHapticPolicy.fire(.selection)
                        withAnimation(Motion.snappy) {
                            selectedSegmentIndex = idx
                        }
                    }
                )
                .equatable()
            }

            if isShowingDownloadedOnly && downloadedCount > 0 {
                Button(role: .destructive, action: onClearAllDownloads) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("清空已下")
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.s3)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    /// 「全部 | 已下载」分段控件：只表达筛选模式，区间另由菜单负责
    private var modeSegmentedControl: some View {
        HStack(spacing: 0) {
            modeSegment(title: "全部", isSelected: !isShowingDownloadedOnly) {
                isShowingDownloadedOnly = false
            }
            modeSegment(
                title: downloadedCount > 0 ? "已下载 \(downloadedCount)" : "已下载",
                isSelected: isShowingDownloadedOnly
            ) {
                isShowingDownloadedOnly = true
            }
            .accessibilityLabel("已下载章节，共 \(downloadedCount) 章")
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.dsSurfaceGrouped))
    }

    private func modeSegment(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !isSelected else { return }
            DSHapticPolicy.fire(.selection)
            withAnimation(Motion.snappy) { action() }
        } label: {
            Text(verbatim: title)
                .font(DSTypography.numericCaption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.dsOnAccent : .primary)
                .padding(.horizontal, Spacing.s4)
                .frame(minHeight: 30)
                .background(Capsule(style: .continuous).fill(isSelected ? Color.dsAccent : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 优先展示已下载章节提示条与状态反馈横幅

    @ViewBuilder
    private var downloadedStatusBanners: some View {
        VStack(spacing: Spacing.s2) {
            if activeDownloadCount > 0 {
                HStack(spacing: Spacing.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在后台下载 \(activeDownloadCount) 章离线音频…")
                        .font(DSTypography.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                        .fill(Color.dsAccent.opacity(0.10))
                )
            }

            if failedDownloadCount > 0 {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("\(failedDownloadCount) 章下载失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    Button("全部重试", action: onRetryAllFailed)
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsOnAccent)
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.dsAccent))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                        .fill(Color.red.opacity(0.10))
                )
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    @ViewBuilder
    private var emptyChaptersStateView: some View {
        if isShowingDownloadedOnly {
            VStack(spacing: Spacing.s3) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("暂无已下载章节")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.primary)
                Text("下载章节后将在此优先展示，支持离线收听与空间管理")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Spacing.s3) {
                    Button(action: onDownloadNext10) {
                        Text("下载后续 10 章")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(Color.dsOnAccent)
                            .padding(.horizontal, Spacing.s4)
                            .padding(.vertical, Spacing.s2)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.dsAccent))
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingDownloadedOnly = false
                    } label: {
                        Text("浏览全部章节")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Spacing.s4)
                            .padding(.vertical, Spacing.s2)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.dsSurfaceGrouped))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.s6)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: Spacing.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("未找到匹配的章节")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.primary)
                if !searchKeyword.isEmpty {
                    Button("清除搜索词") {
                        searchKeyword = ""
                    }
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(Color.dsAccent)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.s6)
            .frame(maxWidth: .infinity)
        }
    }
}


private struct BookChapterSegmentMenu: View, Equatable {
    let segments: [ChapterSegmentItem]
    let selectedSegmentIndex: Int
    let onSelectSegment: (Int) -> Void

    init(
        segments: [ChapterSegmentItem],
        selectedSegmentIndex: Int,
        onSelectSegment: @escaping (Int) -> Void
    ) {
        self.segments = segments
        self.selectedSegmentIndex = selectedSegmentIndex
        self.onSelectSegment = onSelectSegment
    }

    static func == (lhs: BookChapterSegmentMenu, rhs: BookChapterSegmentMenu) -> Bool {
        lhs.segments == rhs.segments
            && lhs.selectedSegmentIndex == rhs.selectedSegmentIndex
    }

    var body: some View {
        Menu {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                Button {
                    onSelectSegment(idx)
                } label: {
                    HStack {
                        Text("第 \(seg.label) 章")
                        if idx == selectedSegmentIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            let segLabel = segments.indices.contains(selectedSegmentIndex)
                ? segments[selectedSegmentIndex].label
                : "1–100"
            HStack(spacing: 4) {
                Text("第 \(segLabel) 章")
                    .font(DSTypography.numericCaption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(DSTypography.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Spacing.s3)
            .frame(minHeight: 34)
            .background(Capsule(style: .continuous).fill(Color.dsSurfaceGrouped))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("切换章节区间")
    }
}
