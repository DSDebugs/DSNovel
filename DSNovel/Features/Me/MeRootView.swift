import SwiftUI
import SwiftData

struct MeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettingsStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var showClearCacheConfirm = false

    init() {}

    var body: some View {
        List {
            Section {
                SourceHealthCard(
                    summary: sourceStore.healthSummary,
                    isChecking: sourceStore.isCheckingAll,
                    onOpenSourceList: { AppRouter.shared.open(.sourceList) },
                    onCheckAll: {
                        Task {
                            await sourceStore.checkSources()
                            DSHapticPolicy.fire(.success)
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

            Section("播放") {
                PlaybackPrefsView(settings: settings)
            }

            Section("下载与存储") {
                StoragePrefsView(
                    settings: settings,
                    manualBytes: downloadManager.totalManualDownloadedBytes(),
                    tempBytes: downloadManager.totalPrecacheAndTempBytes(),
                    onOpenDownloads: { AppRouter.shared.open(.downloads) },
                    onClearTempCache: { showClearCacheConfirm = true }
                )
            }

            Section("外观与交互") {
                AppearancePrefsView(settings: settings)
            }

            Section("关于") {
                AboutView(onResetAll: {
                    settings.resetAll()
                    BannerCenter.shared.show("已重置所有偏好设置", kind: .success)
                })
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.dsSurfaceGrouped)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "确认清理预缓存音频与封面临时缓存？",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("清理临时缓存", role: .destructive) {
                downloadManager.clearTemporaryCaches()
                DSHapticPolicy.fire(.success)
                BannerCenter.shared.show("已清理临时缓存", kind: .success)
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            sourceStore.modelContext = modelContext
            downloadManager.modelContext = modelContext
        }
    }
}
