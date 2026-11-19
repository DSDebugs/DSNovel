import SwiftUI
import SwiftData

struct MeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettingsStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var showClearCacheConfirm = false

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

    var body: some View {
        let _ = settings.nightDimEnabled
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
                    onClearTempCache: { showClearCacheConfirm = true }
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
        .contentMargins(.bottom, DSBottomBar.totalHeight + Spacing.s4, for: .scrollContent)
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
