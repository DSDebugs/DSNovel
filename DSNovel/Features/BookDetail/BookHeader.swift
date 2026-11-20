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

    private var titleParts: (main: String, tags: [String]) {
        BookTitleFormatter.split(book.title)
    }

    private var episodeText: String? {
        var parts: [String] = []
        if !statusText.isEmpty { parts.append(statusText) }
        if totalChapters > 0 { parts.append("\(totalChapters) 集") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let coverSide: CGFloat = 128

    var body: some View {
        let parts = titleParts
        HStack(alignment: .top, spacing: Spacing.s4) {
            // 已下载数量统一在章节筛选里展示，封面不再叠加角标
            DSCover(
                url: book.cover,
                title: book.title,
                side: Self.coverSide,
                badges: [],
                onImageLoaded: onCoverLoaded
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

            // 固定四层：主标题 / 副标签 / 主播 / 书源 + 集数；与封面等高
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.main)
                    .font(DSTypography.bookTitleLarge)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !parts.tags.isEmpty {
                    Text(parts.tags.joined(separator: " · "))
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }

                Spacer(minLength: Spacing.s2)

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
                    if !sourceName.isEmpty {
                        DSSourceBadge(
                            name: sourceName,
                            health: sourceHealth,
                            latencyMs: nil,
                            showHealthAndLatency: false
                        )
                        .layoutPriority(1)
                    }
                    if let episodeText {
                        Text(episodeText)
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if requiresLogin && !isLoggedIn {
                        Button(action: onTapLogin) {
                            DSBadge("需登录", icon: "person.badge.key", style: .warning)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Spacing.s2)
            }
            .frame(maxWidth: .infinity, minHeight: Self.coverSide, alignment: .topLeading)
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }
}
