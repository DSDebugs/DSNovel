import SwiftUI
import SwiftData

struct BookDownloadDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let bookID: String
    let bookTitle: String
    @Query(sort: [SortDescriptor(\DownloadItem.createdAt)])
    private var allItems: [DownloadItem]

    @State private var downloadManager = DownloadManager.shared
    @State private var player = PlayerEngine.shared
    @State private var pendingDeleteItem: DownloadItem?
    @State private var showClearAllConfirm = false

    init(bookID: String, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let partitioned = DownloadsDataHelper.partitionItemsForBook(bookID, from: allItems)
        let completedItems = partitioned.completed
        let totalBytes = completedItems.reduce(Int64(0)) { $0 + $1.bytes }

        Group {
            if completedItems.isEmpty && partitioned.active.isEmpty && partitioned.failed.isEmpty {
                DSStateView(
                    kind: .empty,
                    onPrimary: {
                        let ref = DownloadsDataHelper.buildBookRef(bookID: bookID, bookTitle: bookTitle, items: [])
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
                                let ref = DownloadsDataHelper.buildBookRef(bookID: bookID, bookTitle: bookTitle, items: completedItems)
                                AppRouter.shared.open(.book(ref, preferDownloaded: true))
                            } label: {
                                Text("书籍页")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, Spacing.s3)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.dsSurfaceGrouped))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !partitioned.active.isEmpty {
                        Section("正在下载（\(partitioned.active.count) 章）") {
                            ForEach(partitioned.active) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.chapterTitle)
                                            .font(DSTypography.body)
                                            .lineLimit(1)
                                        Text(item.state == "waitingWiFi" ? "等待 Wi-Fi" : "下载中")
                                            .font(DSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    DSProgress(
                                        value: downloadManager.itemProgress[item.id] ?? 0.15,
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
                                    downloadManager.retryFailedItems(forBookID: bookID)
                                    BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                                }
                                .font(DSTypography.caption.weight(.semibold))
                            }
                            ForEach(partitioned.failed) { item in
                                HStack {
                                    Text(item.chapterTitle)
                                        .font(DSTypography.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("重试") {
                                        downloadManager.retryFailedItem(item)
                                    }
                                    .font(DSTypography.caption)
                                    .foregroundStyle(Color.dsAccent)
                                }
                            }
                        }
                    }

                    if !completedItems.isEmpty {
                        Section("已下载章节（\(completedItems.count)）") {
                            ForEach(completedItems) { item in
                                let isPlayingThis = (player.currentBookID == bookID && player.currentChapter?.id == item.chapterID)
                                HStack(spacing: Spacing.s3) {
                                    Button {
                                        DownloadsDataHelper.playDownloadedChapter(item, allBookItems: completedItems)
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

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.chapterTitle)
                                                    .font(DSTypography.body.weight(isPlayingThis ? .semibold : .regular))
                                                    .foregroundStyle(isPlayingThis ? Color.dsAccent : .primary)
                                                    .lineLimit(2)
                                                Text("已下载 · \(formatBytes(item.bytes))")
                                                    .font(DSTypography.numericCaption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        pendingDeleteItem = item
                                    } label: {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.green)
                                            .frame(width: 36, height: 36)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("已下载，点击删除此章离线文件")
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
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !completedItems.isEmpty {
                    Button("清空全部", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDeleteItem.map { "确认删除「\($0.chapterTitle)」的离线文件（\(formatBytes($0.bytes))）？" } ?? "确认删除该章节离线文件？",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            titleVisibility: .visible
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
        .confirmationDialog(
            "确认清空《\(bookTitle)》全部 \(completedItems.count) 章离线音频（\(formatBytes(totalBytes))）？",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("清空全部已下载章节", role: .destructive) {
                DSHapticPolicy.fire(.warning)
                downloadManager.removeDownloads(forBookID: bookID)
                BannerCenter.shared.show("已清空《\(bookTitle)》全部离线章节", kind: .info, bypassDeduplication: true)
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            downloadManager.modelContext = modelContext
            downloadManager.reconcileCompletedFiles()
        }
    }
}
