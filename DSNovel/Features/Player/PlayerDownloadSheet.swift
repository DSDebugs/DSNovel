import SwiftUI
import SwiftData

struct PlayerDownloadSheet: View {
    private enum RangeInputField: Hashable {
        case start
        case end
    }

    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [DownloadItem]

    let player: PlayerEngine
    @State private var downloadManager = DownloadManager.shared
    @State private var settings = AppSettingsStore.shared
    @State private var customStartChapter: Int = 1
    @State private var customEndChapter: Int = 30
    @State private var startInputText: String = "1"
    @State private var endInputText: String = "30"
    @State private var showClearConfirm = false
    @State private var showClearFailedConfirm = false
    @State private var showAllActive = false
    @State private var showAllFailed = false
    @FocusState private var focusedRangeField: RangeInputField?
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
        let initialEnd = min(total, curOneBased + 29)
        let targetBookID = player.currentBookID ?? ""
        self._allItems = Query(
            filter: #Predicate<DownloadItem> { $0.bookID == targetBookID },
            sort: [SortDescriptor(\DownloadItem.createdAt, order: .reverse)]
        )
        self._customStartChapter = State(initialValue: curOneBased)
        self._customEndChapter = State(initialValue: initialEnd)
        self._startInputText = State(initialValue: String(curOneBased))
        self._endInputText = State(initialValue: String(initialEnd))
    }

    private func fmtBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    private func commitRangeInputs(totalCount: Int) {
        let clamped = DownloadsDataHelper.clampedRange(
            startText: startInputText,
            endText: endInputText,
            fallbackStart: customStartChapter,
            fallbackEnd: customEndChapter,
            totalCount: totalCount
        )
        customStartChapter = clamped.start
        customEndChapter = clamped.end
        startInputText = String(clamped.start)
        endInputText = String(clamped.end)
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
        let visibleActive = showAllActive ? partitioned.active : Array(partitioned.active.prefix(8))
        let hiddenActiveCount = max(0, partitioned.active.count - 8)
        let visibleFailed = showAllFailed ? partitioned.failed : Array(partitioned.failed.prefix(8))
        let hiddenFailedCount = max(0, partitioned.failed.count - 8)
        let totalRecordCount = partitioned.completed.count + partitioned.active.count + partitioned.failed.count
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
                            Button {
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
                            } label: {
                                Text("全部按新音质重下")
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
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        enqueueSlice(from: curIndex, to: min(totalCount, curIndex + 9))
                    } label: {
                        Label("下载后续 10 章（第 \(curIndex)–\(min(totalCount, curIndex + 9)) 章）", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        enqueueSlice(from: curIndex, to: min(totalCount, curIndex + 29))
                    } label: {
                        Label("下载后续 30 章（第 \(curIndex)–\(min(totalCount, curIndex + 29)) 章）", systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        enqueueSlice(from: curIndex, to: totalCount)
                    } label: {
                        Label("下载后续全部章节（第 \(curIndex)–\(totalCount) 章）", systemImage: "tray.and.arrow.down.fill")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section("自定义章节区间下载（共 \(totalCount) 章）") {
                    HStack(spacing: Spacing.s2) {
                        Text("起始章节")
                            .font(DSTypography.body)
                        Spacer()
                        TextField("1", text: $startInputText)
                            .keyboardType(.numberPad)
                            .submitLabel(.done)
                            .multilineTextAlignment(.center)
                            .focused($focusedRangeField, equals: .start)
                            .frame(width: 64, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.dsSurfaceGrouped))
                            .onSubmit {
                                commitRangeInputs(totalCount: totalCount)
                            }
                        Stepper("", value: $customStartChapter, in: 1...totalCount)
                            .labelsHidden()
                    }
                    .onChange(of: customStartChapter) { _, newValue in
                        let clampedStart = min(max(1, newValue), totalCount)
                        if customStartChapter != clampedStart {
                            customStartChapter = clampedStart
                        }
                        if customEndChapter < clampedStart {
                            customEndChapter = clampedStart
                            endInputText = String(clampedStart)
                        }
                        startInputText = String(clampedStart)
                    }

                    HStack(spacing: Spacing.s2) {
                        Text("结束章节")
                            .font(DSTypography.body)
                        Spacer()
                        TextField("\(totalCount)", text: $endInputText)
                            .keyboardType(.numberPad)
                            .submitLabel(.done)
                            .multilineTextAlignment(.center)
                            .focused($focusedRangeField, equals: .end)
                            .frame(width: 64, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.dsSurfaceGrouped))
                            .onSubmit {
                                commitRangeInputs(totalCount: totalCount)
                            }
                        Stepper("", value: $customEndChapter, in: max(1, customStartChapter)...totalCount)
                            .labelsHidden()
                    }
                    .onChange(of: customEndChapter) { _, newValue in
                        let clampedEnd = min(max(customStartChapter, newValue), totalCount)
                        if customEndChapter != clampedEnd {
                            customEndChapter = clampedEnd
                        }
                        endInputText = String(clampedEnd)
                    }
                    .onChange(of: focusedRangeField) { oldFocus, newFocus in
                        if oldFocus != nil && oldFocus != newFocus {
                            commitRangeInputs(totalCount: totalCount)
                        }
                    }

                    Button {
                        focusedRangeField = nil
                        commitRangeInputs(totalCount: totalCount)
                        enqueueSlice(from: customStartChapter, to: max(customStartChapter, customEndChapter))
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("立即下载第 \(customStartChapter)–\(max(customStartChapter, customEndChapter)) 章")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundStyle(Color.dsAccent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !partitioned.active.isEmpty {
                    Section {
                        HStack(spacing: Spacing.s2) {
                            Text("下载队列进行中（\(partitioned.active.count) 章）")
                                .font(DSTypography.cardTitle)
                            Spacer()
                            Button {
                                if let bid = bookID {
                                    Task { await downloadManager.pauseItems(forBookID: bid) }
                                }
                            } label: {
                                Text("暂停本书")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, Spacing.s2)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                if let bid = bookID {
                                    downloadManager.resumePausedItems(forBookID: bid)
                                }
                            } label: {
                                Text("继续本书")
                                    .font(DSTypography.caption.weight(.semibold))
                                    .foregroundStyle(Color.dsAccent)
                                    .padding(.horizontal, Spacing.s2)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(visibleActive) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.chapterTitle)
                                        .font(DSTypography.body)
                                        .lineLimit(1)
                                    Text(DownloadsDataHelper.activeStateLabel(for: item.state))
                                        .font(DSTypography.caption)
                                        .foregroundStyle(item.state == "waitingWiFi" ? .orange : .secondary)
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
                                if let bid = bookID {
                                    downloadManager.retryFailedItems(forBookID: bid)
                                    BannerCenter.shared.show("已重新加入下载队列", kind: .info)
                                }
                            } label: {
                                Text("重试本书")
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
                        }
                    }
                }

                Section("存储与全局管理") {
                    if !(partitioned.completed.isEmpty && partitioned.active.isEmpty && partitioned.failed.isEmpty) {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label(
                                partitioned.completed.isEmpty
                                    ? "清理本书全部下载记录（\(totalRecordCount) 章）"
                                    : "清理本书全部离线与下载记录（\(totalRecordCount) 章）",
                                systemImage: "trash"
                            )
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onClose()
                        onOpenGlobalDownloads()
                    } label: {
                        Label("打开全局下载与存储管理", systemImage: "internaldrive")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .alert(
                DownloadsDataHelper.clearAllAlertTitle(
                    bookTitle: player.currentBook?.title ?? "本书",
                    completedCount: partitioned.completed.count,
                    activeCount: partitioned.active.count,
                    failedCount: partitioned.failed.count,
                    formattedBytes: fmtBytes(bookBytes)
                ),
                isPresented: $showClearConfirm
            ) {
                Button("清理全部记录", role: .destructive) {
                    if let bid = bookID {
                        DSHapticPolicy.fire(.warning)
                        let bookTitle = player.currentBook?.title ?? "本书"
                        let pending = downloadManager.removeDownloads(forBookID: bid, deferred: true, scheduleTimer: false)
                        BannerCenter.shared.showUndo(
                            "已清理《\(bookTitle)》下载记录",
                            onUndo: { pending.cancel() },
                            onCommit: { pending.commitNow() }
                        )
                        onClose()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert(
                "确认清空本书 \(partitioned.failed.count) 章失败记录？",
                isPresented: $showClearFailedConfirm
            ) {
                Button("清空失败", role: .destructive) {
                    if let bid = bookID {
                        let removed = downloadManager.removeFailedItems(forBookID: bid)
                        if removed > 0 {
                            DSHapticPolicy.fire(.warning)
                            BannerCenter.shared.show("已清空 \(removed) 章失败记录", kind: .info, bypassDeduplication: true)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清空后仅移除失败队列记录，不影响已下载的离线音频。")
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
