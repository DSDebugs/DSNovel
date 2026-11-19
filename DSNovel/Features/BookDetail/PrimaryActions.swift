import SwiftUI

struct PrimaryActions: View {
    let isLoadingChapters: Bool
    let isPlayingThisBook: Bool
    let isEnginePlaying: Bool
    let hasProgress: Bool
    let activeChapterTitle: String?
    let downloadedCount: Int
    let downloadedBytesText: String?
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

    init(
        isLoadingChapters: Bool,
        isPlayingThisBook: Bool = false,
        isEnginePlaying: Bool = false,
        hasProgress: Bool,
        activeChapterTitle: String? = nil,
        downloadedCount: Int = 0,
        downloadedBytesText: String? = nil,
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
        self.isPlayingThisBook = isPlayingThisBook
        self.isEnginePlaying = isEnginePlaying
        self.hasProgress = hasProgress
        self.activeChapterTitle = activeChapterTitle
        self.downloadedCount = downloadedCount
        self.downloadedBytesText = downloadedBytesText
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

    private var primaryTitle: String {
        if isLoadingChapters {
            return "正在获取章节…"
        }
        let cleanTitle = activeChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isPlayingThisBook {
            if isEnginePlaying {
                return cleanTitle.isEmpty ? "暂停播放" : "暂停 · \(cleanTitle)"
            } else {
                return cleanTitle.isEmpty ? "继续播放" : "继续 · \(cleanTitle)"
            }
        }
        if hasProgress && !cleanTitle.isEmpty {
            return "继续 · \(cleanTitle)"
        }
        return "开始收听"
    }

    private var primaryIcon: String {
        if isPlayingThisBook && isEnginePlaying {
            return "pause.fill"
        }
        return "play.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack(spacing: Spacing.s3) {
                DSActionButton(
                    title: primaryTitle,
                    icon: primaryIcon,
                    role: isLoadingChapters ? .loading : .primary,
                    action: onPrimaryPlay
                )
                .accessibilityLabel(primaryTitle)

                Menu {
                    Button {
                        onViewDownloadedChapters()
                    } label: {
                        Label(
                            downloadedCount > 0 ? "查看已下载章节（\(downloadedCount) 章）" : "查看已下载章节",
                            systemImage: "checkmark.circle"
                        )
                    }
                    Divider()
                    Button {
                        onDownloadNext10()
                    } label: {
                        Label("下载后续 10 章", systemImage: "arrow.down.to.line")
                    }
                    Button {
                        onDownloadNext30()
                    } label: {
                        Label("下载后续 30 章", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button {
                        onDownloadUnread()
                    } label: {
                        Label("下载未听章节", systemImage: "tray.and.arrow.down")
                    }
                    Button {
                        onDownloadAll()
                    } label: {
                        Label("下载全部章节", systemImage: "arrow.down.circle.fill")
                    }
                    Button {
                        onDownloadCustomRange()
                    } label: {
                        Label("自定义章节区间…", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    if downloadedCount > 0 {
                        Button(role: .destructive) {
                            onClearBookDownloads()
                        } label: {
                            Label("清空本书已下载章节…", systemImage: "trash")
                        }
                    }
                    Button {
                        onOpenDownloads()
                    } label: {
                        Label("打开全局下载管理", systemImage: "internaldrive")
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: downloadedCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(downloadedCount > 0 ? .green : .primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.dsSurfaceGrouped))

                        if activeDownloadCount > 0 {
                            Text("\(min(activeDownloadCount, 99))")
                                .font(DSTypography.caption2.weight(.bold))
                                .foregroundStyle(Color.dsOnAccent)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Color.dsAccent))
                                .offset(x: 4, y: -2)
                        }
                    }
                }
                .accessibilityLabel("下载与管理已下载章节")

                DSIconButton(
                    systemName: inShelf ? "heart.fill" : "heart",
                    accessibilityTitle: inShelf ? "移出书架" : "加入书架",
                    isHighlighted: inShelf,
                    action: onToggleShelf
                )
            }

            if downloadedCount > 0 || activeDownloadCount > 0 {
                HStack(spacing: Spacing.s2) {
                    Spacer(minLength: 0)
                    Button(action: onViewDownloadedChapters) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(DSTypography.caption2)
                                .foregroundStyle(.green)
                            if let downloadedBytesText, !downloadedBytesText.isEmpty, downloadedCount > 0 {
                                Text("已下载 \(downloadedCount) 章 (\(downloadedBytesText))")
                            } else if downloadedCount > 0 {
                                Text("已下载 \(downloadedCount) 章")
                            } else {
                                Text("正在下载 \(activeDownloadCount) 章")
                            }
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                        }
                        .font(DSTypography.numericCaption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}
