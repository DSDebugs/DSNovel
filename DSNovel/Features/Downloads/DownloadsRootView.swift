import SwiftUI
import SwiftData

/// 轻量进度环叶子视图（P1：直接订阅 DownloadProgressStore.shared，避免高频进度刷新外层列表）
struct DownloadProgressRingView: View {
    let itemID: String
    let fallbackProgress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    @State private var progressStore = DownloadProgressStore.shared

    init(
        itemID: String,
        fallbackProgress: Double = 0.15,
        size: CGFloat = 20,
        lineWidth: CGFloat = 2
    ) {
        self.itemID = itemID
        self.fallbackProgress = fallbackProgress
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        DSProgress(
            value: progressStore.progressByItemID[itemID] ?? fallbackProgress,
            style: .ring(size: size, lineWidth: lineWidth)
        )
    }
}

/// 轻量码率角标叶子视图（P1：仅订阅 DownloadProgressStore.shared.bitrateKbpsByItemID）
struct DownloadBitrateBadgeView: View {
    let item: DownloadItem
    @State private var progressStore = DownloadProgressStore.shared

    init(item: DownloadItem) {
        self.item = item
    }

    var body: some View {
        let badge = DownloadsDataHelper.bitrateBadgeText(
            forItem: item,
            inProgressBitrateKbps: progressStore.bitrateKbpsByItemID[item.id]
        )
        if !badge.isEmpty {
            Text(badge)
                .font(DSTypography.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.dsSurfaceGrouped))
        }
    }
}

