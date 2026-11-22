import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import Foundation
import SwiftUI

/// 存储管理页（空间分布概览 + 离线下载管理入口 + 封面/目录缓存清理）
struct StoragePrefsView: View {
    @Environment(AppContainer.self) var container
    @Environment(DownloadCoordinator.self) var downloads
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

    var offlineTotalBytes: Int64 {
        manualAudioBytes + precacheBytes
    }

    var appTotalBytes: Int64 {
        offlineTotalBytes + coverCacheBytes + chapterCacheBytes
    }

    var clearableCacheBytes: Int64 {
        precacheBytes + coverCacheBytes + chapterCacheBytes
    }

    var body: some View {
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

                        Text(formatBytes(offlineTotalBytes))
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

                if precacheBytes > 0 {
                    Button {
                        Task { await clearPrecacheOnly() }
                    } label: {
                        HStack {
                            Label("清理自动预缓存", systemImage: "bolt.horizontal.circle")
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Text(formatBytes(precacheBytes))
                                .font(DSTypography.numericFootnote)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isClearingCache)
                    .listRowBackground(DSColors.surfaceCard)
                }
            } header: {
                Text("离线下载")
            }

            Section {
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
            } footer: {
                Text("清理缓存仅释放封面图片、章节目录与自动预缓存，不会删除手动下载的离线音频、书架收藏或收听进度。")
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
        .onAppear {
            Task { await refreshStorageStats() }
        }
        .task {
            await refreshStorageStats()
        }
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

            HStack(spacing: DSSpacing.md) {
                legendItem(color: DSColors.accent, title: "离线音频", bytes: offlineTotalBytes)
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
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: seg.width)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func legendItem(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(formatBytes(bytes))")
                .font(DSTypography.caption2.monospacedDigit())
                .foregroundStyle(DSColors.inkSecondary)
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
                    .font(DSTypography.caption.weight(.medium))
                    .foregroundStyle(bytes > 0 ? DSColors.accent : DSColors.inkSecondary)
                    .padding(.leading, 4)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClearingCache || bytes == 0)
    }
}
