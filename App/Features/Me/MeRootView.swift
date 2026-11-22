import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 「我的」根视图（1:1 复刻 v2.8：顶部 SourceHealthCard + 快捷内联播放与下载/外观分组 + 保留 v3.0 音质作用域与内置解析器默认隐藏）
struct MeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings

    @State private var totalSourcesCount = 0
    @State private var enabledSourcesCount = 0
    @State private var needLoginSourcesCount = 0

    private var isEffectiveDarkAppearance: Bool {
        switch settings.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    var body: some View {
        @Bindable var bindable = settings
        List {
            Section {
                SourceHealthCard(
                    totalCount: totalSourcesCount,
                    enabledCount: enabledSourcesCount,
                    needLoginCount: needLoginSourcesCount,
                    onOpenSourceList: { router.push(.sources) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                if container.isDiscoverSourceXimalaya {
                    Picker("默认播放音质", selection: $bindable.preferredQuality) {
                        ForEach(AudioQualityTier.availableTiers(builtinParserUnlocked: container.canUseUltraHighQuality)) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .onChange(of: settings.preferredQuality) { _, _ in
                        container.syncSettingsToEngines()
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }

                Toggle("仅在 Wi-Fi 下下载", isOn: $bindable.wifiOnlyDownload)
                    .tint(DSColors.accent)
                    .onChange(of: settings.wifiOnlyDownload) { _, _ in
                        container.syncSettingsToEngines()
                    }
                    .listRowBackground(DSColors.surfaceCard)

                navRow(
                    icon: "arrow.down.circle",
                    title: "下载管理",
                    detail: ByteCountFormatter.string(fromByteCount: downloads.totalDiskBytes, countStyle: .file)
                ) {
                    router.push(.downloads)
                }
                .listRowBackground(DSColors.surfaceCard)

                navRow(icon: "waveform", title: "更多播放偏好", detail: "") {
                    router.push(.playbackPrefs)
                }
                .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("播放与下载")
            } footer: {
                Text("跳过片头片尾请在播放页「更多」中按单本书籍单独设置。")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }

            Section {
                Picker("主题", selection: $bindable.themeMode) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(DSColors.surfaceCard)

                Toggle("夜间降亮遮罩", isOn: $bindable.nightDimEnabled)
                    .tint(DSColors.accent)
                    .disabled(!isEffectiveDarkAppearance)
                    .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("外观")
            } footer: {
                if !isEffectiveDarkAppearance {
                    Text("夜间降亮遮罩仅在深色外观下生效，切换至深色主题后可开启。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            Section("存储与诊断") {
                navRow(icon: "externaldrive", title: "存储、备份与还原", detail: "") {
                    router.push(.storagePrefs)
                }
                .listRowBackground(DSColors.surfaceCard)

                navRow(icon: "stethoscope", title: "脱敏诊断日志", detail: "") {
                    router.push(.diagnostics)
                }
                .listRowBackground(DSColors.surfaceCard)

                if settings.builtinParserUnlocked {
                    navRow(icon: "cpu", title: "内置音频解析器", detail: "独立管理") {
                        router.push(.builtinParser)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }
            }

            Section("关于") {
                navRow(icon: "info.circle", title: "关于 DSNovel", detail: AuthorInfo.appVersionDisplay) {
                    router.push(.about)
                }
                .listRowBackground(DSColors.surfaceCard)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("me_root")
        .background(DSColors.surfaceGrouped)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await refreshSourceSummary() }
        }
        .task {
            await refreshSourceSummary()
        }
    }

    private func refreshSourceSummary() async {
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        totalSourcesCount = all.count
        var enabled = 0
        var needLogin = 0
        for item in all {
            if item.meta.isEnabled { enabled += 1 }
            if item.meta.loginURL != nil || item.meta.methods.contains("checkLogin") {
                needLogin += 1
            }
        }
        enabledSourcesCount = enabled
        needLoginSourcesCount = needLogin
    }

    private func navRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
