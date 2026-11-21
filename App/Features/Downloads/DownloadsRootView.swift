import DSCore
import DSDesignSystem
import DSDownloads
import Foundation
import SwiftUI

/// 独立下载行进度条子视图（P3-06：隔离 DownloadProgressFeed 高频订阅，避免整个 DownloadsRootView 整表重绘）
private struct DownloadRowProgressBar: View {
    @Environment(DownloadProgressFeed.self) private var progressFeed
    let recordID: String

    var body: some View {
        ProgressView(value: progressFeed.progress(for: recordID))
    }
}

/// 下载管理根视图（三屏分段：下载中 / 已完成 / 存储概览；按当前分段缓存派生列表，零视图内集合过滤）
struct DownloadsRootView: View {
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var selectedSegment: Int = 0
    @State private var activeCount: Int = 0
    @State private var completedBookCount: Int = 0
    @State private var activeTasks: [DownloadRecordSnapshot] = []
    @State private var completedGroups: [DownloadsDataHelper.BookGroup] = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("下载视图", selection: $selectedSegment) {
                Text("下载中 (\(activeCount))").tag(0)
                Text("已下载 (\(completedBookCount))").tag(1)
                Text("存储概览").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.xs)

            if downloads.isWaitingForWiFi && activeCount > 0 {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(DSColors.warning)
                    Text("当前为移动网络，已开启「仅 Wi-Fi 下载」，连上 Wi-Fi 后将自动继续。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.warning)
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.bottom, DSSpacing.xs)
            }
            List {
                if selectedSegment == 0 {
                    activeSection(activeTasks)
                } else if selectedSegment == 1 {
                    completedSection(completedGroups)
                } else {
                    storageSection(groupsCount: completedBookCount)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(DSColors.surfaceBase)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectedSegment == 0 && activeCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button("全暂停") {
                            Task { await downloads.pauseAll() }
                        }
                        .frame(minHeight: 44)
                        Button("全开始") {
                            Task { await downloads.resumeAll() }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .onAppear { refreshSegmentData() }
        .onChange(of: selectedSegment) { _, _ in refreshSegmentData() }
        .onChange(of: downloads.manualRecords) { _, _ in refreshSegmentData() }
        .task {
            await downloads.reconcileDisk(force: false)
            refreshSegmentData()
        }
    }

    private func refreshSegmentData() {
        let records = downloads.manualRecords
        activeCount = DownloadsDataHelper.activeTaskCount(from: records)
        completedBookCount = DownloadsDataHelper.completedBookCount(from: records)
        if selectedSegment == 0 {
            activeTasks = DownloadsDataHelper.activeTasks(from: records)
        } else if selectedSegment == 1 {
            completedGroups = DownloadsDataHelper.completedBookGroups(from: records)
        }
    }

    @ViewBuilder
    private func activeSection(_ active: [DownloadRecordSnapshot]) -> some View {
        if active.isEmpty {
            DSStateView(
                icon: "arrow.down.circle",
                title: "暂无进行中的下载任务",
                message: "可在书籍详情或播放器中批量添加章节离线下载。"
            )
            .listRowBackground(Color.clear)
        } else {
            ForEach(active) { item in
                HStack(spacing: DSSpacing.sm) {
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Text(item.chapterTitle)
                            .font(DSTypography.subheadline)
                            .lineLimit(1)
                        Text("\(item.bookTitle) · \(stateLabel(item.state))")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                        DownloadRowProgressBar(recordID: item.id)
                    }
                    Spacer()
                    Button {
                        Task {
                            if item.state == .paused || item.state == .failed {
                                await downloads.resume(id: item.id)
                            } else {
                                await downloads.pause(id: item.id)
                            }
                        }
                    } label: {
                        Image(systemName: (item.state == .paused || item.state == .failed) ? "play.circle" : "pause.circle")
                            .font(DSTypography.title)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((item.state == .paused || item.state == .failed) ? "继续下载" : "暂停下载")
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) {
                        Task { await downloads.cancelAndDelete(id: item.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func completedSection(_ groups: [DownloadsDataHelper.BookGroup]) -> some View {
        if groups.isEmpty {
            DSStateView(
                icon: "checkmark.circle",
                title: "还没有已下载书籍",
                message: "已完成的离线音频会按书籍归类保存在此处。"
            )
            .listRowBackground(Color.clear)
        } else {
            ForEach(groups) { group in
                Button {
                    router.push(.bookDownloadDetail(bookID: group.id, bookTitle: group.bookTitle))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                            Text(group.bookTitle)
                                .font(DSTypography.headline)
                                .foregroundStyle(DSColors.inkPrimary)
                            Text("已下载 \(group.completedCount) 章 · \(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func storageSection(groupsCount: Int) -> some View {
        Section("离线音频存储") {
            HStack {
                Text("已占空间")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: downloads.totalDiskBytes, countStyle: .file))
                    .foregroundStyle(DSColors.inkSecondary)
            }
            HStack {
                Text("离线书籍数")
                Spacer()
                Text("\(groupsCount) 本")
                    .foregroundStyle(DSColors.inkSecondary)
            }
            Button("立即对账并清理孤儿文件") {
                Task {
                    await downloads.reconcileDisk(force: true)
                    refreshSegmentData()
                    banner.show("磁盘对账已完成", tone: .success)
                }
            }
            .frame(minHeight: 44)
        }
    }

    private func stateLabel(_ state: DownloadState) -> String {
        switch state {
        case .queued: return "排队中"
        case .resolving: return "解析地址中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}
