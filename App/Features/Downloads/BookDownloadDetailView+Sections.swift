import DSCore
import DSDesignSystem
import SwiftUI

/// 单书离线下载详情分区视图（紧凑版：46pt 封面头卡 + 36pt 双快捷按钮 + 紧凑列表行高 + 正/倒序切换）
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
                HStack(spacing: DSSpacing.sm) {
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

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.chapterTitle)
                                    .font(DSTypography.subheadline.weight(isPlayingThis ? .semibold : .regular))
                                    .foregroundStyle(isPlayingThis ? DSColors.accent : DSColors.inkPrimary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(isPlayingThis ? "正在播放" : "已下载")
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(isPlayingThis ? DSColors.accent : DSColors.inkSecondary)
                                    Text("· \(formatBytes(item.totalBytes)) · \(DownloadsDataHelper.qualityBadgeText(for: item))")
                                        .font(DSTypography.caption2.monospacedDigit())
                                        .foregroundStyle(DSColors.inkSecondary)
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isBatchManaging {
                        Menu {
                            Button(role: .destructive) { pendingDeleteItem = item } label: {
                                Label("删除离线文件", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(DSTypography.subheadline)
                                .foregroundStyle(DSColors.inkSecondary)
                                .frame(minWidth: 36, minHeight: 36)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .listRowBackground(DSColors.surfaceCard)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isBatchManaging {
                        Button(role: .destructive) { pendingDeleteItem = item } label: {
                            Label("删除", systemImage: "trash")
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
