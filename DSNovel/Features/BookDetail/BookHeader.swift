import SwiftUI

struct BookHeader: View {
    let book: BookRef
    let sourceName: String
    let sourceHealth: DSSourceHealthKind
    let sourceLatencyMs: Int?
    let requiresLogin: Bool
    let isLoggedIn: Bool
    let totalChapters: Int
    let downloadedCount: Int
    let statusText: String
    private let onTapDownloadedBadge: (() -> Void)?
    private let onTapLogin: () -> Void
    private let onTapNarrator: ((String) -> Void)?
    private let onCoverLoaded: (UIImage) -> Void

    init(
        book: BookRef,
        sourceName: String,
        sourceHealth: DSSourceHealthKind = .untested,
        sourceLatencyMs: Int? = nil,
        requiresLogin: Bool,
        isLoggedIn: Bool,
        totalChapters: Int,
        downloadedCount: Int = 0,
        statusText: String,
        onTapDownloadedBadge: (() -> Void)? = nil,
        onTapLogin: @escaping () -> Void,
        onTapNarrator: ((String) -> Void)? = nil,
        onCoverLoaded: @escaping (UIImage) -> Void = { _ in }
    ) {
        self.book = book
        self.sourceName = sourceName
        self.sourceHealth = sourceHealth
        self.sourceLatencyMs = sourceLatencyMs
        self.requiresLogin = requiresLogin
        self.isLoggedIn = isLoggedIn
        self.totalChapters = totalChapters
        self.downloadedCount = downloadedCount
        self.statusText = statusText
        self.onTapDownloadedBadge = onTapDownloadedBadge
        self.onTapLogin = onTapLogin
        self.onTapNarrator = onTapNarrator
        self.onCoverLoaded = onCoverLoaded
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s4) {
            DSCover(
                url: book.cover,
                title: book.title,
                side: 116,
                badges: downloadedCount > 0 ? [.downloaded] : [],
                onImageLoaded: onCoverLoaded
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(book.title)
                    .font(DSTypography.bookTitleLarge)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // 元信息顺序：主播名称 -> 书源名称（去延迟数字） -> 共多少集
                BookHeaderFlowLayout(horizontalSpacing: Spacing.s2, verticalSpacing: 6) {
                    if !book.author.isEmpty {
                        Button {
                            if let onTapNarrator {
                                onTapNarrator(book.author)
                            } else {
                                AppRouter.shared.searchByNarrator(book.author)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill")
                                    .font(DSTypography.caption2)
                                Text(book.author)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(DSTypography.caption2)
                            }
                            .font(DSTypography.subtitle.weight(.medium))
                            .foregroundStyle(Color.dsAccent)
                        }
                        .buttonStyle(.plain)
                    }

                    if !sourceName.isEmpty {
                        DSSourceBadge(
                            name: sourceName,
                            health: sourceHealth,
                            latencyMs: nil,
                            showHealthAndLatency: false
                        )
                    }

                    let episodeText: String? = {
                        var parts: [String] = []
                        if !statusText.isEmpty {
                            parts.append(statusText)
                        }
                        if totalChapters > 0 {
                            parts.append("共 \(totalChapters) 集")
                        }
                        return parts.isEmpty ? nil : parts.joined(separator: " · ")
                    }()
                    if let episodeText {
                        Text(episodeText)
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.vertical, 4)
                    }

                    if downloadedCount > 0 {
                        Button {
                            onTapDownloadedBadge?()
                        } label: {
                            DSBadge("已下 \(downloadedCount) 集", icon: "checkmark.circle.fill", style: .success)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("已下载 \(downloadedCount) 集，点击查看已下载章节")
                    }

                    if requiresLogin && !isLoggedIn {
                        Button(action: onTapLogin) {
                            DSBadge("需登录", icon: "person.badge.key", style: .warning)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}

private struct BookHeaderFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
            totalWidth = max(totalWidth, currentX - horizontalSpacing)
        }
        return CGSize(width: min(maxWidth, totalWidth), height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
    }
}
