import SwiftUI

struct ChapterListView: View {
    let book: BookRef?
    let chapters: [ChapterDTO]
    let currentChapterID: String?
    let isPlaying: Bool
    private let onSelectChapter: (ChapterDTO) -> Void
    private let onOpenBatchDownload: () -> Void
    private let onClose: () -> Void

    @State private var browserModel: BookDetailModel
    @State private var listModel: PlayerChapterListModel
    @State private var downloadManager = DownloadManager.shared
    @State private var player = PlayerEngine.shared
    @State private var showSearchField: Bool = false
    @State private var pendingDeleteSnapshot: ChapterRowSnapshot?
    @FocusState private var isSearchFocused: Bool

    init(
        book: BookRef? = nil,
        chapters: [ChapterDTO],
        currentChapterID: String?,
        isPlaying: Bool,
        onSelectChapter: @escaping (ChapterDTO) -> Void,
        onOpenBatchDownload: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        let fallbackBook = book ?? BookRef(
            sourceID: "local",
            bookURL: "local",
            title: "有声书",
            chapterCount: chapters.count
        )
        self.book = book
        self.chapters = chapters
        self.currentChapterID = currentChapterID
        self.isPlaying = isPlaying
        self.onSelectChapter = onSelectChapter
        self.onOpenBatchDownload = onOpenBatchDownload
        self.onClose = onClose

        let model = BookDetailModel(book: fallbackBook)
        model.applyChapters(chapters)
        if let segIdx = PlayerChapterListModel.segmentIndex(for: currentChapterID, in: chapters, pageSize: 100),
           model.segments.indices.contains(segIdx) {
            model.selectedSegmentIndex = segIdx
        }
        self._browserModel = State(initialValue: model)
        self._listModel = State(
            initialValue: PlayerChapterListModel(
                book: fallbackBook,
                chapters: chapters,
                currentChapterID: currentChapterID
            )
        )
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let livePosMs: Int? = nil
        let snapshots = listModel.visibleSnapshots(
            from: browserModel,
            isPlaying: isPlaying,
            currentPlayingPositionMs: livePosMs
        )
        let downloadedCount = downloadManager.summariesByBookID[listModel.book.id]?.completedCount ?? 0

        DSSheetScaffold(title: "章节目录（共 \(chapters.count) 章）", onClose: onClose) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    controlBar(proxy: proxy, downloadedCount: downloadedCount)

                    if showSearchField {
                        DSSearchField(
                            text: $browserModel.chapterSearchKeyword,
                            isFocused: $isSearchFocused,
                            prompt: "搜索章节号或标题关键词"
                        )
                        .padding(.bottom, Spacing.s2)
                    }

                    if snapshots.isEmpty {
                        Spacer()
                        DSStateView(
                            kind: .empty,
                            onPrimary: {
                                browserModel.chapterSearchKeyword = ""
                                listModel.onlyDownloadedFilter = false
                            },
                            onSecondary: nil
                        )
                        Spacer()
                    } else {
                        List(snapshots) { snap in
                            let chapterAccessibilityLabel = "第 \(snap.displayIndex) 章，\(snap.chapter.title)"
                            ChapterRow(
                                snapshot: snap,
                                onSelect: {
                                    DSHapticPolicy.fire(.chapterSwitch)
                                    onSelectChapter(snap.chapter)
                                    onClose()
                                },
                                onDownloadAction: {
                                    let realState = downloadManager.downloadState(
                                        bookID: listModel.book.id,
                                        chapterID: snap.chapter.id
                                    )
                                    if realState == .completed {
                                        pendingDeleteSnapshot = snap
                                    } else {
                                        listModel.startOrRetryDownload(snap)
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.dsSurfaceCard)
                            .id(snap.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(chapterAccessibilityLabel)
                            .accessibilityValue(accessibilityDownloadDescription(for: snap))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .background(Color.dsSurfaceGrouped)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            locateCurrentChapter(proxy: proxy)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                Text("定位当前")
                            }
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                        }
                    }
                }
                .alert(
                    pendingDeleteSnapshot.map { "确认删除「\($0.chapter.title)」的离线音频文件？" } ?? "确认删除该章离线文件？",
                    isPresented: Binding(
                        get: { pendingDeleteSnapshot != nil },
                        set: { if !$0 { pendingDeleteSnapshot = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("删除离线文件", role: .destructive) {
                        if let snap = pendingDeleteSnapshot {
                            listModel.confirmDeleteDownload(snap)
                        }
                        pendingDeleteSnapshot = nil
                    }
                    Button("取消", role: .cancel) {
                        pendingDeleteSnapshot = nil
                    }
                } message: {
                    Text("删除后将释放本地空间，再次收听该章需联网或重新下载。")
                }
                .onAppear {
                    listModel.reloadDownloadMap()
                    if let currentChapterID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(Motion.snappy) {
                                proxy.scrollTo(currentChapterID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func controlBar(proxy: ScrollViewProxy, downloadedCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s2) {
                Button {
                    DSHapticPolicy.fire(.selection)
                    withAnimation(Motion.snappy) {
                        listModel.onlyDownloadedFilter.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: listModel.onlyDownloadedFilter ? "checkmark.circle.fill" : "checkmark.circle")
                        Text(downloadedCount > 0 ? "已下载章节 (\(downloadedCount))" : "已下载章节")
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(listModel.onlyDownloadedFilter ? Color.dsOnAccent : .primary)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(listModel.onlyDownloadedFilter ? Color.dsAccent : Color.dsSurfaceCard)
                    )
                }
                .buttonStyle(.plain)

                if browserModel.segments.count > 1 && !listModel.onlyDownloadedFilter {
                    PlayerChapterSegmentMenu(
                        segments: browserModel.segments,
                        selectedSegmentIndex: browserModel.selectedSegmentIndex,
                        onlyDownloadedFilter: listModel.onlyDownloadedFilter,
                        downloadedCount: downloadedCount,
                        onSelectDownloadedOnly: {
                            withAnimation(Motion.snappy) {
                                listModel.onlyDownloadedFilter = true
                            }
                        },
                        onSelectSegment: { idx in
                            withAnimation(Motion.snappy) {
                                listModel.onlyDownloadedFilter = false
                                browserModel.selectedSegmentIndex = idx
                            }
                        }
                    )
                    .equatable()
                }

                Button {
                    DSHapticPolicy.fire(.selection)
                    browserModel.isAscending.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: browserModel.isAscending ? "arrow.up.arrow.down" : "arrow.down.to.line")
                        Text(browserModel.isAscending ? "正序" : "倒序")
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.dsSurfaceCard))
                }
                .buttonStyle(.plain)

                Button {
                    DSHapticPolicy.fire(.selection)
                    showSearchField.toggle()
                    if !showSearchField {
                        browserModel.chapterSearchKeyword = ""
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索")
                    }
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(showSearchField ? Color.dsAccent : .primary)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(showSearchField ? Color.dsAccent.opacity(0.16) : Color.dsSurfaceCard)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    onClose()
                    onOpenBatchDownload()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.to.line.circle.fill")
                        Text("批量下载")
                    }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.dsAccent.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.pageHorizontal)
            .padding(.vertical, Spacing.s2)
        }
    }

    private func locateCurrentChapter(proxy: ScrollViewProxy) {
        guard let currentChapterID else { return }
        DSHapticPolicy.fire(.selection)
        browserModel.chapterSearchKeyword = ""
        listModel.onlyDownloadedFilter = false
        if let segIdx = PlayerChapterListModel.segmentIndex(for: currentChapterID, in: chapters, pageSize: 100),
           browserModel.segments.indices.contains(segIdx) {
            browserModel.selectedSegmentIndex = segIdx
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(Motion.snappy) {
                proxy.scrollTo(currentChapterID, anchor: .center)
            }
        }
    }

    private func accessibilityDownloadDescription(for snap: ChapterRowSnapshot) -> String {
        switch snap.downloadState {
        case .notDownloaded: return "未下载"
        case .downloading(let p): return "正在下载 \(Int((p * 100).rounded()))%"
        case .completed: return "已离线下载"
        case .failed: return "下载失败，可点击重试"
        }
    }
}


private struct PlayerChapterSegmentMenu: View, Equatable {
    let segments: [ChapterSegmentItem]
    let selectedSegmentIndex: Int
    let onlyDownloadedFilter: Bool
    let downloadedCount: Int
    let onSelectDownloadedOnly: () -> Void
    let onSelectSegment: (Int) -> Void

    static func == (lhs: PlayerChapterSegmentMenu, rhs: PlayerChapterSegmentMenu) -> Bool {
        lhs.segments == rhs.segments
            && lhs.selectedSegmentIndex == rhs.selectedSegmentIndex
            && lhs.onlyDownloadedFilter == rhs.onlyDownloadedFilter
            && lhs.downloadedCount == rhs.downloadedCount
    }

    var body: some View {
        Menu {
            Button(action: onSelectDownloadedOnly) {
                Label("已下载章节（\(downloadedCount) 章）", systemImage: "checkmark.circle")
            }
            Divider()
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                Button {
                    onSelectSegment(idx)
                } label: {
                    HStack {
                        Text("第 \(seg.label) 章")
                        if idx == selectedSegmentIndex && !onlyDownloadedFilter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            let currentLabel = segments.indices.contains(selectedSegmentIndex)
                ? segments[selectedSegmentIndex].label
                : "1–100"
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                Text("第 \(currentLabel) 章")
                Image(systemName: "chevron.down")
                    .font(DSTypography.caption2)
            }
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(Color.dsAccent)
            .padding(.horizontal, Spacing.s3)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.dsAccent.opacity(0.16)))
        }
    }
}
