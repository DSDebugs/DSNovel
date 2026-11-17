import SwiftUI

struct BookHeader: View {
    let book: BookRef
    let sourceName: String
    let sourceHealth: DSSourceHealthKind
    let sourceLatencyMs: Int?
    let requiresLogin: Bool
    let isLoggedIn: Bool
    let alternativesCount: Int
    let totalChapters: Int
    let statusText: String
    private let onTapSwitchSource: () -> Void
    private let onTapLogin: () -> Void
    private let onCoverLoaded: (UIImage) -> Void

    init(
        book: BookRef,
        sourceName: String,
        sourceHealth: DSSourceHealthKind,
        sourceLatencyMs: Int?,
        requiresLogin: Bool,
        isLoggedIn: Bool,
        alternativesCount: Int,
        totalChapters: Int,
        statusText: String,
        onTapSwitchSource: @escaping () -> Void,
        onTapLogin: @escaping () -> Void,
        onCoverLoaded: @escaping (UIImage) -> Void = { _ in }
    ) {
        self.book = book
        self.sourceName = sourceName
        self.sourceHealth = sourceHealth
        self.sourceLatencyMs = sourceLatencyMs
        self.requiresLogin = requiresLogin
        self.isLoggedIn = isLoggedIn
        self.alternativesCount = alternativesCount
        self.totalChapters = totalChapters
        self.statusText = statusText
        self.onTapSwitchSource = onTapSwitchSource
        self.onTapLogin = onTapLogin
        self.onCoverLoaded = onCoverLoaded
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s4) {
            DSCover(
                url: book.cover,
                title: book.title,
                side: 128,
                onImageLoaded: onCoverLoaded
            )

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(book.title)
                    .font(DSTypography.bookTitleLarge)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(DSTypography.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                let metaParts = [
                    statusText.isEmpty ? nil : statusText,
                    totalChapters > 0 ? "共 \(totalChapters) 章" : nil
                ].compactMap { $0 }
                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " · "))
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Spacing.s2) {
                    DSSourceBadge(
                        name: sourceName,
                        health: sourceHealth,
                        latencyMs: sourceLatencyMs
                    )

                    Button(action: onTapSwitchSource) {
                        DSBadge("换源 · \(max(1, alternativesCount + 1))", icon: "arrow.triangle.2.circlepath", style: .neutral)
                    }
                    .buttonStyle(.plain)

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
