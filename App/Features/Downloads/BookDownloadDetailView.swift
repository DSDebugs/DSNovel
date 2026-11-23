import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import Foundation
import SwiftUI

/// 单本书离线下载详情页（1:1 复刻 v2.8：顶部概览卡+书籍页胶囊 → 本书进行中/失败分区 → 已下载章节优先还原完整目录起播）
struct BookDownloadDetailView: View {
    @Environment(AppContainer.self) var container
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(PlaybackCoordinator.self) var playback
    @Environment(AppRouter.self) var router
    @Environment(DSBannerCoordinator.self) var banner

    let bookID: String
    let bookTitle: String

    @State var activeItems: [DownloadRecordSnapshot] = []
    @State var failedItems: [DownloadRecordSnapshot] = []
    @State var completedItems: [DownloadRecordSnapshot] = []
    @State var totalBytes: Int64 = 0

    @State var showAllActive = false
    @State var showAllFailed = false
    @State var pendingDeleteItem: DownloadRecordSnapshot?
    @State var showClearAllConfirm = false
    @State var showClearFailedConfirm = false

    init(bookID: String, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
    }

    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        let visibleActive = showAllActive ? activeItems : Array(activeItems.prefix(8))
        let hiddenActiveCount = max(0, activeItems.count - 8)
        let visibleFailed = showAllFailed ? failedItems : Array(failedItems.prefix(8))
        let hiddenFailedCount = max(0, failedItems.count - 8)
        let isEmptyAll = completedItems.isEmpty && activeItems.isEmpty && failedItems.isEmpty

        Group {
            if isEmptyAll {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无已下载章节",
                    messageOverride: "前往书籍详情页选择需要离线下载的章节",
                    primaryTitleOverride: "前往书籍页",
                    onPrimary: { Task { await openBookDetailPage() } },
                    onSecondary: nil
                )
            } else {
                List {
                    overviewSection

                    if !activeItems.isEmpty {
                        activeSection(visibleActive: visibleActive, hiddenCount: hiddenActiveCount)
                    }

                    if !failedItems.isEmpty {
                        failedSection(visibleFailed: visibleFailed, hiddenCount: hiddenFailedCount)
                    }

                    if !completedItems.isEmpty {
                        completedSection
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(DSColors.surfaceGrouped)
            }
        }
        .background(DSColors.surfaceGrouped)
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isEmptyAll {
                    Button("清空全部", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
        }
        .alert(
            pendingDeleteItem.map {
                "确认删除「\($0.chapterTitle)」的离线文件（\(formatBytes($0.totalBytes))）？"
            } ?? "确认删除该章节离线文件？",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            )
        ) {
            Button("删除离线文件", role: .destructive) {
                if let target = pendingDeleteItem {
                    Task {
                        await downloads.cancelAndDelete(id: target.id)
                        banner.show("已删除「\(target.chapterTitle)」离线文件", tone: .info)
                    }
                }
                pendingDeleteItem = nil
            }
            Button("取消", role: .cancel) { pendingDeleteItem = nil }
        } message: {
            Text("删除后释放本地存储空间，再次收听需联网或重新下载。")
        }
        .alert(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: bookTitle,
                completedCount: completedItems.count,
                activeCount: activeItems.count,
                failedCount: failedItems.count,
                formattedBytes: formatBytes(totalBytes)
            ),
            isPresented: $showClearAllConfirm
        ) {
            Button("清空全部记录", role: .destructive) {
                Task {
                    await downloads.deleteBookDownloads(bookID: bookID)
                    banner.show("已清空《\(bookTitle)》全部下载记录", tone: .info)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "确认清空本书 \(failedItems.count) 章失败记录？",
            isPresented: $showClearFailedConfirm
        ) {
            Button("清空失败", role: .destructive) {
                Task { await clearBookFailed() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后仅移除失败队列记录，不影响已下载的离线音频。")
        }
        .onAppear { refreshPartitionedItems() }
        .onChange(of: downloads.manualRecords) { _, _ in refreshPartitionedItems() }
    }

    func refreshPartitionedItems() {
        let p = DownloadsDataHelper.partitionRecordsForBook(bookID, from: downloads.manualRecords)
        activeItems = p.active
        failedItems = p.failed
        completedItems = p.completed
        totalBytes = p.completed.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
    }

    func openBookDetailPage() async {
        let book = await resolveBookSummary()
        router.push(.bookDetail(book))
    }

    private func resolveBookSummary() async -> BookSummaryDTO {
        if let exact = try? await container.persistence.fetchBook(id: bookID) {
            return exact
        }
        let sample = completedItems.first ?? activeItems.first ?? failedItems.first
        return BookSummaryDTO(
            id: bookID,
            sourceID: sample?.sourceID ?? "",
            bookURL: "",
            title: bookTitle,
            coverURL: sample?.coverURL ?? "",
            totalChapters: completedItems.count
        )
    }

    /// 优先从 ChapterCacheStore 还原完整目录队列再定位对应章起播，无缓存时回退已下载列表
    func playOffline(record: DownloadRecordSnapshot, fallbackIndex: Int) async {
        DSHaptics.selection()
        let book = await resolveBookSummary()
        if let cached = await container.chapterCache.loadChapters(bookID: bookID), !cached.isEmpty {
            let matchIdx = cached.firstIndex(where: { $0.id == record.chapterID })
                ?? (cached.indices.contains(record.chapterIndex) ? record.chapterIndex : nil)
            if let startIdx = matchIdx {
                playback.play(book: book, chapters: cached, startIndex: startIdx, autoPlay: true)
                return
            }
        }
        let fallbackQueue = completedItems.map { rec in
            ChapterDTO(id: rec.chapterID, index: rec.chapterIndex, title: rec.chapterTitle, url: rec.chapterURL)
        }
        let safeIdx = min(max(0, fallbackIndex), max(0, fallbackQueue.count - 1))
        guard fallbackQueue.indices.contains(safeIdx) else { return }
        playback.play(book: book, chapters: fallbackQueue, startIndex: safeIdx, autoPlay: true)
    }

    func pauseBookActive() async {
        for item in activeItems where item.state != .paused {
            await downloads.pause(id: item.id)
        }
    }

    func resumeBookActive() async {
        for item in activeItems where item.state == .paused {
            await downloads.resume(id: item.id)
        }
    }

    func retryBookFailed() async {
        for item in failedItems {
            await downloads.resume(id: item.id)
        }
        banner.show("已重新加入下载队列", tone: .info)
    }

    func clearBookFailed() async {
        let targets = failedItems
        for item in targets {
            await downloads.cancelAndDelete(id: item.id)
        }
        if !targets.isEmpty {
            banner.show("已清空 \(targets.count) 章失败记录", tone: .info)
        }
    }
}
