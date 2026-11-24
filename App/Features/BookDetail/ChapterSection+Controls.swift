import DSDesignSystem
import SwiftUI

/// 章节区模式切换、100 章区间菜单、已下载提示横幅与空态（拆分自 ChapterSection.swift 以保持 ≤ 385 行）
extension ChapterSection {
    var modeAndSegmentControlRow: some View {
        HStack(spacing: DSSpacing.sm) {
            modeSegmentedControl

            if !isShowingDownloadedOnly, segments.count > 1 {
                BookChapterSegmentMenu(
                    segments: segments,
                    selectedSegmentIndex: selectedSegmentIndex,
                    onSelectSegment: { idx in
                        DSHaptics.selection()
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
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
                    .foregroundStyle(DSColors.danger)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(DSColors.danger.opacity(0.12)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

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
        .background(Capsule(style: .continuous).fill(DSColors.surfaceGrouped))
    }

    private func modeSegment(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !isSelected else { return }
            DSHaptics.selection()
            DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) { action() }
        } label: {
            Text(verbatim: title)
                .font(DSTypography.numericCaption.weight(.semibold))
                .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
                .padding(.horizontal, DSSpacing.md)
                .frame(minHeight: 30)
                .background(Capsule(style: .continuous).fill(isSelected ? DSColors.accent : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var downloadedStatusBanners: some View {
        VStack(spacing: DSSpacing.xs) {
            if activeDownloadCount > 0 {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在后台下载 \(activeDownloadCount) 章离线音频…")
                        .font(DSTypography.caption.weight(.medium))
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer()
                }
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                        .fill(DSColors.accent.opacity(0.10))
                )
            }

            if failedDownloadCount > 0 {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DSColors.danger)
                    Text("\(failedDownloadCount) 章下载失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                    Spacer()
                    Button("全部重试", action: onRetryAllFailed)
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.onAccent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DSColors.accent))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                        .fill(DSColors.danger.opacity(0.10))
                )
            }
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    @ViewBuilder
    var emptyChaptersStateView: some View {
        if isShowingDownloadedOnly {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(DSTypography.largeTitle)
                    .foregroundStyle(DSColors.inkSecondary)
                Text("暂无已下载章节")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                Text(totalCount > 0 ? "下载章节后将在此优先展示，支持离线收听与空间管理" : "当前书籍暂无可下载章节，可稍后刷新目录")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: DSSpacing.sm) {
                    if totalCount > 0 {
                        Button(action: onDownloadNext10) {
                            Text("下载后续 10 章")
                                .font(DSTypography.cardTitle)
                                .foregroundStyle(DSColors.onAccent)
                                .padding(.horizontal, DSSpacing.md)
                                .padding(.vertical, DSSpacing.xs)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(DSColors.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        isShowingDownloadedOnly = false
                    } label: {
                        Text("浏览全部章节")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.md)
                            .padding(.vertical, DSSpacing.xs)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceGrouped))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: .infinity)
        } else if totalCount == 0 {
            DSStateView(
                icon: "list.bullet.rectangle",
                title: "暂无章节目录",
                message: "当前书源暂未返回章节列表，可稍后点击右上角刷新目录。"
            )
        } else {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.inkSecondary)
                Text("未找到匹配的章节")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(DSColors.inkPrimary)
                if !searchKeyword.isEmpty {
                    Button("清除搜索词") { searchKeyword = "" }
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(DSColors.accent)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                }
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 100 章区间分段下拉菜单
struct BookChapterSegmentMenu: View, Equatable {
    let segments: [ChapterSegmentItem]
    let selectedSegmentIndex: Int
    let onSelectSegment: (Int) -> Void

    nonisolated static func == (lhs: BookChapterSegmentMenu, rhs: BookChapterSegmentMenu) -> Bool {
        lhs.segments == rhs.segments && lhs.selectedSegmentIndex == rhs.selectedSegmentIndex
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
            .foregroundStyle(DSColors.inkPrimary)
            .padding(.horizontal, DSSpacing.sm)
            .frame(minHeight: 34)
            .background(Capsule(style: .continuous).fill(DSColors.surfaceGrouped))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("切换章节区间")
    }
}
