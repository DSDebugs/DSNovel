import DSDesignSystem
import SwiftUI

/// 书籍详情主操作栏（1:1 复刻 v2.8：52pt 全宽主播放胶囊 + 52pt 圆形下载 Menu + 52pt 圆形红心书架钮）
struct PrimaryActions: View {
    let isLoadingChapters: Bool
    let hasChapters: Bool
    let isPlayingThisBook: Bool
    let isEnginePlaying: Bool
    let hasProgress: Bool
    let activeChapterTitle: String?
    let downloadedCount: Int
    let activeDownloadCount: Int
    let inShelf: Bool
    private let onPrimaryPlay: () -> Void
    private let onViewDownloadedChapters: () -> Void
    private let onDownloadAll: () -> Void
    private let onDownloadUnread: () -> Void
    private let onDownloadNext10: () -> Void
    private let onDownloadNext30: () -> Void
    private let onDownloadCustomRange: () -> Void
    private let onClearBookDownloads: () -> Void
    private let onOpenDownloads: () -> Void
    private let onToggleShelf: () -> Void

    private static let controlHeight: CGFloat = 48

    init(
        isLoadingChapters: Bool,
        hasChapters: Bool = true,
        isPlayingThisBook: Bool = false,
        isEnginePlaying: Bool = false,
        hasProgress: Bool,
        activeChapterTitle: String? = nil,
        downloadedCount: Int = 0,
        activeDownloadCount: Int = 0,
        inShelf: Bool,
        onPrimaryPlay: @escaping () -> Void,
        onViewDownloadedChapters: @escaping () -> Void = {},
        onDownloadAll: @escaping () -> Void,
        onDownloadUnread: @escaping () -> Void,
        onDownloadNext10: @escaping () -> Void,
        onDownloadNext30: @escaping () -> Void,
        onDownloadCustomRange: @escaping () -> Void,
        onClearBookDownloads: @escaping () -> Void = {},
        onOpenDownloads: @escaping () -> Void,
        onToggleShelf: @escaping () -> Void
    ) {
        self.isLoadingChapters = isLoadingChapters
        self.hasChapters = hasChapters
        self.isPlayingThisBook = isPlayingThisBook
        self.isEnginePlaying = isEnginePlaying
        self.hasProgress = hasProgress
        self.activeChapterTitle = activeChapterTitle
        self.downloadedCount = downloadedCount
        self.activeDownloadCount = activeDownloadCount
        self.inShelf = inShelf
        self.onPrimaryPlay = onPrimaryPlay
        self.onViewDownloadedChapters = onViewDownloadedChapters
        self.onDownloadAll = onDownloadAll
        self.onDownloadUnread = onDownloadUnread
        self.onDownloadNext10 = onDownloadNext10
        self.onDownloadNext30 = onDownloadNext30
        self.onDownloadCustomRange = onDownloadCustomRange
        self.onClearBookDownloads = onClearBookDownloads
        self.onOpenDownloads = onOpenDownloads
        self.onToggleShelf = onToggleShelf
    }

