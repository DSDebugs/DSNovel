import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 「我的」根视图（一屏均衡布局：书源概览卡 + 播放与下载 + 外观 + 系统）
struct MeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings

    @State private var totalSourcesCount = 0
    @State private var enabledSourcesCount = 0
    @State private var needLoginSourcesCount = 0
    @State private var hasXimalayaSource = false
    @State private var totalStorageBytes: Int64 = 0

    private var isEffectiveDarkAppearance: Bool {
        switch settings.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    private var sourceStatusSubtitle: String {
        guard hasXimalayaSource else {
            return "共 \(totalSourcesCount) 个书源 · \(needLoginSourcesCount) 个支持登录"
        }
        switch container.sourceAuth.status(for: AppContainer.ximalayaSourceID) {
        case .loggedIn:
            return "共 \(totalSourcesCount) 个书源 · 喜马拉雅已登录"
        case .loggedOut:
            return "共 \(totalSourcesCount) 个书源 · 喜马拉雅未登录"
        case .checking, .unknown:
            return "共 \(totalSourcesCount) 个书源 · \(needLoginSourcesCount) 个支持登录"
        }
    }

    private var playbackPrefsSummary: String {
        let autoText = settings.autoPlayNextChapter ? "连播开" : "连播关"
        if settings.precacheNextCount > 0 {
            return "\(autoText) · 预缓存 \(settings.precacheNextCount) 章"
        }
        return "\(autoText) · 不预缓存"
    }

    private var storageDetailText: String {
        guard totalStorageBytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: totalStorageBytes, countStyle: .file)
    }

    var body: some View {
        @Bindable var bindable = settings
        List {
            Section {
                SourceHealthCard(
                    totalCount: totalSourcesCount,
                    enabledCount: enabledSourcesCount,
                    needLoginCount: needLoginSourcesCount,
                    statusSubtitle: sourceStatusSubtitle,
                    onOpenSourceList: { router.push(.sources) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("播放与下载") {
                Toggle(isOn: $bindable.wifiOnlyDownload) {
                    HStack(spacing: DSSpacing.sm) {
                        meRowIcon("wifi")
                        Text("仅在 Wi-Fi 下下载")
                            .foregroundStyle(DSColors.inkPrimary)
                    }
                }
                .tint(DSColors.accent)
                .onChange(of: settings.wifiOnlyDownload) { _, _ in
                    container.syncSettingsToEngines()
                }
                .frame(minHeight: 36)
                .listRowBackground(DSColors.surfaceCard)

                navRow(
                    icon: "ellipsis",
                    title: "更多播放偏好",
                    detail: playbackPrefsSummary,
                    useBadgeIcon: true
                ) {
                    router.push(.playbackPrefs)
                }
                .listRowBackground(DSColors.surfaceCard)
            }

            Section {
                Picker("主题", selection: $bindable.themeMode) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(DSColors.surfaceCard)

                Toggle(isOn: $bindable.nightDimEnabled) {
                    HStack(spacing: DSSpacing.sm) {
                        meRowIcon("moon.stars.fill")
                        Text("夜间降亮遮罩")
                            .foregroundStyle(isEffectiveDarkAppearance ? DSColors.inkPrimary : DSColors.inkSecondary)
                    }
                }
                .tint(DSColors.accent)
                .disabled(!isEffectiveDarkAppearance)
                .frame(minHeight: 36)
                .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("外观")
            } footer: {
                if !isEffectiveDarkAppearance {
                    Text("夜间降亮遮罩仅在深色外观下生效。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            Section("系统") {
                navRow(
                    icon: "externaldrive",
                    title: "存储管理",
                    detail: storageDetailText,
                    useBadgeIcon: false
                ) {
                    router.push(.storagePrefs)
                }
                .accessibilityIdentifier("me_storage_entry")
                .listRowBackground(DSColors.surfaceCard)

                navRow(
                    icon: "info.circle",
                    title: "关于 DSNovel",
                    detail: "",
                    useBadgeIcon: false
                ) {
                    router.push(.about)
                }
                .accessibilityIdentifier("me_about_entry")
                .listRowBackground(DSColors.surfaceCard)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("me_root")
        .background(DSColors.surfaceGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: container.sourcesRevision) { _, _ in
            Task { await refreshSummary() }
        }
        .onChange(of: downloads.totalDiskBytes) { _, _ in
            Task { await refreshStorageTotal() }
        }
        .onAppear {
            Task {
                await refreshSummary()
                await refreshStorageTotal()
            }
        }
        .task {
            await refreshSummary()
            await refreshStorageTotal()
        }
    }

    private func meRowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.inkSecondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(DSColors.inkSecondary.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private func navRow(
        icon: String,
        title: String,
        detail: String,
        useBadgeIcon: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                if useBadgeIcon {
                    meRowIcon(icon)
                } else {
                    Image(systemName: icon)
                        .font(DSTypography.body)
                        .foregroundStyle(DSColors.inkSecondary)
                        .frame(width: 26, alignment: .center)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer(minLength: 4)
                if !detail.isEmpty {
                    Text(detail)
                        .font(DSTypography.numericFootnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshSummary() async {
        await container.ensureSourcesRegistered()
        guard let all = try? await container.persistence.fetchAllSources() else { return }
        let metas = all.map(\.meta)
        totalSourcesCount = metas.count
        var enabled = 0
        var needLogin = 0
        var foundXmly = false
        for meta in metas {
            if meta.isEnabled { enabled += 1 }
            if meta.loginURL != nil || meta.methods.contains("checkLogin") {
                needLogin += 1
            }
            if meta.id == AppContainer.ximalayaSourceID {
                foundXmly = true
            }
        }
        enabledSourcesCount = enabled
        needLoginSourcesCount = needLogin
        hasXimalayaSource = foundXmly
        await container.sourceAuth.refreshAllLoginCapable(
            sources: metas,
            runtime: container.pluginRuntime
        )
    }

    private func refreshStorageTotal() async {
        let manual = DownloadsDataHelper.manualCompletedBytes(from: downloads.manualRecords)
        let precache: Int64
        if let precacheRecords = try? await container.persistence.fetchDownloads(kind: .precache, limit: 500) {
            precache = precacheRecords.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        } else {
            precache = 0
        }
        async let cover = container.coverPipeline.diskUsageBytes()
        async let chapter = container.chapterCache.diskUsageBytes()
        totalStorageBytes = manual + precache + (await cover) + (await chapter)
    }
}
