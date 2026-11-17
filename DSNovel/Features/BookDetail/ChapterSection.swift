import SwiftUI

struct ChapterSection: View {
    let totalCount: Int
    let segments: [ChapterSegmentItem]
    @Binding var selectedSegmentIndex: Int
    @Binding var isAscending: Bool
    @Binding var searchKeyword: String
    @Binding var showInlineSearch: Bool
    let snapshots: [ChapterRowSnapshot]
    private let onLocateCurrent: () -> Void
    private let onSelectSnapshot: (ChapterRowSnapshot) -> Void
    private let onDownloadAction: (ChapterRowSnapshot) -> Void
    private let onToggleFinished: (ChapterRowSnapshot) -> Void
    private let onCopyTitle: (ChapterRowSnapshot) -> Void

    init(
        totalCount: Int,
        segments: [ChapterSegmentItem],
        selectedSegmentIndex: Binding<Int>,
        isAscending: Binding<Bool>,
        searchKeyword: Binding<String>,
        showInlineSearch: Binding<Bool>,
        snapshots: [ChapterRowSnapshot],
        onLocateCurrent: @escaping () -> Void,
        onSelectSnapshot: @escaping (ChapterRowSnapshot) -> Void,
        onDownloadAction: @escaping (ChapterRowSnapshot) -> Void,
        onToggleFinished: @escaping (ChapterRowSnapshot) -> Void,
        onCopyTitle: @escaping (ChapterRowSnapshot) -> Void
    ) {
        self.totalCount = totalCount
        self.segments = segments
        self._selectedSegmentIndex = selectedSegmentIndex
        self._isAscending = isAscending
        self._searchKeyword = searchKeyword
        self._showInlineSearch = showInlineSearch
        self.snapshots = snapshots
        self.onLocateCurrent = onLocateCurrent
        self.onSelectSnapshot = onSelectSnapshot
        self.onDownloadAction = onDownloadAction
        self.onToggleFinished = onToggleFinished
        self.onCopyTitle = onCopyTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack {
                Text("章节 · 共 \(totalCount)")
                    .font(DSTypography.sectionHeader)
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    isAscending.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换正序倒序")

                if segments.count > 1 {
                    Menu {
                        Picker("章节区间", selection: $selectedSegmentIndex) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                                Text(seg.label).tag(idx)
                            }
                        }
                    } label: {
                        Text(segments.indices.contains(selectedSegmentIndex) ? segments[selectedSegmentIndex].label : "区间")
                            .font(DSTypography.numericCaption)
                            .padding(.horizontal, Spacing.s2)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.dsSurfaceGrouped))
                    }
                }

                Button {
                    showInlineSearch.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索章节")

                Button(action: onLocateCurrent) {
                    Image(systemName: "scope")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("定位当前章节")
            }
            .padding(.horizontal, Spacing.pageHorizontal)

            if showInlineSearch {
                TextField("搜索章节标题…", text: $searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, Spacing.pageHorizontal)
            }

            LazyVStack(spacing: 0) {
                ForEach(snapshots) { snap in
                    ChapterRow(
                        snapshot: snap,
                        onSelect: { onSelectSnapshot(snap) },
                        onDownloadAction: { onDownloadAction(snap) }
                    )
                    .equatable()
                    .id(snap.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            onDownloadAction(snap)
                        } label: {
                            Label(snap.downloadState == .completed ? "删除下载" : "下载", systemImage: "arrow.down.circle")
                        }
                        .tint(Color.dsAccent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            onToggleFinished(snap)
                        } label: {
                            Label(snap.isFinished ? "标为未听" : "标为已听", systemImage: "checkmark.circle")
                        }
                    }
                    .contextMenu {
                        Button("从此处连续播放") { onSelectSnapshot(snap) }
                        Button("下载此章") { onDownloadAction(snap) }
                        Button("复制标题") { onCopyTitle(snap) }
                    }
                }
            }
        }
    }
}