    private var cleanTitle: String {
        activeChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var isEmptyChaptersIdle: Bool {
        !hasChapters && !isLoadingChapters
    }

    private var primaryTitle: String {
        if isLoadingChapters { return "正在获取章节…" }
        if !hasChapters { return "重新加载目录" }
        if isPlayingThisBook { return isEnginePlaying ? "暂停播放" : "继续播放" }
        if hasProgress && !cleanTitle.isEmpty { return "继续收听" }
        return "开始收听"
    }

    private var primarySubtitle: String? {
        guard !isLoadingChapters, hasChapters, !cleanTitle.isEmpty else { return nil }
        if isPlayingThisBook { return isEnginePlaying ? "正在播放 · \(cleanTitle)" : cleanTitle }
        if hasProgress { return "上次听到 · \(cleanTitle)" }
        return nil
    }

    private var primaryIcon: String {
        if !hasChapters && !isLoadingChapters { return "arrow.clockwise" }
        if isPlayingThisBook && isEnginePlaying { return "pause.fill" }
        return "play.fill"
    }

    private var primaryButton: some View {
        Button(action: onPrimaryPlay) {
            HStack(spacing: DSSpacing.xs) {
                if isLoadingChapters {
                    ProgressView().tint(DSColors.onAccent)
                } else {
                    Image(systemName: primaryIcon)
                        .font(DSTypography.callout.weight(.bold))
                }
                VStack(alignment: primarySubtitle == nil ? .center : .leading, spacing: 1) {
                    Text(primaryTitle)
                        .font(DSTypography.headline)
                        .lineLimit(1)
                    if let primarySubtitle {
                        Text(primarySubtitle)
                            .font(DSTypography.caption2)
                            .opacity(0.88)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .foregroundStyle(DSColors.onAccent)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: Self.controlHeight)
            .background(Capsule(style: .continuous).fill(DSColors.accent))
        }
        .buttonStyle(.dsCard)
        .disabled(isLoadingChapters)
        .accessibilityLabel(primarySubtitle.map { "\(primaryTitle)，\($0)" } ?? primaryTitle)
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            primaryButton

            Button(action: onToggleShelf) {
                Image(systemName: inShelf ? "heart.fill" : "heart")
                    .font(DSTypography.body.weight(.semibold))
                    .foregroundStyle(inShelf ? DSColors.accent : DSColors.inkPrimary)
                    .frame(width: Self.controlHeight, height: Self.controlHeight)
                    .background(
                        Circle()
                            .fill(inShelf ? DSColors.accent.opacity(0.16) : DSColors.surfaceCard)
                            .overlay(
                                Circle()
                                    .strokeBorder(inShelf ? DSColors.accent.opacity(0.5) : DSColors.separator.opacity(0.35), lineWidth: 0.7)
                            )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.dsCard)
            .accessibilityLabel(inShelf ? "移出书架" : "加入书架")

            Menu {
                Button(action: onViewDownloadedChapters) {
                    Label(
                        downloadedCount > 0 ? "查看已下载章节（\(downloadedCount) 章）" : "查看已下载章节",
                        systemImage: "checkmark.circle"
                    )
                }
                Divider()
                Button(action: onDownloadNext10) {
                    Label("下载后续 10 章", systemImage: "arrow.down.to.line")
                }
                Button(action: onDownloadNext30) {
                    Label("下载后续 30 章", systemImage: "square.and.arrow.down.on.square")
                }
                Button(action: onDownloadUnread) {
                    Label("下载未听章节", systemImage: "tray.and.arrow.down")
                }
                Button(action: onDownloadAll) {
                    Label("下载全部章节", systemImage: "arrow.down.circle.fill")
                }
                Button(action: onDownloadCustomRange) {
                    Label("自定义章节区间…", systemImage: "slider.horizontal.3")
                }
                Divider()
                if downloadedCount > 0 {
                    Button(role: .destructive, action: onClearBookDownloads) {
                        Label("清空本书已下载章节…", systemImage: "trash")
                    }
                }
                Button(action: onOpenDownloads) {
                    Label("打开全局下载管理", systemImage: "internaldrive")
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: downloadedCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(DSTypography.body.weight(.semibold))
                        .foregroundStyle(downloadedCount > 0 ? DSColors.success : DSColors.inkPrimary)
                        .frame(width: Self.controlHeight, height: Self.controlHeight)
                        .background(
                            Circle()
                                .fill(DSColors.surfaceCard)
                                .overlay(Circle().strokeBorder(DSColors.separator.opacity(0.35), lineWidth: 0.7))
                        )
                        .contentShape(Circle())

                    if activeDownloadCount > 0 {
                        Text("\(min(activeDownloadCount, 99))")
                            .font(DSTypography.caption2.weight(.bold))
                            .foregroundStyle(DSColors.onAccent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(DSColors.accent))
                            .offset(x: 4, y: -2)
                    }
                }
            }
            .disabled(isEmptyChaptersIdle)
            .opacity(isEmptyChaptersIdle ? 0.45 : 1.0)
            .accessibilityLabel("下载与管理已下载章节")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }
}
