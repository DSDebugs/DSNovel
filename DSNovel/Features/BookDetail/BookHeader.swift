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
        sourceHealth: DSSourceHealthKind,
        sourceLatencyMs: Int?,
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
                side: 120,
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

                HStack(spacing: Spacing.s2) {
                    let metaParts = [
                        statusText.isEmpty ? nil : statusText,
                        totalChapters > 0 ? "共 \(totalChapters) 章" : nil
                    ].compactMap { $0 }
                    if !metaParts.isEmpty {
                        Text(metaParts.joined(separator: " · "))
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if downloadedCount > 0 {
                        Button {
                            onTapDownloadedBadge?()
                        } label: {
                            DSBadge("已下 \(downloadedCount) 章", icon: "checkmark.circle.fill", style: .success)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("已下载 \(downloadedCount) 章，点击查看已下载章节")
                    }
                }

                HStack(spacing: Spacing.s2) {
                    DSSourceBadge(
                        name: sourceName,
                        health: sourceHealth,
                        latencyMs: sourceLatencyMs
                    )

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
