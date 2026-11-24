import DSCore
import DSDesignSystem
import SwiftUI

/// 单书离线下载详情分区视图（拆分自 BookDownloadDetailView.swift 以保持单文件 ≤ 385 行）
extension BookDownloadDetailView {
    var overviewSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已下载 \(completedItems.count) 章")
                        .font(DSTypography.rowTitle)
                    Text("离线占用 \(formatBytes(totalBytes)) · 点击任意章节可直接离线播放")
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Spacer()
                Button {
                    Task { await openBookDetailPage() }
                } label: {
                    Text("书籍页")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DSColors.surfaceGrouped))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
                Button {
                    Task { await pauseBookActive() }
                } label: {
                    Text("暂停")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await resumeBookActive() }
                } label: {
                    Text("继续")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(DSColors.surfaceCard)

            ForEach(visibleActive) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.chapterTitle)
                            .font(DSTypography.body)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(DownloadsDataHelper.activeStateLabel(for: item.state, isWaitingForWiFi: downloads.isWaitingForWiFi))
                                .font(DSTypography.caption)
                                .foregroundStyle(downloads.isWaitingForWiFi ? DSColors.warning : DSColors.inkSecondary)
                            Text(DownloadsDataHelper.qualityBadgeText(for: item))
                                .font(DSTypography.caption2.weight(.medium))
                                .foregroundStyle(DSColors.inkSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DSColors.surfaceGrouped))
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            if item.state == .paused {
                                await downloads.resume(id: item.id)
                            } else {
                                await downloads.pause(id: item.id)
                            }
                        }
                    } label: {
                        Group {
                            if item.state == .paused {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(DSColors.accent)
                            } else {
                                LiveDownloadProgressRing(recordID: item.id, fallbackProgress: 0.15)
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(DSColors.surfaceCard)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task {
                            await downloads.cancelAndDelete(id: item.id)
                            banner.show("已取消「\(item.chapterTitle)」下载", tone: .info)
                        }
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                    }
                }
            }

            if hiddenCount > 0 {
                Button {
                    showAllActive.toggle()
                } label: {
                    HStack {
                        Spacer()
                        Text(showAllActive ? "收起" : "展开其余 \(hiddenCount) 章")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
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
                Text("\(failedItems.count) 章下载失败")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.danger)
                Spacer()
                Button {
                    Task { await retryBookFailed() }
                } label: {
                    Text("全部重试")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    showClearFailedConfirm = true
                } label: {
                    Text("清空失败")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(DSColors.surfaceCard)

            ForEach(visibleFailed) { item in
                HStack(spacing: DSSpacing.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.chapterTitle)
                            .font(DSTypography.body)
                            .lineLimit(1)
                        if let err = item.errorMessage, !err.isEmpty {
                            Text(err)
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.danger.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            await downloads.resume(id: item.id)
                            banner.show("已重新加入下载队列", tone: .info)
                        }
                    } label: {
                        Text("重试")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                            .padding(.horizontal, DSSpacing.xs)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        Task {
                            await downloads.cancelAndDelete(id: item.id)
                            banner.show("已删除「\(item.chapterTitle)」失败记录", tone: .info)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(DSTypography.subheadline)
                            .foregroundStyle(DSColors.danger)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(DSColors.surfaceCard)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await downloads.cancelAndDelete(id: item.id) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            if hiddenCount > 0 {
                Button {
                    showAllFailed.toggle()
                } label: {
                    HStack {
                        Spacer()
                        Text(showAllFailed ? "收起" : "展开其余 \(hiddenCount) 章")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(DSColors.surfaceCard)
            }
        }
    }

    var completedSection: some View {
        Section("已下载章节（\(completedItems.count)）") {
            ForEach(Array(completedItems.enumerated()), id: \.element.id) { idx, item in
                let isPlayingThis = (playback.currentBook?.id == bookID && playback.currentChapter?.id == item.chapterID)
                HStack(spacing: DSSpacing.sm) {
                    Button {
                        Task { await playOffline(record: item, fallbackIndex: idx) }
                    } label: {
                        HStack(spacing: DSSpacing.sm) {
                            if isPlayingThis {
                                DSEqualizer(isPlaying: playback.state.isPlaying)
                                    .frame(width: 24)
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(DSColors.accent)
                                    .frame(width: 24)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.chapterTitle)
                                    .font(DSTypography.body.weight(isPlayingThis ? .semibold : .regular))
                                    .foregroundStyle(isPlayingThis ? DSColors.accent : DSColors.inkPrimary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text("已下载 · \(formatBytes(item.totalBytes))")
                                        .font(DSTypography.numericCaption)
                                        .foregroundStyle(DSColors.inkSecondary)
                                    Text(DownloadsDataHelper.qualityBadgeText(for: item))
                                        .font(DSTypography.caption2.weight(.medium))
                                        .foregroundStyle(DSColors.inkSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(DSColors.surfaceGrouped))
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button(role: .destructive) {
                            pendingDeleteItem = item
                        } label: {
                            Label("删除离线文件", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DSTypography.body.weight(.medium))
                            .foregroundStyle(DSColors.inkSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多操作：\(item.chapterTitle)")
                }
                .listRowBackground(DSColors.surfaceCard)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteItem = item
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }
}
