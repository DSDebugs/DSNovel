import SwiftUI
import SwiftData

struct DownloadsRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)])
    private var allItems: [DownloadItem]
    @State private var downloadManager = DownloadManager.shared
    @State private var pendingDeleteSummary: DownloadSummary?

    init() {}

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let partitioned = DownloadsDataHelper.partitionItems(allItems)
        let summaries = DownloadsDataHelper.sortedSummaries(downloadManager.summariesByBookID)

        List {
            if downloadManager.isDiskInsufficient {
                Section {
                    Text("设备可用存储空间不足，下载队列已暂停")
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(.red)
                }
            }

            Section {
                StorageOverviewCard(
                    manualBytes: downloadManager.totalManualDownloadedBytes(),
                    precacheBytes: downloadManager.totalPrecacheAndTempBytes(),
                    freeDiskBytes: downloadManager.availableDiskBytesProvider(),
                    onClearPrecache: {
                        downloadManager.clearPrecacheOnly()
                        DSHapticPolicy.fire(.success)
                        BannerCenter.shared.show("已清理预缓存", kind: .success)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !partitioned.active.isEmpty {
                Section {
                    HStack {
                        Text("进行中（\(partitioned.active.count) 章）")
                            .font(DSTypography.cardTitle)
                        Spacer()
                        Button("暂停全部") {
                            Task { await downloadManager.pauseAllActive() }
                        }
                        .font(DSTypography.caption)
                        Button("继续全部") {
                            downloadManager.resumeAllPaused()
                        }
                        .font(DSTypography.caption)
                    }
                    ForEach(partitioned.active.prefix(5)) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.chapterTitle)
                                    .font(DSTypography.body)
                                    .lineLimit(1)
                                Text(item.state == "waitingWiFi" ? "等待 Wi-Fi" : item.bookTitle)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(item.state == "waitingWiFi" ? .orange : .secondary)
                            }
                            Spacer()
                            DSProgress(
                                value: downloadManager.itemProgress[item.id] ?? 0.1,
                                style: .ring(size: 20, lineWidth: 2)
                            )
                        }
                    }
                }
            }

            if !partitioned.failed.isEmpty {
                Section {
                    HStack {
                        Text("\(partitioned.failed.count) 章下载失败")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("全部重试") {
                            downloadManager.retryAllFailed()
                        }
                        .font(DSTypography.caption.weight(.semibold))
                    }
                    ForEach(partitioned.failed) { item in
                        HStack {
                            Text(item.chapterTitle)
                                .lineLimit(1)
                            Spacer()
                            Button("重试") {
                                downloadManager.retryFailedItem(item)
                            }
                            .font(DSTypography.caption)
                        }
                    }
                }
            }

            Section("已下载书籍（\(summaries.count)）") {
                if summaries.isEmpty {
                    DSStateView(
                        kind: .empty,
                        onPrimary: { AppRouter.shared.selectedTab = .discover },
                        onSecondary: nil
                    )
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
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingDeleteSummary.map { "确认删除《\($0.bookTitle)》的 \($0.completedCount) 章离线音频（\(formatBytes($0.totalBytes))）？" } ?? "确认删除离线音频？",
            isPresented: Binding(
                get: { pendingDeleteSummary != nil },
                set: { if !$0 { pendingDeleteSummary = nil } }
            ),
            titleVisibility: .visible
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
            downloadManager.reconcileCompletedFiles()
        }
    }
}
