import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettingsStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var showClearCacheConfirm = false
    @State private var backupDocument: LibraryBackupDocument?
    @State private var backupDefaultFilename: String = "DSNovel-Backup"
    @State private var pendingExportBookCount: Int = 0
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false

    init() {}

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private var clearCacheConfirmButtonTitle: String {
        if let bytes = downloadManager.cachedTemporaryCacheBytes, bytes > 0 {
            return "清理 \(formatBytes(bytes))"
        }
        return "清理缓存"
    }

    private func startExportBackup() {
        do {
            let result = try LibraryBackupCodec.exportDocument(context: modelContext)
            backupDocument = result.document
            backupDefaultFilename = result.defaultFilename
            pendingExportBookCount = result.bookCount
            showBackupExporter = true
        } catch {
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show("导出备份失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func handleBackupExportResult(_ result: Result<URL, Error>) {
        backupDocument = nil
        switch result {
        case .success:
            DSHapticPolicy.fire(.success)
            BannerCenter.shared.show("已导出 \(pendingExportBookCount) 本书架与进度备份", kind: .success)
        case .failure(let error):
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show("导出备份失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func handleBackupImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let summary = try LibraryBackupCodec.importJSON(data, into: modelContext)
                LibraryStore.shared.refreshNow()
                ChapterProgressCache.shared.resetMemoryForTesting()
                DSHapticPolicy.fire(.success)
                if summary.importedBookCount > 0 || summary.updatedBookCount > 0 {
                    BannerCenter.shared.show(
                        "已恢复备份：新增 \(summary.importedBookCount) 本、更新 \(summary.updatedBookCount) 本书目",
                        kind: .success
                    )
                } else if summary.importedProgressCount > 0 {
                    BannerCenter.shared.show(
                        "已恢复 \(summary.importedProgressCount) 条章节播放进度",
                        kind: .success
                    )
                } else {
                    BannerCenter.shared.show(
                        "备份已是最新，共核对 \(summary.totalBookCount) 本书目",
                        kind: .info
                    )
                }
            } catch {
                DSHapticPolicy.fire(.error)
                BannerCenter.shared.show("恢复备份失败：\(error.localizedDescription)", kind: .error)
            }
        case .failure(let error):
            DSHapticPolicy.fire(.error)
            BannerCenter.shared.show("读取备份文件失败：\(error.localizedDescription)", kind: .error)
        }
    }

    var body: some View {
        let _ = settings.nightDimEnabled
        ScrollViewReader { proxy in
            List {
                Section {
                    SourceHealthCard(
                        summary: sourceStore.healthSummary,
                        isChecking: sourceStore.isCheckingAll,
                        onOpenSourceList: { AppRouter.shared.open(.sourceList) },
                        onCheckAll: {
                            Task {
                                await sourceStore.checkSources()
                                let s = sourceStore.healthSummary
                                DSHapticPolicy.fire(s.unavailableCount > 0 ? .warning : .success)
                                BannerCenter.shared.show(
                                    "检测完成：可用 \(s.availableCount) · 需登录 \(s.needAuthCount) · 异常 \(s.unavailableCount)",
                                    kind: s.unavailableCount > 0 ? .warning : .success
                                )
                            }
                        },
                        onHandleAttention: {
                            if let first = sourceStore.needAttention.first {
                                AppRouter.shared.open(.sourceDetail(id: first.id, focus: nil))
                            } else {
                                AppRouter.shared.open(.sourceList)
                            }
                        },
                        onImportSource: { AppRouter.shared.open(.sourceImport) }
                    )
                    .id("meTop")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    PlaybackPrefsView(settings: settings)
                } header: {
                    Text("听书")
                } footer: {
                    Text("默认倍速仅用于首次播放的新书；每本书会自动记住自己的倍速。跳过片头片尾请在播放页「更多」中按书单独设置。")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                }

                Section("下载与存储") {
                    StoragePrefsView(
                        settings: settings,
                        manualBytes: downloadManager.cachedManualDownloadedBytes,
                        tempBytes: downloadManager.cachedTemporaryCacheBytes,
                        onOpenDownloads: { AppRouter.shared.open(.downloads) },
                        onClearTempCache: { showClearCacheConfirm = true },
                        onExportBackup: { startExportBackup() },
                        onImportBackup: { showBackupImporter = true }
                    )
                }

                Section("外观与交互") {
                    AppearancePrefsView(settings: settings)
                }

                Section("关于") {
                    NavigationLink(value: Route.about) {
                        DSSettingsRow(
                            icon: "info.circle",
                            title: "关于 DSNovel",
                            valueText: AuthorInfo.appVersionDisplay,
                            style: .value
                        )
                    }
                    .listRowBackground(Color.dsSurfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
            .contentMargins(.top, Spacing.s2, for: .scrollContent)
            .contentMargins(.bottom, Spacing.s4, for: .scrollContent)
            .onChange(of: ScrollToTopCenter.shared.count(for: .me)) { _, _ in
                withAnimation(Motion.snappy) {
                    proxy.scrollTo("meTop", anchor: .top)
                }
            }
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清理缓存？", isPresented: $showClearCacheConfirm) {
            Button("取消", role: .cancel) {}
            Button(clearCacheConfirmButtonTitle, role: .destructive) {
                downloadManager.clearTemporaryCaches()
                DSHapticPolicy.fire(.success)
                BannerCenter.shared.show("已清理预缓存与封面缓存", kind: .success)
            }
        } message: {
            Text("将清理预缓存音频与封面临时缓存，不影响已下载的离线章节与书架数据。")
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: backupDefaultFilename
        ) { result in
            handleBackupExportResult(result)
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImportResult(result)
        }
        .onAppear {
            sourceStore.modelContext = modelContext
            downloadManager.modelContext = modelContext
            if let notice = PerBookSkipMigration.consumePendingNoticeIfNeeded() {
                BannerCenter.shared.show(notice, kind: .info)
            }
        }
        .task {
            await downloadManager.refreshCachedStorageMetrics()
        }
    }
}
