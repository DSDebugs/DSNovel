import SwiftUI
import SwiftData

struct MeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettingsStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var downloadManager = DownloadManager.shared

    init() {}

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
                        onOpenDownloads: { AppRouter.shared.open(.downloads) }
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
