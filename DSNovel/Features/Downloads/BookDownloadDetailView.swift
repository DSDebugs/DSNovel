import SwiftUI
import SwiftData

struct BookDownloadDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let bookID: String
    let bookTitle: String
    @Query private var allItems: [DownloadItem]

    @State private var downloadManager = DownloadManager.shared
    @State private var player = PlayerEngine.shared
    @State private var settings = AppSettingsStore.shared
    @State private var pendingDeleteItem: DownloadItem?
    @State private var showClearAllConfirm = false
    @State private var showClearFailedConfirm = false
    @State private var showAllActive = false
    @State private var showAllFailed = false
    @State private var cachedChapterIndexByID: [String: Int] = [:]
    @State private var cachedSortedCompletedItems: [DownloadItem] = []

    init(bookID: String, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        let targetID = bookID
        self._allItems = Query(
            filter: #Predicate<DownloadItem> { $0.bookID == targetID },
            sort: [SortDescriptor(\DownloadItem.createdAt)]
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let partitioned = DownloadsDataHelper.partitionItemsForBook(bookID, from: allItems)
        let completedSignature = DownloadsDataHelper.completedSignature(for: partitioned.completed, bookID: bookID)
        let completedItems = DownloadsDataHelper.displayCompletedItems(
            cached: cachedSortedCompletedItems,
            live: partitioned.completed
        )
        let visibleActive = showAllActive ? partitioned.active : Array(partitioned.active.prefix(8))
        let hiddenActiveCount = max(0, partitioned.active.count - 8)
        let visibleFailed = showAllFailed ? partitioned.failed : Array(partitioned.failed.prefix(8))
        let hiddenFailedCount = max(0, partitioned.failed.count - 8)
        let totalBytes = DownloadsDataHelper.totalLocalBytes(forBookID: bookID, in: allItems)
        let currentTier = downloadManager.effectiveQualityTier(forBookID: bookID)
        let currentTierRaw = currentTier.rawValue
        let tierLabel = DownloadsDataHelper.qualityTierLabel(for: currentTierRaw)
        let tierTitle = tierLabel.isEmpty ? currentTier.title : tierLabel
        let staleCount = DownloadsDataHelper.staleCount(forBookID: bookID, in: allItems, currentTierRaw: currentTierRaw)

        Group {
            if completedItems.isEmpty && partitioned.active.isEmpty && partitioned.failed.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无已下载章节",
                    messageOverride: "前往书籍详情页选择需要离线下载的章节",
                    primaryTitleOverride: "前往书籍页",
                    onPrimary: {
                        let ref = DownloadsDataHelper.buildBookRef(bookID: bookID, bookTitle: bookTitle, items: [], cachedChapterCount: cachedChapterIndexByID.count)
                        AppRouter.shared.open(.book(ref, preferDownloaded: false))
                    },
                    onSecondary: nil
                )
            } else {
                List {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已下载 \(completedItems.count) 章")
                                    .font(DSTypography.rowTitle)
                                Text("离线占用 \(formatBytes(totalBytes)) · 点击任意章节可直接离线播放")
                                    .font(DSTypography.numericCaption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                let ref = DownloadsDataHelper.buildBookRef(bookID: bookID, bookTitle: bookTitle, items: completedItems, cachedChapterCount: cachedChapterIndexByID.count)
                                AppRouter.shared.open(.book(ref, preferDownloaded: true))
                            } label: {
                                Text("书籍页")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, Spacing.s3)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.dsSurfaceGrouped))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(Color.dsSurfaceCard)

                        if staleCount > 0 {
                            HStack(spacing: Spacing.s2) {
                                Label("有 \(staleCount) 章为旧音质", systemImage: "arrow.triangle.2.circlepath")
                                    .font(DSTypography.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                                Spacer(minLength: Spacing.s2)
                                Button {
                                    let count = downloadManager.refreshStaleQualityItems(bookID: bookID)
                                    if count > 0 {
                                        DSHapticPolicy.fire(.success)
                                        BannerCenter.shared.show(
                                            "已按「\(tierTitle)」重新下载 \(count) 章（旧文件将在成功后覆盖）",
                                            kind: .success,
                                            bypassDeduplication: true
                                        )
                                    } else {
                                        BannerCenter.shared.show("本书暂无需要重下的旧音质章节", kind: .info)
                                    }
                                } label: {
                                    Text("按新音质重下（\(staleCount) 章）")
                                        .font(DSTypography.caption.weight(.semibold))
                                        .foregroundStyle(Color.dsOnAccent)
                                        .padding(.horizontal, Spacing.s3)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.dsAccent))
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Color.dsSurfaceCard)
                        }
                    }

                    if !partitioned.active.isEmpty {
                        Section {
                            HStack(spacing: Spacing.s2) {
                                Text("正在下载（\(partitioned.active.count) 章）")
                                    .font(DSTypography.cardTitle)
                                Spacer()
                                Button {
                                    Task { await downloadManager.pauseItems(forBookID: bookID) }
                                } label: {
                                    Text("暂停")
                                        .font(DSTypography.caption.weight(.semibold))
                                        .foregroundStyle(Color.dsAccent)
                                        .padding(.horizontal, Spacing.s2)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    downloadManager.resumePausedItems(forBookID: bookID)
                                } label: {
                                    Text("继续")
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
                                        HStack(spacing: 6) {
                                            Text(DownloadsDataHelper.activeStateLabel(for: item.state))
                                                .font(DSTypography.caption)
                                                .foregroundStyle(item.state == "waitingWiFi" ? .orange : .secondary)
                                            DownloadBitrateBadgeView(item: item)
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
                                                    fallbackProgress: 0.15,
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
                                    downloadManager.retryFailedItems(forBookID: bookID)
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

                            ForEach(visibleFailed) { item in
                                HStack(spacing: Spacing.s2) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.chapterTitle)
                                            .font(DSTypography.body)
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

                            if hiddenFailedCount > 0 {
                                Button {
                                    showAllFailed.toggle()
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text(showAllFailed ? "收起" : "展开其余 \(hiddenFailedCount) 章")
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

                    if !completedItems.isEmpty {
                        Section("已下载章节（\(completedItems.count)）") {
                            ForEach(completedItems) { item in
                                let isPlayingThis = (player.currentBookID == bookID && player.currentChapter?.id == item.chapterID)
                                let itemTierLabel = DownloadsDataHelper.bitrateBadgeText(forItem: item)
                                let itemIsStale = DownloadsDataHelper.isItemStale(item, currentTierRaw: currentTierRaw)
                                HStack(spacing: Spacing.s3) {
                                    Button {
                                        Task { await DownloadsDataHelper.playDownloadedChapterAsync(item, allBookItems: completedItems) }
                                    } label: {
                                        HStack(spacing: Spacing.s3) {
                                            if isPlayingThis {
                                                DSEqualizer(isPlaying: player.state == .playing)
                                                    .frame(width: 24)
                                            } else {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.title3)
                                                    .foregroundStyle(Color.dsAccent)
                                                    .frame(width: 24)
                                            }

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.chapterTitle)
                                                    .font(DSTypography.body.weight(isPlayingThis ? .semibold : .regular))
                                                    .foregroundStyle(isPlayingThis ? Color.dsAccent : .primary)
                                                    .lineLimit(2)
                                                HStack(spacing: 6) {
                                                    Text("已下载 · \(formatBytes(item.bytes))")
                                                        .font(DSTypography.numericCaption)
                                                        .foregroundStyle(.secondary)
                                                    if !itemTierLabel.isEmpty {
                                                        Text(itemTierLabel)
                                                            .font(DSTypography.caption2.weight(.medium))
                                                            .foregroundStyle(.secondary)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 1)
                                                            .background(Capsule().fill(Color.dsSurfaceGrouped))
                                                    }
                                                    if itemIsStale {
                                                        Text("旧音质")
                                                            .font(DSTypography.caption2.weight(.semibold))
                                                            .foregroundStyle(.orange)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 1)
                                                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                                                    }
                                                }
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Menu {
                                        if itemIsStale {
                                            Button {
                                                let count = downloadManager.refreshStaleQualityItems(
                                                    bookID: bookID,
                                                    chapterIDs: [item.chapterID]
                                                )
                                                if count > 0 {
                                                    DSHapticPolicy.fire(.success)
                                                    BannerCenter.shared.show(
                                                        "已按「\(tierTitle)」重新下载 \(count) 章（旧文件将在成功后覆盖）",
                                                        kind: .success,
                                                        bypassDeduplication: true
                                                    )
                                                } else {
                                                    let isReDL = downloadManager.isReDownloading(bookID: bookID, chapterID: item.chapterID)
                                                    let isStale = downloadManager.isChapterQualityStale(bookID: bookID, chapterID: item.chapterID)
                                                    let text = BookDetailModel.chapterDownloadBannerCopy(added: 0, isReDownloading: isReDL, isStale: isStale)
                                                    BannerCenter.shared.show(text, kind: .info)
                                                }
                                            } label: {
                                                Label("按「\(tierTitle)」重新下载", systemImage: "arrow.triangle.2.circlepath")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            pendingDeleteItem = item
                                        } label: {
                                            Label("删除离线文件", systemImage: "trash")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(minWidth: 44, minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("更多操作：\(item.chapterTitle)")
                                }
                                .listRowBackground(Color.dsSurfaceCard)
                                .onAppear {
                                    downloadManager.backfillAudioMetricsIfNeeded(for: item)
                                }
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
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.dsSurfaceGrouped)
            }
        }
        .background(Color.dsSurfaceGrouped)
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !(completedItems.isEmpty && partitioned.active.isEmpty && partitioned.failed.isEmpty) {
                    Button("清空全部", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
        }
        .alert(
            pendingDeleteItem.map { "确认删除「\($0.chapterTitle)」的离线文件（\(formatBytes($0.bytes))）？" } ?? "确认删除该章节离线文件？",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            )
        ) {
            Button("删除离线文件", role: .destructive) {
                if let target = pendingDeleteItem {
                    let removed = downloadManager.invalidateLocalFile(bookID: target.bookID, chapterID: target.chapterID)
                    DSHapticPolicy.fire(.warning)
                    BannerCenter.shared.show(
                        removed ? "已删除「\(target.chapterTitle)」离线文件" : "离线文件不存在，已同步状态",
                        kind: .info,
                        bypassDeduplication: true
                    )
                }
                pendingDeleteItem = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: {
            Text("删除后释放本地存储空间，再次收听需联网或重新下载。")
        }
        .alert(
            DownloadsDataHelper.clearAllAlertTitle(
                bookTitle: bookTitle,
                completedCount: completedItems.count,
                activeCount: partitioned.active.count,
                failedCount: partitioned.failed.count,
                formattedBytes: formatBytes(totalBytes)
            ),
            isPresented: $showClearAllConfirm
        ) {
            Button("清空全部记录", role: .destructive) {
                DSHapticPolicy.fire(.warning)
                downloadManager.removeDownloads(forBookID: bookID)
                BannerCenter.shared.show("已清空《\(bookTitle)》全部下载记录", kind: .info, bypassDeduplication: true)
            }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "确认清空本书 \(partitioned.failed.count) 章失败记录？",
            isPresented: $showClearFailedConfirm
        ) {
            Button("清空失败", role: .destructive) {
                let removed = downloadManager.removeFailedItems(forBookID: bookID)
                if removed > 0 {
                    DSHapticPolicy.fire(.warning)
                    BannerCenter.shared.show("已清空 \(removed) 章失败记录", kind: .info, bypassDeduplication: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后仅移除失败队列记录，不影响已下载的离线音频。")
        }
        .task(id: completedSignature) {
            if cachedChapterIndexByID.isEmpty {
                let chapters = await ChapterCacheStore.loadChaptersAsync(for: bookID) ?? []
                cachedChapterIndexByID = DownloadsDataHelper.chapterIndexMap(from: chapters)
            }
            cachedSortedCompletedItems = DownloadsDataHelper.sortedCompletedItems(
                partitioned.completed,
                indexByChapterID: cachedChapterIndexByID
            )
        }
        .onAppear {
            if downloadManager.modelContext == nil {
                downloadManager.modelContext = modelContext
            }
            downloadManager.reconcileCompletedFilesIfNeeded()
        }
    }
}
