import SwiftUI
import SwiftData

struct PlayerDownloadSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [DownloadItem]

    let player: PlayerEngine
    @State private var downloadManager = DownloadManager.shared
    @State private var settings = AppSettingsStore.shared
    @State private var customStartChapter: Int = 1
    @State private var customEndChapter: Int = 30
    @State private var showClearConfirm = false
    private let onOpenGlobalDownloads: () -> Void
    private let onClose: () -> Void

    init(
        player: PlayerEngine = .shared,
        onOpenGlobalDownloads: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.player = player
        self.onOpenGlobalDownloads = onOpenGlobalDownloads
        self.onClose = onClose
        let curOneBased = max(1, player.currentChapterOneBasedIndex)
        let total = max(1, player.chapterQueue.count)
        let targetBookID = player.currentBookID ?? ""
        self._allItems = Query(
            filter: #Predicate<DownloadItem> { $0.bookID == targetBookID },
            sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]
        )
        self._customStartChapter = State(initialValue: curOneBased)
        self._customEndChapter = State(initialValue: min(total, curOneBased + 29))
    }

    private func fmtBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    private func enqueueSlice(from startOneBased: Int, to endOneBased: Int) {
        guard let book = player.currentBook, !player.chapterQueue.isEmpty else { return }
        let s = max(0, startOneBased - 1)
        let e = min(player.chapterQueue.count, endOneBased)
        guard s < e else { return }
        let slice = Array(player.chapterQueue[s..<e])
        do {
            let added = try downloadManager.enqueueChaptersWithCheck(slice, for: book, kind: "manual")
            DSHapticPolicy.fire(.success)
            if added > 0 {
                BannerCenter.shared.show("已加入下载队列 \(added) 章", kind: .success)
            } else {
                BannerCenter.shared.show("所选章节已在队列或已下载", kind: .info)
            }
        } catch {
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show(error.localizedDescription, kind: .error)
        }
    }

    var body: some View {
        let _ = downloadManager.stateVersion
        let bookID = player.currentBookID
        let partitioned = DownloadsDataHelper.partitionItemsForBook(bookID, from: allItems)
        let totalCount = max(player.chapterQueue.count, 1)
        let curIndex = max(1, player.currentChapterOneBasedIndex)
        let bookBytes = DownloadsDataHelper.totalLocalBytes(forBookID: bookID, in: allItems)
        let precacheText = fmtBytes(downloadManager.cachedPrecacheBytes)
        let freeDiskText = downloadManager.cachedAvailableDiskBytes.map(fmtBytes) ?? "计算中..."
        let currentTier = bookID.map { downloadManager.effectiveQualityTier(forBookID: $0) } ?? settings.audioQualityTier
        let currentTierRaw = currentTier.rawValue
        let tierLabel = DownloadsDataHelper.qualityTierLabel(for: currentTierRaw)
        let tierTitle = tierLabel.isEmpty ? currentTier.title : tierLabel
        let staleCount = DownloadsDataHelper.staleCount(forBookID: bookID, in: allItems, currentTierRaw: currentTierRaw)

        DSSheetScaffold(title: "章节离线下载", onClose: onClose) {
            List {
                Section("本书离线概览") {
                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        HStack {
                            Text(player.currentBook?.title ?? "当前书籍")
                                .font(DSTypography.rowTitle)
                            Spacer()
                            Text("已下载 \(partitioned.completed.count) / \(player.chapterQueue.count) 章")
                                .font(DSTypography.numericCaption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                        }
                        Text("本书占用 \(fmtBytes(bookBytes)) · 预缓存 \(precacheText) · 设备剩余 \(freeDiskText)")
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.s1)

                    if staleCount > 0 {
                        HStack(spacing: Spacing.s2) {
                            Label("有 \(staleCount) 章为旧音质", systemImage: "arrow.triangle.2.circlepath")
                                .font(DSTypography.caption.weight(.medium))
                                .foregroundStyle(.orange)
                            Spacer(minLength: Spacing.s2)
                            Button("全部按新音质重下") {
                                if let bid = bookID {
                                    let count = downloadManager.refreshStaleQualityItems(bookID: bid)
                                    if count > 0 {
                                        DSHapticPolicy.fire(.success)
                                        BannerCenter.shared.show(
                                            "已按「\(tierTitle)」重新下载 \(count) 章（旧文件将在成功后覆盖）",
                                            kind: .success
                                        )
                                    } else {
                                        BannerCenter.shared.show("当前没有需要重下的旧音质章节", kind: .info)
                                    }
                                }
                            }
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsOnAccent)
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.dsAccent))
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    Toggle("仅在 Wi-Fi 下下载", isOn: $settings.wifiOnlyDownload)
                        .onChange(of: settings.wifiOnlyDownload) { _, newValue in
                            Task { await downloadManager.handleWiFiOnlySettingChanged(newValue) }
                        }

                    Toggle("离线时目录仅显示已下载章节", isOn: $settings.onlyPlayDownloadedInOffline)
                }

                Section("快捷批量下载（从第 \(curIndex) 章起）") {
                    Button {
                        enqueueSlice(from: curIndex, to: curIndex)
                    } label: {
                        Label("下载当前章节（第 \(curIndex) 章）", systemImage: "arrow.down.circle")
                    }

                    Button {
                        enqueueSlice(from: curIndex, to: min(totalCount, curIndex + 9))
                    } label: {
                        Label("下载后续 10 章（第 \(curIndex)–\(min(totalCount, curIndex + 9)) 章）", systemImage: "arrow.down.to.line")
                    }

                    Button {
                        enqueueSlice(from: curIndex, to: min(totalCount, curIndex + 29))
                    } label: {
                        Label("下载后续 30 章（第 \(curIndex)–\(min(totalCount, curIndex + 29)) 章）", systemImage: "square.and.arrow.down.on.square")
                    }

                    Button {
                        enqueueSlice(from: curIndex, to: totalCount)
                    } label: {
                        Label("下载后续全部章节（第 \(curIndex)–\(totalCount) 章）", systemImage: "tray.and.arrow.down.fill")
                    }
                }

                Section("自定义章节区间下载（共 \(totalCount) 章）") {
                    Stepper("起始章节：第 \(customStartChapter) 章", value: $customStartChapter, in: 1...totalCount)
                    Stepper("结束章节：第 \(max(customStartChapter, customEndChapter)) 章", value: $customEndChapter, in: max(1, customStartChapter)...totalCount)

                    Button {
                        enqueueSlice(from: customStartChapter, to: max(customStartChapter, customEndChapter))
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("立即下载第 \(customStartChapter)–\(max(customStartChapter, customEndChapter)) 章")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(Color.dsAccent)
                    }
                }

                if !partitioned.active.isEmpty {
                    Section {
                        HStack {
                            Text("下载队列进行中（\(partitioned.active.count) 章）")
                                .font(DSTypography.cardTitle)
                            Spacer()
                            Button("暂停本书") {
                                if let bid = bookID {
                                    Task { await downloadManager.pauseItems(forBookID: bid) }
                                }
                            }
                            .font(DSTypography.caption)
                            Button("继续本书") {
                                if let bid = bookID {
                                    downloadManager.resumePausedItems(forBookID: bid)
                                }
                            }
                            .font(DSTypography.caption)
                        }

                        ForEach(partitioned.active.prefix(8)) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.chapterTitle)
                                        .font(DSTypography.body)
                                        .lineLimit(1)
                                    Text(item.state == "waitingWiFi" ? "等待 Wi-Fi 连接" : (item.state == "paused" ? "已暂停" : "正在下载"))
                                        .font(DSTypography.caption)
                                        .foregroundStyle(item.state == "waitingWiFi" ? .orange : .secondary)
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
                            Button("重试本书") {
                                if let bid = bookID {
                                    downloadManager.retryFailedItems(forBookID: bid)
                                    BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                                }
                            }
                            .font(DSTypography.caption.weight(.semibold))
                        }

                        ForEach(partitioned.failed.prefix(8)) { item in
                            HStack {
                                Text(item.chapterTitle)
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

                Section("存储与全局管理") {
                    if !partitioned.completed.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清理本书全部离线章节（\(partitioned.completed.count) 章）", systemImage: "trash")
                        }
                    }

                    Button {
                        onClose()
                        onOpenGlobalDownloads()
                    } label: {
                        Label("打开全局下载与存储管理", systemImage: "internaldrive")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .alert(
                "确认清理《\(player.currentBook?.title ?? "本书")》全部 \(partitioned.completed.count) 章离线音频（\(fmtBytes(bookBytes))）？",
                isPresented: $showClearConfirm
            ) {
                Button("清理本书离线章节", role: .destructive) {
                    if let bid = bookID {
                        DSHapticPolicy.fire(.warning)
                        let bookTitle = player.currentBook?.title ?? "本书"
                        let pending = downloadManager.removeDownloads(forBookID: bid, deferred: true, scheduleTimer: false)
                        BannerCenter.shared.showUndo(
                            "已清理《\(bookTitle)》离线章节",
                            onUndo: { pending.cancel() },
                            onCommit: { pending.commitNow() }
                        )
                        onClose()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear {
                downloadManager.modelContext = modelContext
            }
            .task {
                await downloadManager.refreshCachedStorageMetrics()
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
}
