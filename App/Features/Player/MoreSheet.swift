import AVFoundation
import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI
import UIKit

/// 弹窗 8：更多播放设置（第一版精修：书籍微卡顶栏 + 2×2 圆形图标磁贴 + 统一五项功能单卡）
struct MoreSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    let supportsQualitySelection: Bool
    private let onOpenAudioEffects: () -> Void
    private let onOpenQuality: () -> Void
    private let onOpenDownloads: () -> Void
    private let onOpenSkip: () -> Void
    private let onOpenBookDetail: () -> Void
    private let onSearchNarrator: (String) -> Void
    private let onDismiss: () -> Void

    init(
        supportsQualitySelection: Bool,
        onOpenAudioEffects: @escaping () -> Void,
        onOpenQuality: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onOpenSkip: @escaping () -> Void,
        onOpenBookDetail: @escaping () -> Void,
        onSearchNarrator: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.supportsQualitySelection = supportsQualitySelection
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenQuality = onOpenQuality
        self.onOpenDownloads = onOpenDownloads
        self.onOpenSkip = onOpenSkip
        self.onOpenBookDetail = onOpenBookDetail
        self.onSearchNarrator = onSearchNarrator
        self.onDismiss = onDismiss
    }

    private var skipSummaryText: String {
        let cfg = playback.bookSkipConfig
        if !cfg.isEnabled { return "未开启" }
        var parts: [String] = []
        if cfg.introSeconds > 0 { parts.append("头\(cfg.introSeconds)s") }
        if cfg.outroSeconds > 0 { parts.append("尾\(cfg.outroSeconds)s") }
        return parts.isEmpty ? "未开启" : parts.joined(separator: "·")
    }

    private var effectSummaryText: String {
        if playback.dsp.smartRepairEnabled {
            if playback.dsp.isCustomEQ { return "AI · 自定义" }
            return playback.dsp.preset == .flat ? "AI 智能修音" : "AI · \(playback.dsp.preset.title)"
        }
        if playback.dsp.isCustomEQ { return "自定义 EQ" }
        return playback.dsp.preset == .flat ? (isEffectActive ? "已增强" : "未开启") : playback.dsp.preset.title
    }

    private var isEffectActive: Bool {
        playback.dsp.currentParameters().needsProcessing
    }

    private var qualityBadgeText: String {
        if !supportsQualitySelection, let book = playback.currentBook {
            if let stream = playback.activeStream, let kbps = stream.bitrateKbps, kbps > 0 {
                return stream.displayBitrateBadge
            }
            return playback.cachedProbedQuality(bookID: book.id, sourceID: book.sourceID)?.displayName ?? "固定音质"
        }
        return playback.activeStream?.displayBitrateBadge ?? playback.preferredQuality.displayName
    }

    private var currentOutputRouteName: String {
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "本机扬声器" : trimmed
    }

    private var narratorName: String {
        DSMetadataSanitizer.cleanPersonName(playback.currentBook?.narrator)
    }

    private func downloadedCountForCurrentBook() -> Int {
        guard let bookID = playback.currentBook?.id else { return 0 }
        var count = 0
        for rec in downloads.manualRecords where rec.bookID == bookID && rec.state == .completed { count += 1 }
        return count
    }

    var body: some View {
        let hasNoBook = (playback.currentBook == nil)
        let downloadedCount = downloadedCountForCurrentBook()

        ScrollView {
            VStack(spacing: DSSpacing.md) {
                bookHeaderRow(hasNoBook: hasNoBook)
                quickActionGrid(hasNoBook: hasNoBook, downloadedCount: downloadedCount)
                actionListCard(hasNoBook: hasNoBook)
            }
            .padding(.horizontal, DSSpacing.pageHorizontal)
            .padding(.top, DSSpacing.sm)
            .padding(.bottom, DSSpacing.lg)
        }
        .background(DSColors.surfaceBase)
        .overlay(alignment: .top) {
            if let msg = banner.current {
                DSBannerPill(message: msg)
                    .padding(.top, DSSpacing.xs)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func bookHeaderRow(hasNoBook: Bool) -> some View {
        let bookTitle = playback.currentBook.map { BookTitleFormatter.cleanTitle($0.title) } ?? "未在播放"
        let chapterNum = playback.currentChapterIndex + 1
        let sourceName = playback.currentBook?.sourceName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var metaParts: [String] = []
        if !hasNoBook && playback.currentChapter != nil { metaParts.append("第 \(chapterNum) 章") }
        if !sourceName.isEmpty { metaParts.append(sourceName) }
        if !hasNoBook { metaParts.append(qualityBadgeText) }
        let subtitle = metaParts.isEmpty ? "更多播放设置" : metaParts.joined(separator: " · ")

        return HStack(spacing: DSSpacing.sm) {
            DSCover(
                url: playback.currentBook?.coverURL ?? "",
                title: bookTitle,
                pipeline: container.coverPipeline,
                side: 42,
                showsBorder: true,
                showsSoftShadow: false
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(bookTitle)
                    .font(DSTypography.cardTitle.weight(.bold))
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(DSColors.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DSColors.surfaceCard))
                    .overlay(Circle().strokeBorder(DSColors.separator.opacity(0.32), lineWidth: 0.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭更多播放设置")
        }
    }

    private func quickActionGrid(hasNoBook: Bool, downloadedCount: Int) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs)
        ]
        return LazyVGrid(columns: columns, spacing: DSSpacing.xs) {
            MoreQuickTile(
                icon: "waveform",
                title: "音效增强",
                subtitle: effectSummaryText,
                isActive: isEffectActive,
                disabled: false,
                action: onOpenAudioEffects
            )
            MoreQuickTile(
                icon: "forward.frame",
                title: "跳过片头尾",
                subtitle: skipSummaryText,
                isActive: playback.bookSkipConfig.isEnabled,
                disabled: hasNoBook,
                action: onOpenSkip
            )
            MoreQuickTile(
                icon: "arrow.down.to.line",
                title: "批量离线",
                subtitle: downloadedCount > 0 ? "已下载 \(downloadedCount) 章" : "下载离线章节",
                isActive: false,
                disabled: hasNoBook,
                action: onOpenDownloads
            )
            airPlayTile
        }
    }

    private var airPlayTile: some View {
        HStack(spacing: DSSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 34, height: 34)
                AirPlayRoutePickerRepresentable()
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("切换 AirPlay 音频输出")

            VStack(alignment: .leading, spacing: 2) {
                Text("AirPlay 投屏")
                    .font(DSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(DSColors.inkPrimary)
                    .lineLimit(1)
                Text(currentOutputRouteName)
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(DSColors.separator.opacity(0.24), lineWidth: 0.5)
        )
    }

    private func actionListCard(hasNoBook: Bool) -> some View {
        let narrator = narratorName
        return VStack(spacing: 0) {
            if !hasNoBook {
                MoreActionRow(
                    icon: "sparkles",
                    title: "播放音质",
                    badgeText: qualityBadgeText,
                    showsChevron: supportsQualitySelection
                ) {
                    if supportsQualitySelection {
                        onOpenQuality()
                    } else {
                        banner.show("当前书源为固定音源音质（\(qualityBadgeText)）", tone: .info)
                    }
                }
                insetDivider
            }

            MoreActionRow(
                icon: "arrow.clockwise",
                title: "重新加载当前章节",
                showsChevron: false,
                disabled: hasNoBook || playback.currentChapter == nil
            ) {
                playback.retryCurrentChapter()
                banner.show("正在重新加载当前章节", tone: .info)
                onDismiss()
            }
            insetDivider

            MoreActionRow(
                icon: "book.closed",
                title: "书籍详情与简介",
                showsChevron: true,
                disabled: hasNoBook,
                action: onOpenBookDetail
            )

            if !narrator.isEmpty {
                insetDivider
                MoreActionRow(
                    icon: "mic",
                    title: "搜索同演播作品",
                    trailingText: narrator,
                    showsChevron: true
                ) {
                    onSearchNarrator(narrator)
                }
            }

            insetDivider
            MoreActionRow(
                icon: "doc.on.doc",
                title: "复制当前章节标题",
                showsChevron: false,
                disabled: playback.currentChapter == nil
            ) {
                let title = playback.currentChapter?.title ?? ""
                if !title.isEmpty {
                    UIPasteboard.general.string = title
                    banner.show("已复制当前章节标题", tone: .success)
                }
                onDismiss()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(DSColors.separator.opacity(0.24), lineWidth: 0.5)
        )
    }

    private var insetDivider: some View {
        Divider()
            .overlay(DSColors.separator.opacity(0.24))
            .padding(.leading, 50)
    }
}
