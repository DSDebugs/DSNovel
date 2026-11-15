import SwiftUI

struct FloatingMiniPlayerBar: View {
    @Environment(AudioPlayerEngine.self) private var player

    let onExpandPlayer: () -> Void
    let onOpenChapters: () -> Void

    var body: some View {
        if let book = player.currentBook {
            AppGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    // 左侧点击展开全屏播放器
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onExpandPlayer()
                    } label: {
                        HStack(spacing: 10) {
                            BookCoverView(
                                bookId: book.id,
                                urlString: book.coverURL,
                                title: book.title,
                                source: book.source,
                                width: 42,
                                height: 42,
                                cornerRadius: 10
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.currentEpisode?.displayTitle ?? book.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text("\(book.title) · \(player.statusBanner)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())

                    // 右侧 3 个独立 42x42pt 快捷按钮（播放/暂停、下一集、直接打开章节目录）
                    GlassIconButton(
                        systemName: player.isPlaying ? "pause.fill" : "play.fill",
                        tint: .orange,
                        size: 36
                    ) {
                        player.togglePlayPause()
                    }

                    GlassIconButton(systemName: "forward.end.fill", size: 36) {
                        player.playNextEpisode()
                    }

                    GlassIconButton(systemName: "list.bullet", size: 36) {
                        onOpenChapters()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .appGlassEffect(.regular, in: .capsule)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
    }
}
