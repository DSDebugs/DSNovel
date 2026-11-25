import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 「设置」根视图（紧凑三卡精修：听书 [书源管理/Wi-Fi下载/播放偏好] · 外观 [三卡片主题 + 深色按需显夜间遮罩] · 系统 [存储管理/关于]）
struct MeRootView: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings

    @State private var totalSourcesCount = 0
    @State private var enabledSourcesCount = 0
    @State private var hasXimalayaSource = false
    @State private var totalStorageBytes: Int64 = 0

    private var isEffectiveDarkAppearance: Bool {
        switch settings.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    private var isXimalayaLoggedIn: Bool {
        guard hasXimalayaSource else { return false }
        if case .loggedIn = container.sourceAuth.status(for: AppContainer.ximalayaSourceID) {
            return true
        }
        return false
    }

    private var sourceSummaryText: String {
        if totalSourcesCount == 0 { return "未导入" }
        return "\(enabledSourcesCount)/\(totalSourcesCount) 已启用"
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

    private var appVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.3.9"
    }

    var body: some View {
        @Bindable var bindable = settings
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                sectionGroup(title: "听书") {
                    listeningCard(bindable: $bindable)
                }

                sectionGroup(title: "外观") {
                    appearanceCard(bindable: $bindable)
                }

                sectionGroup(title: "系统") {
                    systemCard
                }
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.top, DSSpacing.xs)
            .padding(.bottom, DSSpacing.lg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me_root")
        .background(DSColors.surfaceBase)
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

    private func sectionGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DSTypography.caption.weight(.medium))
                .foregroundStyle(DSColors.inkSecondary)
                .padding(.leading, 4)

            content()
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .fill(DSColors.surfaceCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                                .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.035), radius: 8, y: 2)
                )
        }
    }

    private func listeningCard(bindable: Bindable<AppSettingsStore>) -> some View {
        VStack(spacing: 0) {
            Button {
                DSHaptics.selection()
                router.push(.sources)
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    rowBadgeIcon("books.vertical.fill", isAccent: true)
                    Text("书源管理")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        if isXimalayaLoggedIn {
                            Circle()
                                .fill(DSColors.success)
                                .frame(width: 6, height: 6)
                        }
                        Text(sourceSummaryText)
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(DSColors.inkSecondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.70))
                }
                .padding(.horizontal, DSSpacing.md)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书源管理，\(sourceSummaryText)")

            insetDivider

            Toggle(isOn: bindable.wifiOnlyDownload) {
                HStack(spacing: DSSpacing.sm) {
                    rowBadgeIcon("wifi", isAccent: true)
                    Text("仅在 Wi-Fi 下下载")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                }
            }
            .tint(DSColors.accent)
            .onChange(of: settings.wifiOnlyDownload) { _, _ in
                container.syncSettingsToEngines()
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: 48)

            insetDivider

            navRow(
                icon: "slider.horizontal.3",
                title: "更多播放偏好",
                detail: playbackPrefsSummary,
                isAccentIcon: false
            ) {
                router.push(.playbackPrefs)
            }
        }
    }

    private func appearanceCard(bindable: Bindable<AppSettingsStore>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DSSpacing.xs) {
                themeTile(mode: .system, icon: "circle.lefthalf.filled")
                themeTile(mode: .light, icon: "sun.max.fill")
                themeTile(mode: .dark, icon: "moon.fill")
            }
            .padding(DSSpacing.sm)

            if isEffectiveDarkAppearance {
                insetDivider
                Toggle(isOn: bindable.nightDimEnabled) {
                    HStack(spacing: DSSpacing.sm) {
                        rowBadgeIcon("moon.stars.fill", isAccent: false)
                        Text("夜间降亮遮罩")
                            .font(DSTypography.subheadline)
                            .foregroundStyle(DSColors.inkPrimary)
                    }
                }
                .tint(DSColors.accent)
                .padding(.horizontal, DSSpacing.md)
                .frame(minHeight: 48)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: isEffectiveDarkAppearance)
    }

    private func themeTile(mode: AppThemeMode, icon: String) -> some View {
        let isSelected = (settings.themeMode == mode)
        return Button {
            DSHaptics.selection()
            settings.themeMode = mode
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(DSTypography.callout.weight(.medium))
                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkPrimary.opacity(0.78))
                Text(mode.title)
                    .font(DSTypography.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                    .fill(isSelected ? DSColors.accent.opacity(0.12) : DSColors.surfaceGrouped)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                    .strokeBorder(
                        isSelected ? DSColors.accent.opacity(0.60) : Color.clear,
                        lineWidth: 1.0
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var systemCard: some View {
        VStack(spacing: 0) {
            navRow(
                icon: "externaldrive.fill",
                title: "存储管理",
                detail: storageDetailText,
                isAccentIcon: false
            ) {
                router.push(.storagePrefs)
            }
            .accessibilityIdentifier("me_storage_entry")

            insetDivider

            navRow(
                icon: "info.circle.fill",
                title: "关于 DSNovel",
                detail: appVersionText,
                isAccentIcon: false
            ) {
                router.push(.about)
            }
            .accessibilityIdentifier("me_about_entry")
        }
    }

    private var insetDivider: some View {
        Divider()
            .overlay(DSColors.separator.opacity(0.28))
            .padding(.leading, 54)
    }

    private func rowBadgeIcon(_ systemName: String, isAccent: Bool) -> some View {
        Image(systemName: systemName)
            .font(DSTypography.caption.weight(.semibold))
            .foregroundStyle(isAccent ? DSColors.accent : DSColors.inkSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isAccent ? DSColors.accent.opacity(0.14) : DSColors.inkSecondary.opacity(0.12))
            )
            .accessibilityHidden(true)
    }

    private func navRow(
        icon: String,
        title: String,
        detail: String,
        isAccentIcon: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            DSHaptics.selection()
            action()
        } label: {
            HStack(spacing: DSSpacing.sm) {
                rowBadgeIcon(icon, isAccent: isAccentIcon)
                Text(title)
                    .font(DSTypography.subheadline)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer(minLength: 8)
                if !detail.isEmpty {
                    Text(detail)
                        .font(DSTypography.numericFootnote)
                        .foregroundStyle(DSColors.inkSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(DSColors.inkSecondary.opacity(0.70))
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: 48)
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
        var foundXmly = false
        for meta in metas {
            if meta.isEnabled { enabled += 1 }
            if meta.id == AppContainer.ximalayaSourceID { foundXmly = true }
        }
        enabledSourcesCount = enabled
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
