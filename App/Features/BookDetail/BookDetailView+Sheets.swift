import UIKit
import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 自定义区间批量下载弹窗（1:1 复刻 v2.8：默认起点为当前播放章、终点 +29、快捷按钮含「后 50 章/后 100 章/后续全部/全部」、数字输入框 + Stepper）
struct RangeDownloadSheet: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppContainer.self) private var container
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    private let book: BookSummaryDTO
    private let chapters: [ChapterDTO]
    private let currentChapterIndex: Int
    private let onDismiss: () -> Void

    /// 0-based 起始与结束下标
    @State private var startIndex: Int
    @State private var endIndex: Int
    /// 1-based 数字输入展示值
    @State private var startChapterInput: Int
    @State private var endChapterInput: Int
    @State private var isEnqueuing = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case start
        case end
    }

    init(
        book: BookSummaryDTO,
        chapters: [ChapterDTO],
        currentChapterIndex: Int = 0,
        onDismiss: @escaping () -> Void
    ) {
        self.book = book
        self.chapters = chapters
        let maxIdx = max(0, chapters.count - 1)
        let safeStart = min(max(0, currentChapterIndex), maxIdx)
        let safeEnd = min(maxIdx, safeStart + 29)
        self.currentChapterIndex = safeStart
        self.onDismiss = onDismiss
        _startIndex = State(initialValue: safeStart)
        _endIndex = State(initialValue: safeEnd)
        _startChapterInput = State(initialValue: safeStart + 1)
        _endChapterInput = State(initialValue: safeEnd + 1)
    }

    private var totalChapters: Int { max(1, chapters.count) }

    private func applyRange(startZeroBased: Int, endZeroBased: Int) {
        let maxIdx = max(0, chapters.count - 1)
        let clampedStart = min(max(0, startZeroBased), maxIdx)
        let clampedEnd = min(max(clampedStart, endZeroBased), maxIdx)
        startIndex = clampedStart
        endIndex = clampedEnd
        startChapterInput = clampedStart + 1
        endChapterInput = clampedEnd + 1
        focusedField = nil
        DSHaptics.selection()
    }

    private func normalizeInputs() {
        let maxIdx = max(0, chapters.count - 1)
        let clampedStart = min(max(0, startChapterInput - 1), maxIdx)
        let clampedEnd = min(max(clampedStart, endChapterInput - 1), maxIdx)
        startIndex = clampedStart
        endIndex = clampedEnd
        if startChapterInput != clampedStart + 1 { startChapterInput = clampedStart + 1 }
        if endChapterInput != clampedEnd + 1 { endChapterInput = clampedEnd + 1 }
    }

    var body: some View {
        DSSheetScaffold(title: "自定义区间下载", banner: banner, onDismiss: onDismiss) {
            Form {
                if chapters.isEmpty {
                    Section {
                        Text("暂无可下载章节，请先返回刷新目录。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }

                Section("快捷区间（共 \(chapters.count) 章）") {
                    HStack(spacing: DSSpacing.xs) {
                        presetButton(title: "后 50 章") {
                            applyRange(startZeroBased: currentChapterIndex, endZeroBased: currentChapterIndex + 49)
                        }
                        presetButton(title: "后 100 章") {
                            applyRange(startZeroBased: currentChapterIndex, endZeroBased: currentChapterIndex + 99)
                        }
                        presetButton(title: "后续全部") {
                            applyRange(startZeroBased: currentChapterIndex, endZeroBased: max(0, chapters.count - 1))
                        }
                        presetButton(title: "全部") {
                            applyRange(startZeroBased: 0, endZeroBased: max(0, chapters.count - 1))
                        }
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }

                Section("选择章节范围（1 – \(totalChapters)）") {
                    rangeInputRow(
                        label: "起始章",
                        value: $startChapterInput,
                        field: .start,
                        range: 1...totalChapters
                    )
                    rangeInputRow(
                        label: "结束章",
                        value: $endChapterInput,
                        field: .end,
                        range: 1...totalChapters
                    )
                }

                Section {
                    let safeStart = min(max(0, startIndex), max(0, chapters.count - 1))
                    let safeEnd = min(max(safeStart, endIndex), max(0, chapters.count - 1))
                    let count = chapters.isEmpty ? 0 : (safeEnd - safeStart + 1)
                    DSActionButton(
                        title: isEnqueuing ? "正在加入队列…" : "下载第 \(safeStart + 1)–\(safeEnd + 1) 章（共 \(count) 章）",
                        icon: "arrow.down.circle.fill",
                        role: isEnqueuing ? .loading : .primary
                    ) {
                        confirmDownload()
                    }
                    .disabled(chapters.isEmpty || isEnqueuing)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                        normalizeInputs()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: focusedField) { _, newField in
                if newField == nil { normalizeInputs() }
            }
            .onChange(of: startChapterInput) { _, _ in
                if focusedField == nil { normalizeInputs() }
            }
            .onChange(of: endChapterInput) { _, _ in
                if focusedField == nil { normalizeInputs() }
            }
        }
    }

    private func rangeInputRow(
        label: String,
        value: Binding<Int>,
        field: Field,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: DSSpacing.xs) {
            Text(label)
                .font(DSTypography.body)
            TextField("\(range.lowerBound)", value: value, format: .number)
                .focused($focusedField, equals: field)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(DSTypography.numericCaption.weight(.semibold))
                .frame(width: 72)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                        .fill(DSColors.surfaceGrouped)
                )
            Spacer()
            Stepper("", value: value, in: range)
                .labelsHidden()
                .disabled(chapters.isEmpty || isEnqueuing)
        }
        .frame(minHeight: 44)
        .listRowBackground(DSColors.surfaceCard)
    }

    private func presetButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(DSColors.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.horizontal, DSSpacing.xxs)
                .background(Capsule(style: .continuous).fill(DSColors.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(chapters.isEmpty || isEnqueuing)
    }

    private func confirmDownload() {
        focusedField = nil
        normalizeInputs()
        guard !isEnqueuing,
              !chapters.isEmpty,
              startIndex >= 0,
              startIndex <= endIndex,
              endIndex < chapters.count else { return }
        isEnqueuing = true
        let slice = Array(chapters[startIndex...endIndex])
        Task {
            defer { isEnqueuing = false }
            await downloads.enqueueManual(book: book, chapters: slice, quality: container.resolvedQuality(for: book))
            banner.show("已添加 \(slice.count) 章至下载队列", tone: .success)
            onDismiss()
        }
    }

    @ViewBuilder
    func chapterArea(
        proxy: ScrollViewProxy,
        dlOverview: BookDownloadOverview,
        snapshots: [ChapterRowSnapshot]
    ) -> some View {
        if isLoading && chapters.isEmpty {
            DSSkeleton(mode: .chapters(rows: 8))
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else if let err = errorMessage, chapters.isEmpty {
            DSStateView(
                kind: .error(detail: err),
                onPrimary: { Task { await loadDetail(forceRemote: true) } },
                onSecondary: { router.push(.sourceDetail(sourceID: currentBook.sourceID)) }
            )
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else {
            ChapterSection(
                totalCount: chapters.count,
                downloadedCount: dlOverview.completedCount,
                activeDownloadCount: dlOverview.activeCount,
                failedDownloadCount: dlOverview.failedCount,
                segments: segments,
                selectedSegmentIndex: $selectedSegmentIndex,
                isShowingDownloadedOnly: $isShowingDownloadedOnly,
                isAscending: $isAscending,
                searchKeyword: $searchKeyword,
                showInlineSearch: $showInlineSearch,
                snapshots: snapshots,
                onLocateCurrent: { locateCurrentChapter(proxy: proxy) },
                onSelectSnapshot: { snap in handleChapterSelect(snap) },
                onDownloadAction: { snap in handleChapterDownloadTap(snap) },
                onSwipeDelete: { snap in handleChapterSwipeDelete(snap) },
                onRetryAllFailed: { Task { await retryFailedForBook(dlOverview) } },
                onClearAllDownloads: { showClearAllDownloadsConfirm = true },
                onDownloadNext10: {
                    let s = max(0, activeChapterIndex ?? 0)
                    enqueueRange(startZeroBased: s, endZeroBased: min(max(0, chapters.count - 1), s + 9))
                },
                onToggleFinished: { snap in
                    if finishedIndices.contains(snap.arrayIndex) {
                        finishedIndices.remove(snap.arrayIndex)
                    } else {
                        finishedIndices.insert(snap.arrayIndex)
                    }
                },
                onCopyTitle: { snap in
                    UIPasteboard.general.string = snap.chapter.title
                    banner.show("已复制章节标题", tone: .info)
                }
            )
        }
    }
}
