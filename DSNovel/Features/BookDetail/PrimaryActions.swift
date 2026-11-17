import SwiftUI

struct PrimaryActions: View {
    let isLoadingChapters: Bool
    let hasProgress: Bool
    let lastChapterIndex: Int
    let lastPositionText: String
    let lastPlayedRelativeText: String?
    let inShelf: Bool
    private let onPrimaryPlay: () -> Void
    private let onDownloadAll: () -> Void
    private let onDownloadUnread: () -> Void
    private let onDownloadNext10: () -> Void
    private let onDownloadNext30: () -> Void
    private let onDownloadCustomRange: () -> Void
    private let onOpenDownloads: () -> Void
    private let onToggleShelf: () -> Void

    init(
        isLoadingChapters: Bool,
        hasProgress: Bool,
        lastChapterIndex: Int,
        lastPositionText: String,
        lastPlayedRelativeText: String?,
        inShelf: Bool,
        onPrimaryPlay: @escaping () -> Void,
        onDownloadAll: @escaping () -> Void,
        onDownloadUnread: @escaping () -> Void,
        onDownloadNext10: @escaping () -> Void,
        onDownloadNext30: @escaping () -> Void,
        onDownloadCustomRange: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onToggleShelf: @escaping () -> Void
    ) {
        self.isLoadingChapters = isLoadingChapters
        self.hasProgress = hasProgress
        self.lastChapterIndex = lastChapterIndex
        self.lastPositionText = lastPositionText
        self.lastPlayedRelativeText = lastPlayedRelativeText
        self.inShelf = inShelf
        self.onPrimaryPlay = onPrimaryPlay
        self.onDownloadAll = onDownloadAll
        self.onDownloadUnread = onDownloadUnread
        self.onDownloadNext10 = onDownloadNext10
        self.onDownloadNext30 = onDownloadNext30
        self.onDownloadCustomRange = onDownloadCustomRange
        self.onOpenDownloads = onOpenDownloads
        self.onToggleShelf = onToggleShelf
    }

    private var primaryTitle: String {
        if isLoadingChapters {
            return "正在获取章节…"
        }
        if hasProgress && lastChapterIndex > 0 {
            return "继续 · 第 \(lastChapterIndex) 章 \(lastPositionText)"
        }
        return "开始收听"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack(spacing: Spacing.s3) {
                DSActionButton(
                    title: primaryTitle,
                    icon: "play.fill",
                    role: isLoadingChapters ? .loading : .primary,
                    action: onPrimaryPlay
                )

                Menu {
                    Button("下载全部", action: onDownloadAll)
                    Button("下载未听章节", action: onDownloadUnread)
                    Button("下载后续 10 章", action: onDownloadNext10)
                    Button("下载后续 30 章", action: onDownloadNext30)
                    Button("自定义区间…", action: onDownloadCustomRange)
                    Divider()
                    Button("查看下载", action: onOpenDownloads)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.dsSurfaceGrouped))
                }
                .accessibilityLabel("下载章节")

                DSIconButton(
                    systemName: inShelf ? "heart.fill" : "heart",
                    accessibilityTitle: inShelf ? "移出书架" : "加入书架",
                    isHighlighted: inShelf,
                    action: onToggleShelf
                )
            }

            if let lastPlayedRelativeText, !lastPlayedRelativeText.isEmpty, hasProgress {
                Text("上次听到 \(lastPlayedRelativeText)")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}
