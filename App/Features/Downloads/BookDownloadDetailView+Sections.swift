import DSCore
import DSDesignSystem
import SwiftUI

/// 单书离线下载详情分区视图（紧凑版：46pt 封面头卡 + 36pt 双快捷按钮 + 紧凑列表行高 + 正/倒序切换 + 左滑/长按导出）
extension BookDownloadDetailView {
    var overviewSection: some View {
        Section {
            VStack(spacing: 0) {
                HStack(spacing: DSSpacing.sm) {
                    DSCover(
                        url: coverURLString,
                        title: bookTitle,
                        pipeline: container.coverPipeline,
                        side: 48,
                        showsBorder: true,
                        showsSoftShadow: false
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookTitle)
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(DSColors.inkPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(completedItems.count) 章 · \(formatBytes(totalBytes))")
                                .font(DSTypography.numericCaption)
                                .foregroundStyle(DSColors.inkSecondary)
                            if !primaryQualityBadge.isEmpty {
                                Text(primaryQualityBadge)
                                    .font(DSTypography.caption2.weight(.semibold))
                                    .foregroundStyle(DSColors.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        Task { await openBookDetailPage() }
                    } label: {
                        Text("书籍页")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DSColors.surfaceGrouped))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, 10)

                if !completedItems.isEmpty {
                    Divider().overlay(DSColors.separator.opacity(0.25))

                    HStack(spacing: 0) {
                        Button {
                            Task { await continueOfflinePlayback() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(DSTypography.caption)
                                Text("继续离线播放")
                                    .font(DSTypography.caption.weight(.semibold))
                            }
                            .foregroundStyle(DSColors.accent)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .frame(height: 18)
                            .overlay(DSColors.separator.opacity(0.30))

                        Button {
                            DSHaptics.selection()
                            isBatchManaging.toggle()
                            if !isBatchManaging { selectedRecordIDs.removeAll() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isBatchManaging ? "xmark.circle" : "checkmark.circle")
                                    .font(DSTypography.caption)
                                Text(isBatchManaging ? "完成管理" : "批量管理")
                                    .font(DSTypography.caption.weight(.medium))
                            }
                            .foregroundStyle(isBatchManaging ? DSColors.accent : DSColors.inkPrimary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(DSColors.surfaceCard)
        }
    }

    @ViewBuilder
    func activeSection(visibleActive: [DownloadRecordSnapshot], hiddenCount: Int) -> some View {
        Section {
            HStack(spacing: DSSpacing.xs) {
                Text("正在下载（\(activeItems.count) 章）")
                    .font(DSTypography.cardTitle)
                Spacer()
                Button("暂停") { Task { await pauseBookActive() } }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .buttonStyle(.plain)
                Button("继续") { Task { await resumeBookActive() } }
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .padding(.leading, 8)
                    .buttonStyle(.plain)
            }
            .listRowBackground(DSColors.surfaceCard)

            ForEach(visibleActive) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.chapterTitle).font(DSTypography.subheadline).lineLimit(1)
                        Text(DownloadsDataHelper.activeStateLabel(for: item.state, isWaitingForWiFi: downloads.isWaitingForWiFi))
                            .font(DSTypography.caption2)
                            .foregroundStyle(downloads.isWaitingForWiFi ? DSColors.warning : DSColors.inkSecondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            if item.state == .paused { await downloads.resume(id: item.id) }
                            else { await downloads.pause(id: item.id) }
                        }
                    } label: {
                        if item.state == .paused {
                            Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(DSColors.accent)
                        } else {
                            LiveDownloadProgressRing(recordID: item.id, fallbackProgress: 0.15)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(DSColors.surfaceCard)
            }

            if hiddenCount > 0 {
                Button { showAllActive.toggle() } label: {
                    Text(showAllActive ? "收起" : "展开其余 \(hiddenCount) 章")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
            }
        }
    }

    @ViewBuilder
    func failedSection(visibleFailed: [DownloadRecordSnapshot], hiddenCount: Int) -> some View {
        Section {
            HStack(spacing: DSSpacing.xs) {
                Text("\(failedItems.count) 章下载失败").font(DSTypography.cardTitle).foregroundStyle(DSColors.danger)
                Spacer()
                Button("全部重试") { Task { await retryBookFailed() } }
                    .font(DSTypography.caption.weight(.semibold)).foregroundStyle(DSColors.accent).buttonStyle(.plain)
                Button("清空失败", role: .destructive) { showClearFailedConfirm = true }
                    .font(DSTypography.caption.weight(.semibold)).foregroundStyle(DSColors.danger).padding(.leading, 8).buttonStyle(.plain)
            }
            .listRowBackground(DSColors.surfaceCard)

            ForEach(visibleFailed) { item in
                HStack(spacing: DSSpacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.chapterTitle).font(DSTypography.subheadline).lineLimit(1)
                        if let err = item.errorMessage, !err.isEmpty {
                            Text(err).font(DSTypography.caption2).foregroundStyle(DSColors.danger.opacity(0.85)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("重试") {
                        Task {
                            await downloads.resume(id: item.id)
                            banner.show("已重新加入下载队列", tone: .info)
                        }
                    }
                    .font(DSTypography.caption.weight(.semibold)).foregroundStyle(DSColors.accent).buttonStyle(.plain)
                }
                .listRowBackground(DSColors.surfaceCard)
            }

            if hiddenCount > 0 {
                Button { showAllFailed.toggle() } label: {
                    Text(showAllFailed ? "收起" : "展开其余 \(hiddenCount) 章")
                        .font(DSTypography.caption.weight(.semibold)).foregroundStyle(DSColors.accent).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
            }
        }
    }

    var completedSection: some View {
        Section {
            ForEach(Array(displayedCompletedItems.enumerated()), id: \.element.id) { idx, item in
                let isPlayingThis = (playback.currentBook?.id == bookID && playback.currentChapter?.id == item.chapterID)
                let isSelected = selectedRecordIDs.contains(item.id)
                let cleanTitle = BookTitleFormatter.stripBookPrefix(from: item.chapterTitle, bookTitle: bookTitle)
                let sizeText = (item.totalBytes > 0 ? item.totalBytes : item.downloadedBytes).dsCompactByteSize
                let metaText = isPlayingThis
                    ? (sizeText.isEmpty ? "正在播放" : "正在播放 · \(sizeText)")
                    : (sizeText.isEmpty ? "已下载" : sizeText)
                Button {
                    if isBatchManaging {
                        DSHaptics.selection()
                        if isSelected { selectedRecordIDs.remove(item.id) }
                        else { selectedRecordIDs.insert(item.id) }
                    } else {
                        Task { await playOffline(record: item, fallbackIndex: idx) }
                    }
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        if isBatchManaging {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                                .frame(width: 24)
                        } else if isPlayingThis {
                            DSEqualizer(isPlaying: playback.state.isPlaying).frame(width: 24)
                        } else {
                            Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(DSColors.accent).frame(width: 24)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(cleanTitle)
                                .font(DSTypography.subheadline.weight(isPlayingThis ? .semibold : .regular))
                                .foregroundStyle(isPlayingThis ? DSColors.accent : DSColors.inkPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 5) {
                                if item.qualityTier != .auto {
                                    DSQualityMicroBadge(tier: item.qualityTier)
                                }
                                Text(metaText)
                                    .font(DSTypography.caption2.monospacedDigit())
                                    .foregroundStyle(isPlayingThis ? DSColors.accent.opacity(0.90) : DSColors.inkSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .allowsTightening(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isBatchManaging {
                        Button(role: .destructive) {
                            DSHaptics.lightImpact()
                            Task {
                                await downloads.cancelAndDelete(id: item.id)
                                banner.show("已删除该章离线文件", tone: .info)
                            }
                        } label: {
                            Label("删除离线", systemImage: "trash")
                        }
                        Button {
                            exportSingleChapter(item)
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                        .disabled(isPreparingExport)
                    }
                }
                .contextMenu {
                    if !isBatchManaging {
                        Button {
                            exportSingleChapter(item)
                        } label: {
                            Label("导出音频", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isPreparingExport)
                        Button(role: .destructive) {
                            pendingDeleteItem = item
                        } label: {
                            Label("删除离线", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("已下载章节（\(completedItems.count)）")
                Spacer()
                Button {
                    DSHaptics.selection()
                    isDescendingOrder.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(isDescendingOrder ? "倒序" : "正序")
                    }
                    .font(DSTypography.caption2.weight(.medium))
                    .foregroundStyle(DSColors.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
