import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import Foundation
import SwiftUI

/// 存储管理页（4 段空间分布 + 离线下载入口 + 统一缓存清理 + 缓存上限自动清理滑块）
struct StoragePrefsView: View {
    @Environment(AppContainer.self) var container
    @Environment(DownloadCoordinator.self) var downloads
    @Environment(AppSettingsStore.self) var settings
    @Environment(AppRouter.self) var router
    @Environment(DSBannerCoordinator.self) var banner

    @State var manualAudioBytes: Int64 = 0
    @State var precacheBytes: Int64 = 0
    @State var coverCacheBytes: Int64 = 0
    @State var chapterCacheBytes: Int64 = 0
    @State var freeDiskBytes: Int64 = 0
    @State var downloadedBooksCount = 0
    @State var activeDownloadsCount = 0
    @State var failedDownloadsCount = 0

    @State var isClearingCache = false
    @State var showClearAllCacheConfirm = false
    @State var limitEvaluateTask: Task<Void, Never>?
    @State var hasPendingLimitEnforcement = false

    var appTotalBytes: Int64 {
        manualAudioBytes + precacheBytes + coverCacheBytes + chapterCacheBytes
    }

    var clearableCacheBytes: Int64 {
        precacheBytes + coverCacheBytes + chapterCacheBytes
    }

    private var formattedLimitText: String {
        let mb = settings.cacheLimitMB
        if mb >= 2000 { return "2 GB" }
        if mb >= 1024 {
            let gb = Double(mb) / 1024.0
            return abs(gb - gb.rounded()) < 0.05 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
        }
        return "\(mb) MB"
    }

