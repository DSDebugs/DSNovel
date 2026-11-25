import DSCore
import DSDesignSystem
import SwiftUI

/// 下载管理分区子视图（拆分自 DownloadsRootView.swift 以保持单文件 ≤ 385 行）
extension DownloadsRootView {
    @ViewBuilder
    func activeSection(visibleActive: [DownloadRecordSnapshot], hiddenCount: Int) -> some View {
        Section {
            HStack(spacing: DSSpacing.xs) {
                Text("进行中（\(activeItems.count) 章）")
                    .font(DSTypography.cardTitle)
                Spacer()
                Button {
                    Task { await downloads.pauseAll() }
                } label: {
                    Text("暂停全部")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await downloads.resumeAll() }
                } label: {
                    Text("继续全部")
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
                activeTaskRow(item)
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

    private func activeTaskRow(_ item: DownloadRecordSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.chapterTitle)
                    .font(DSTypography.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(DownloadsDataHelper.activeStateLabel(for: item.state, isWaitingForWiFi: downloads.isWaitingForWiFi))
                        .font(DSTypography.caption)
                        .foregroundStyle(downloads.isWaitingForWiFi ? DSColors.warning : DSColors.inkSecondary)
                    Text("·")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Text(item.bookTitle)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
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
                        LiveDownloadProgressRing(recordID: item.id, fallbackProgress: 0.1)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.state == .paused ? "继续下载：\(item.chapterTitle)" : "暂停下载：\(item.chapterTitle)")
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

    var failedSection: some View {
        Section {
            HStack(spacing: DSSpacing.xs) {
                Text("\(failedItems.count) 章下载失败")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.danger)
                Spacer()
                Button {
                    Task { await retryAllFailed() }
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

            ForEach(failedItems) { item in
                failedTaskRow(item)
            }
        }
    }

    private func failedTaskRow(_ item: DownloadRecordSnapshot) -> some View {
        HStack(spacing: DSSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.chapterTitle)
                    .font(DSTypography.body)
                    .lineLimit(1)
                Text(item.bookTitle)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
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
            .accessibilityLabel("删除失败记录：\(item.chapterTitle)")
        }
        .listRowBackground(DSColors.surfaceCard)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task {
                    await downloads.cancelAndDelete(id: item.id)
                    banner.show("已删除「\(item.chapterTitle)」失败记录", tone: .info)
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    var completedBooksSection: some View {
        Section("已下载书籍（\(bookSummaries.count)）") {
            if bookSummaries.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无已下载书籍",
                    messageOverride: "在书籍详情页下载章节后即可离线收听",
                    primaryTitleOverride: "去发现",
                    onPrimary: { router.selectTab(.discover) },
                    onSecondary: nil
                )
                .listRowBackground(DSColors.surfaceCard)
            } else {
                ForEach(bookSummaries) { sum in
                    Button {
                        router.push(.bookDownloadDetail(bookID: sum.id, bookTitle: sum.bookTitle))
                    } label: {
                        HStack(spacing: DSSpacing.sm) {
                            DSCover(
                                url: sum.coverURL,
                                title: sum.bookTitle,
                                pipeline: container.coverPipeline,
                                side: 46,
                                showsBorder: true,
                                showsSoftShadow: false
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sum.bookTitle)
                                    .font(DSTypography.rowTitle)
                                    .foregroundStyle(DSColors.inkPrimary)
                                    .lineLimit(1)
                                HStack(spacing: DSSpacing.xs) {
                                    Text("已下载 \(sum.completedCount) 章 · \(formatBytes(sum.totalBytes))")
                                        .font(DSTypography.numericCaption)
                                        .foregroundStyle(DSColors.inkSecondary)
                                    if sum.activeCount > 0 {
                                        DSBadge("下载中 \(sum.activeCount)", style: .accent)
                                    }
                                    if sum.failedCount > 0 {
                                        DSBadge("失败 \(sum.failedCount)", style: .danger)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteSummary = sum
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}
