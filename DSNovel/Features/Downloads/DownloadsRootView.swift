import SwiftUI
import SwiftData

struct DownloadsRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<DownloadItem> { $0.state != "completed" },
        sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]
    )
    private var activeAndFailedItems: [DownloadItem]
    @State private var downloadManager = DownloadManager.shared
    @State private var pendingDeleteSummary: DownloadSummary?
    @State private var freeDiskBytes: Int64 = 0

    init() {}

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let partitioned = DownloadsDataHelper.partitionItems(activeAndFailedItems)
        let summaries = DownloadsDataHelper.sortedSummaries(downloadManager.summariesByBookID)

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
                StorageOverviewCard(
                    manualBytes: downloadManager.cachedManualDownloadedBytes,
                    precacheBytes: downloadManager.cachedTemporaryCacheBytes ?? 0,
                    freeDiskBytes: freeDiskBytes,
                    onClearPrecache: {
                        downloadManager.clearTemporaryCaches()
                        DSHapticPolicy.fire(.success)
                        BannerCenter.shared.show("已清理预缓存与封面缓存", kind: .success)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !partitioned.active.isEmpty {
                Section {
                    HStack(spacing: Spacing.s3) {
                        Text("进行中（\(partitioned.active.count) 章）")
                            .font(DSTypography.cardTitle)
                        Spacer()
                        Button("暂停全部") {
                            Task { await downloadManager.pauseAllActive() }
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .buttonStyle(.plain)

                        Button("继续全部") {
                            downloadManager.resumeAllPaused()
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.dsSurfaceCard)

                    ForEach(partitioned.active.prefix(5)) { item in
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
                                        DSProgress(
                                            value: downloadManager.itemProgress[item.id] ?? 0.1,
                                            style: .ring(size: 20, lineWidth: 2)
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
                }
            }

            if !partitioned.failed.isEmpty {
                Section {
                    HStack(spacing: Spacing.s3) {
                        Text("\(partitioned.failed.count) 章下载失败")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("全部重试") {
                            downloadManager.retryAllFailed()
                            BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .buttonStyle(.plain)

                        Button("清空失败", role: .destructive) {
                            let removed = downloadManager.removeAllFailedItems()
                            if removed > 0 {
                                DSHapticPolicy.fire(.warning)
                                BannerCenter.shared.show("已清空 \(removed) 章失败记录", kind: .info, bypassDeduplication: true)
                            }
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(.red)
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
                            }
                            Spacer()
                            Button("重试") {
                                downloadManager.retryFailedItem(item)
                                BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                            }
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
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
        .onAppear {
            downloadManager.modelContext = modelContext
            downloadManager.reconcileCompletedFilesIfNeeded()
        }
        .task {
            await downloadManager.refreshCachedStorageMetrics()
            let provider = downloadManager.availableDiskBytesProvider
            let computedFree = await Task.detached(priority: .utility) {
                provider()
            }.value
            freeDiskBytes = computedFree
        }
    }
}