struct DownloadsRootView: View {
    @Environment(\.modelContext) private var modelContext
    /// 7-2：下载管理 UI 列表严格过滤 `kind == "manual"`，避免暴露 `precache` 预缓存项
    @Query(
        filter: #Predicate<DownloadItem> { $0.kind == "manual" && $0.state != "completed" },
        sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]
    )
    private var activeAndFailedItems: [DownloadItem]
    @State private var downloadManager = DownloadManager.shared
    @State private var pendingDeleteSummary: DownloadSummary?
    @State private var showAllActive = false
    @State private var showClearFailedConfirm = false

    init() {}

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let partitioned = DownloadsDataHelper.partitionItems(activeAndFailedItems)
        let summaries = DownloadsDataHelper.sortedSummaries(downloadManager.summariesByBookID)
        let visibleActive = showAllActive ? partitioned.active : Array(partitioned.active.prefix(5))
        let hiddenActiveCount = max(0, partitioned.active.count - 5)

        List {
            if downloadManager.isDiskInsufficient {
                Section {
                    Text("设备可用存储空间不足，下载队列已暂停")
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.dsSurfaceCard)
                }
            }

            Section {
                // 7-5：直接复用 downloadManager.cachedAvailableDiskBytes，未就绪时使用占位渲染，彻底消除冗余刷新与首帧 0B 闪烁
                StorageOverviewCard(
                    manualBytes: downloadManager.cachedManualDownloadedBytes,
                    precacheBytes: downloadManager.cachedTemporaryCacheBytes ?? downloadManager.cachedPrecacheBytes,
                    freeDiskBytes: downloadManager.cachedAvailableDiskBytes ?? 0,
                    onClearPrecache: {
                        downloadManager.clearTemporaryCaches()
                        DSHapticPolicy.fire(.success)
                        BannerCenter.shared.show("已清理预缓存与封面缓存", kind: .success)
                    }
                )
                .redacted(reason: downloadManager.cachedAvailableDiskBytes == nil ? .placeholder : [])
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !partitioned.active.isEmpty {
                Section {
                    HStack(spacing: Spacing.s2) {
                        Text("进行中（\(partitioned.active.count) 章）")
                            .font(DSTypography.cardTitle)
                        Spacer()
                        Button {
                            Task { await downloadManager.pauseAllActive() }
                        } label: {
                            Text("暂停全部")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, Spacing.s2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            downloadManager.resumeAllPaused()
                        } label: {
                            Text("继续全部")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, Spacing.s2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.dsSurfaceCard)

                    ForEach(visibleActive) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.chapterTitle)
                                    .font(DSTypography.body)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(DownloadsDataHelper.activeStateLabel(for: item.state))
                                        .font(DSTypography.caption)
                                        .foregroundStyle(item.state == "waitingWiFi" ? .orange : .secondary)
                                    Text("·")
                                        .font(DSTypography.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.bookTitle)
                                        .font(DSTypography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                if item.state == "paused" {
                                    downloadManager.resumeItem(item)
                                } else {
                                    Task { await downloadManager.pauseItem(item) }
                                }
                            } label: {
                                Group {
                                    if item.state == "paused" {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color.dsAccent)
                                    } else {
                                        DownloadProgressRingView(
                                            itemID: item.id,
                                            fallbackProgress: 0.1,
                                            size: 20,
                                            lineWidth: 2
                                        )
                                    }
                                }
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.state == "paused" ? "继续下载：\(item.chapterTitle)" : "暂停下载：\(item.chapterTitle)")
                        }
                        .listRowBackground(Color.dsSurfaceCard)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                let removed = downloadManager.removeDownloadItem(bookID: item.bookID, chapterID: item.chapterID)
                                if removed {
                                    DSHapticPolicy.fire(.warning)
                                    BannerCenter.shared.show("已取消「\(item.chapterTitle)」下载", kind: .info, bypassDeduplication: true)
                                }
                            } label: {
                                Label("取消", systemImage: "xmark.circle")
                            }
                        }
                    }

                    if hiddenActiveCount > 0 {
                        Button {
                            showAllActive.toggle()
                        } label: {
                            HStack {
                                Spacer()
                                Text(showAllActive ? "收起" : "展开其余 \(hiddenActiveCount) 章")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.dsSurfaceCard)
                    }
                }
            }

            if !partitioned.failed.isEmpty {
                Section {
                    HStack(spacing: Spacing.s2) {
                        Text("\(partitioned.failed.count) 章下载失败")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            downloadManager.retryAllFailed()
                            BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                        } label: {
                            Text("全部重试")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, Spacing.s2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            showClearFailedConfirm = true
                        } label: {
                            Text("清空失败")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, Spacing.s2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.dsSurfaceCard)

                    ForEach(partitioned.failed) { item in
                        HStack(spacing: Spacing.s2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.chapterTitle)
                                    .font(DSTypography.body)
                                    .lineLimit(1)
                                Text(item.bookTitle)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !item.lastErrorMessage.isEmpty {
                                    Text(item.lastErrorMessage)
                                        .font(DSTypography.caption)
                                        .foregroundStyle(.red.opacity(0.85))
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Button {
                                downloadManager.retryFailedItem(item)
                                BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                            } label: {
                                Text("重试")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, Spacing.s2)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                let removed = downloadManager.removeDownloadItem(bookID: item.bookID, chapterID: item.chapterID)
                                if removed {
                                    DSHapticPolicy.fire(.warning)
                                    BannerCenter.shared.show("已删除「\(item.chapterTitle)」失败记录", kind: .info, bypassDeduplication: true)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除失败记录：\(item.chapterTitle)")
                        }
                        .listRowBackground(Color.dsSurfaceCard)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                let removed = downloadManager.removeDownloadItem(bookID: item.bookID, chapterID: item.chapterID)
                                if removed {
                                    DSHapticPolicy.fire(.warning)
                                    BannerCenter.shared.show("已删除「\(item.chapterTitle)」失败记录", kind: .info, bypassDeduplication: true)
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section("已下载书籍（\(summaries.count)）") {
                if summaries.isEmpty {
                    DSStateView(
                        kind: .empty,
                        titleOverride: "暂无已下载书籍",
                        messageOverride: "在书籍详情页下载章节后即可离线收听",
                        primaryTitleOverride: "去发现",
                        onPrimary: { AppRouter.shared.selectedTab = .discover },
                        onSecondary: nil
                    )
                    .listRowBackground(Color.dsSurfaceCard)
                } else {
                    ForEach(summaries, id: \.bookID) { sum in
                        NavigationLink {
                            BookDownloadDetailView(bookID: sum.bookID, bookTitle: sum.bookTitle)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sum.bookTitle)
                                        .font(DSTypography.rowTitle)
                                    HStack(spacing: Spacing.s2) {
                                        Text("已下载 \(sum.completedCount) 章 · \(formatBytes(sum.totalBytes))")
                                            .font(DSTypography.numericCaption)
                                            .foregroundStyle(.secondary)
                                        if sum.activeCount > 0 {
                                            DSBadge("下载中 \(sum.activeCount)", style: .accent)
                                        }
                                        if sum.failedCount > 0 {
                                            DSBadge("失败 \(sum.failedCount)", style: .danger)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.dsSurfaceCard)
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.dsSurfaceGrouped)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pendingDeleteSummary.map { "确认删除《\($0.bookTitle)》的 \($0.completedCount) 章离线音频（\(formatBytes($0.totalBytes))）？" } ?? "确认删除离线音频？",
            isPresented: Binding(
                get: { pendingDeleteSummary != nil },
                set: { if !$0 { pendingDeleteSummary = nil } }
            )
        ) {
            Button("删除离线章节", role: .destructive) {
                if let sum = pendingDeleteSummary {
                    DSHapticPolicy.fire(.warning)
                    let pending = downloadManager.removeDownloads(forBookID: sum.bookID, deferred: true, scheduleTimer: false)
                    BannerCenter.shared.showUndo(
                        "已删除《\(sum.bookTitle)》离线章节",
                        onUndo: { pending.cancel() },
                        onCommit: { pending.commitNow() }
                    )
                }
                pendingDeleteSummary = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteSummary = nil
            }
        }
        .alert(
            "确认清空全部 \(partitioned.failed.count) 章失败记录？",
            isPresented: $showClearFailedConfirm
        ) {
            Button("清空失败", role: .destructive) {
                let removed = downloadManager.removeAllFailedItems()
                if removed > 0 {
                    DSHapticPolicy.fire(.warning)
                    BannerCenter.shared.show("已清空 \(removed) 章失败记录", kind: .info, bypassDeduplication: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后仅移除失败队列记录，不影响已下载的离线音频。")
        }
        .onAppear {
            if downloadManager.modelContext == nil {
                downloadManager.modelContext = modelContext
            }
            downloadManager.reconcileCompletedFilesIfNeeded()
        }
        .task {
            await downloadManager.refreshCachedStorageMetrics()
        }
    }
}
