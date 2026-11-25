import DSCore
import DSDesignSystem
import DSDownloads
import Foundation
import SwiftUI

/// 隔离订阅 DownloadProgressFeed 的 20pt 环形下载进度视图（避免高频进度刷新外层列表）
struct LiveDownloadProgressRing: View {
    @Environment(DownloadProgressFeed.self) private var progressFeed
    let recordID: String
    let fallbackProgress: Double

    var body: some View {
        let live = progressFeed.progress(for: recordID)
        DownloadProgressRingView(
            progress: live > 0 ? live : fallbackProgress,
            size: 20,
            lineWidth: 2
        )
    }
}

enum DownloadsFilterTab: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "进行中"
    case completed = "已完成"

    var id: String { rawValue }
}

/// 下载管理根视图（聚焦手动离线下载：纯净离线概览卡 → 三段筛选 → 进行中/失败队列 → 带封面已下载书籍）
struct DownloadsRootView: View {
    @Environment(AppContainer.self) var container
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(AppRouter.self) var router
    @Environment(DSBannerCoordinator.self) var banner

    @State var activeItems: [DownloadRecordSnapshot] = []
    @State var failedItems: [DownloadRecordSnapshot] = []
    @State var bookSummaries: [DownloadsDataHelper.BookDownloadSummary] = []
    @State var manualBytes: Int64 = 0
    @State var freeDiskBytes: Int64 = 0
    @State var selectedFilter: DownloadsFilterTab = .all

    @State var showAllActive = false
    @State var pendingDeleteSummary: DownloadsDataHelper.BookDownloadSummary?
    @State var showClearFailedConfirm = false

    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        let visibleActive = showAllActive ? activeItems : Array(activeItems.prefix(5))
        let hiddenActiveCount = max(0, activeItems.count - 5)
        let totalCompletedChapters = bookSummaries.reduce(0) { $0 + $1.completedCount }
        let hasPaused = activeItems.contains { $0.state == .paused }

        List {
            if downloads.isWaitingForWiFi && !activeItems.isEmpty {
                Section {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(DSColors.warning)
                        Text("当前为移动网络，已开启「仅 Wi-Fi 下载」，连上 Wi-Fi 后将自动继续。")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.warning)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }
            }

            Section {
                StorageOverviewCard(
                    manualBytes: manualBytes,
                    bookCount: bookSummaries.count,
                    completedChapterCount: totalCompletedChapters,
                    activeCount: activeItems.count,
                    freeDiskBytes: freeDiskBytes,
                    hasPausedTasks: hasPaused,
                    onTogglePauseResumeAll: {
                        Task {
                            if hasPaused {
                                await downloads.resumeAll()
                            } else {
                                await downloads.pauseAll()
                            }
                        }
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !(activeItems.isEmpty && failedItems.isEmpty && bookSummaries.isEmpty) {
                Section {
                    Picker("筛选", selection: $selectedFilter) {
                        ForEach(DownloadsFilterTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            if selectedFilter == .all || selectedFilter == .active {
                if !activeItems.isEmpty {
                    activeSection(visibleActive: visibleActive, hiddenCount: hiddenActiveCount)
                } else if selectedFilter == .active && failedItems.isEmpty {
                    Section {
                        DSStateView(
                            kind: .empty,
                            titleOverride: "暂无进行中的下载",
                            messageOverride: "在书籍详情页选择章节即可加入离线队列",
                            primaryTitleOverride: nil,
                            onPrimary: nil,
                            onSecondary: nil
                        )
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }
                if !failedItems.isEmpty {
                    failedSection
                }
            }

            if selectedFilter == .all || selectedFilter == .completed {
                completedBooksSection
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pendingDeleteSummary.map {
                "确认删除《\($0.bookTitle)》的 \($0.completedCount) 章离线音频（\(formatBytes($0.totalBytes))）？"
            } ?? "确认删除离线音频？",
            isPresented: Binding(
                get: { pendingDeleteSummary != nil },
                set: { if !$0 { pendingDeleteSummary = nil } }
            )
        ) {
            Button("删除离线章节", role: .destructive) {
                if let target = pendingDeleteSummary {
                    Task {
                        DSHaptics.lightImpact()
                        await downloads.deleteBookDownloads(bookID: target.id)
                        banner.show("已删除《\(target.bookTitle)》离线章节", tone: .info)
                        await refreshAllData()
                    }
                }
                pendingDeleteSummary = nil
            }
            Button("取消", role: .cancel) { pendingDeleteSummary = nil }
        } message: {
            Text("仅删除本地离线音频，不会影响书架收藏与收听进度。")
        }
        .alert(
            "确认清空全部 \(failedItems.count) 章失败记录？",
            isPresented: $showClearFailedConfirm
        ) {
            Button("清空失败", role: .destructive) {
                Task { await clearAllFailed() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后仅移除失败队列记录，不影响已下载的离线音频。")
        }
        .onChange(of: downloads.manualRecords) { _, _ in refreshDerivedFromCoordinator() }
        .task {
            await downloads.reconcileDisk(force: false)
            await refreshAllData()
        }
    }

    func refreshDerivedFromCoordinator() {
        let records = downloads.manualRecords
        let partitioned = DownloadsDataHelper.partitionRecords(records)
        activeItems = partitioned.active
        failedItems = partitioned.failed
        bookSummaries = DownloadsDataHelper.bookSummaries(from: records)
        manualBytes = DownloadsDataHelper.manualCompletedBytes(from: records)
    }

    func refreshAllData() async {
        refreshDerivedFromCoordinator()
        freeDiskBytes = DownloadsDataHelper.freeDiskBytes()
    }

    func retryAllFailed() async {
        let targets = failedItems
        for item in targets {
            await downloads.resume(id: item.id)
        }
        if !targets.isEmpty {
            banner.show("已重新加入 \(targets.count) 个下载任务", tone: .info)
        }
    }

    func clearAllFailed() async {
        let targets = failedItems
        for item in targets {
            await downloads.cancelAndDelete(id: item.id)
        }
        if !targets.isEmpty {
            banner.show("已清空 \(targets.count) 条失败记录", tone: .info)
        }
    }
}