    var body: some View {
        @Bindable var bindableSettings = settings
        List {
            Section {
                storageOverviewCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    router.push(.downloads)
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(DSTypography.sectionHeader)
                            .foregroundStyle(DSColors.accent)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("下载管理")
                                .font(DSTypography.rowTitle)
                                .foregroundStyle(DSColors.inkPrimary)
                            Text(downloadsSubtitle)
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Text(formatBytes(manualAudioBytes))
                            .font(DSTypography.numericFootnote)
                            .foregroundStyle(DSColors.inkSecondary)

                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage_downloads_entry")
                .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("离线下载")
            }

            Section {
                cacheRow(
                    icon: "bolt.fill",
                    title: "自动预缓存",
                    bytes: precacheBytes,
                    action: { Task { await clearPrecacheOnly() } }
                )
                .listRowBackground(DSColors.surfaceCard)

                cacheRow(
                    icon: "photo.stack",
                    title: "封面图片缓存",
                    bytes: coverCacheBytes,
                    action: { Task { await clearCoverCache() } }
                )
                .listRowBackground(DSColors.surfaceCard)

                cacheRow(
                    icon: "list.bullet.rectangle",
                    title: "章节目录缓存",
                    bytes: chapterCacheBytes,
                    action: { Task { await clearChapterCache() } }
                )
                .listRowBackground(DSColors.surfaceCard)

                Button(role: .destructive) {
                    showClearAllCacheConfirm = true
                } label: {
                    HStack {
                        Label("一键清理全部缓存", systemImage: "trash")
                            .foregroundStyle(clearableCacheBytes > 0 ? DSColors.danger : DSColors.inkSecondary)
                        Spacer()
                        if clearableCacheBytes > 0 {
                            Text(formatBytes(clearableCacheBytes))
                                .font(DSTypography.numericFootnote)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isClearingCache || clearableCacheBytes == 0)
                .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("缓存清理")
            }

            Section {
                Toggle("到达上限自动清理", isOn: $bindableSettings.autoCacheCleanupEnabled)
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)

                if settings.autoCacheCleanupEnabled {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        HStack {
                            Text("缓存上限")
                                .font(DSTypography.subheadline)
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Text(formattedLimitText)
                                .font(DSTypography.numericFootnote.weight(.semibold))
                                .foregroundStyle(DSColors.accent)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(settings.cacheLimitMB) },
                                set: { settings.cacheLimitMB = Int(($0 / 100.0).rounded() * 100.0) }
                            ),
                            in: 200...2000,
                            step: 100
                        )
                        .tint(DSColors.accent)

                        HStack {
                            Text("200 MB")
                            Spacer()
                            Text("500 MB")
                            Spacer()
                            Text("1 GB")
                            Spacer()
                            Text("2 GB")
                        }
                        .font(DSTypography.caption2.monospacedDigit())
                        .foregroundStyle(DSColors.inkSecondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(DSColors.surfaceCard)
                }
            } header: {
                Text("自动清理上限")
            } footer: {
                Text("仅统计自动预缓存、封面与章节目录；超过上限时按最久未用自动清理，绝不删除手动下载的离线书籍与收听进度。")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("存储管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认清理全部缓存？", isPresented: $showClearAllCacheConfirm) {
            Button("取消", role: .cancel) {}
            Button("立即清理", role: .destructive) {
                Task { await clearAllCaches() }
            }
        } message: {
            Text("将释放约 \(formatBytes(clearableCacheBytes)) 缓存空间，已手动下载的离线音频和收听进度不会受影响。")
        }
        .onChange(of: downloads.manualRecords) { _, _ in
            Task { await refreshStorageStats() }
        }
        .onChange(of: downloads.completedRevision) { _, _ in
            Task { await refreshStorageStats() }
        }
        .onChange(of: settings.autoCacheCleanupEnabled) { _, enabled in
            container.syncSettingsToEngines()
            if enabled { scheduleLimitEnforcement() }
        }
        .onChange(of: settings.cacheLimitMB) { _, _ in
            container.syncSettingsToEngines()
            scheduleLimitEnforcement()
        }
        .onDisappear {
            limitEvaluateTask?.cancel()
            if hasPendingLimitEnforcement {
                hasPendingLimitEnforcement = false
                let targetContainer = container
                Task { @MainActor in
                    _ = await StorageCachePolicyEngine.enforceLimitIfNeeded(container: targetContainer)
                }
            }
        }
        .task { await refreshStorageStats() }
    }

    private var storageOverviewCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用本地占用")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Text(formatBytes(appTotalBytes))
                        .font(DSTypography.title.monospacedDigit().weight(.semibold))
                        .foregroundStyle(DSColors.inkPrimary)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("设备剩余空间")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Text(formatBytes(freeDiskBytes))
                        .font(DSTypography.numericFootnote.weight(.medium))
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }

            storageBreakdownBar

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xs), count: 4),
                alignment: .leading,
                spacing: 4
            ) {
                legendItem(color: DSColors.accent, title: "离线下载", bytes: manualAudioBytes)
                legendItem(color: DSColors.warning, title: "预缓存", bytes: precacheBytes)
                legendItem(color: Color.blue, title: "封面", bytes: coverCacheBytes)
                legendItem(color: DSColors.inkSecondary, title: "目录", bytes: chapterCacheBytes)
            }
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.heroCard, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
    }

    private var storageBreakdownBar: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 1.5
            let segments = computeBreakdownSegments(totalWidth: proxy.size.width, spacing: spacing)
            HStack(spacing: spacing) {
                if segments.isEmpty {
                    Rectangle().fill(DSColors.separator.opacity(0.35))
                } else {
                    ForEach(segments) { seg in
                        Rectangle().fill(seg.color).frame(width: seg.width)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func legendItem(color: Color, title: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
            }
            Text(formatBytes(bytes))
                .font(DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.inkPrimary.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func cacheRow(
        icon: String,
        title: String,
        bytes: Int64,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                Text(formatBytes(bytes))
                    .font(DSTypography.numericFootnote)
                    .foregroundStyle(DSColors.inkSecondary)
                Text("清理")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(bytes > 0 ? DSColors.accent : DSColors.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(bytes > 0 ? DSColors.accent.opacity(0.14) : DSColors.surfaceGrouped))
                    .padding(.leading, 4)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClearingCache || bytes == 0)
    }
}
