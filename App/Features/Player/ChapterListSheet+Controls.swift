import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 播放页章节目录弹窗：分段与已下载双胶囊切换栏、空态与定位辅助扩展
extension ChapterListSheet {
    func filterAndLocateBar(segments: [ChapterSegmentRange], downloadedCount: Int) -> some View {
        HStack(spacing: DSSpacing.sm) {
            HStack(spacing: 2) {
                if segments.count > 1 {
                    segmentTabControl(segments: segments)
                } else {
                    segmentedPillButton(title: "全部章节", showChevron: false, isSelected: !model.onlyDownloaded) {
                        DSHaptics.selection()
                        DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) { model.onlyDownloaded = false }
                    }
                }

                segmentedPillButton(
                    title: downloadedCount > 0 ? "已下载 (\(downloadedCount))" : "已下载",
                    showChevron: false,
                    isSelected: model.onlyDownloaded
                ) {
                    DSHaptics.selection()
                    DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                        model.onlyDownloaded.toggle()
                    }
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))

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
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func segmentTabControl(segments: [ChapterSegmentRange]) -> some View {
        let currentLabel = segments.indices.contains(model.selectedSegmentIndex)
            ? segments[model.selectedSegmentIndex].label
            : "1–100"
        let title = "第 \(currentLabel) 章"
        if model.onlyDownloaded {
            segmentedPillButton(title: title, showChevron: true, isSelected: false) {
                DSHaptics.selection()
                DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) { model.onlyDownloaded = false }
            }
        } else {
            Menu {
                ForEach(segments) { seg in
                    Button {
                        DSHaptics.selection()
                        model.onlyDownloaded = false
                        model.selectedSegmentIndex = seg.index
                    } label: {
                        HStack {
                            Text("第 \(seg.label) 章")
                            if seg.index == model.selectedSegmentIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                segmentedPillLabel(title: title, showChevron: true, isSelected: true)
            }
        }
    }

    private func segmentedPillButton(title: String, showChevron: Bool, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            segmentedPillLabel(title: title, showChevron: showChevron, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func segmentedPillLabel(title: String, showChevron: Bool, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(DSTypography.caption.weight(isSelected ? .semibold : .medium))
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(DSTypography.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(isSelected ? DSColors.accent.opacity(0.18) : Color.clear))
        .overlay(Capsule().strokeBorder(isSelected ? DSColors.accent.opacity(0.55) : Color.clear, lineWidth: 0.7))
        .frame(minHeight: 32)
        .contentShape(Capsule())
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

    func downloadedSummaryStrip(count: Int, totalBytes: Int64) -> some View {
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

    var emptyStateView: some View {
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

    func enqueueSingleChapter(_ chapter: ChapterDTO) {
        guard let book = playback.currentBook else { return }
        DSHaptics.selection()
        let quality = container.resolvedQuality(for: book)
        Task {
            await downloads.enqueueManual(book: book, chapters: [chapter], quality: quality)
            banner.show("已加入下载队列", tone: .info)
        }
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
