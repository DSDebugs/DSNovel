import DSDesignSystem
import SwiftUI

/// 单章下载状态（供 PlayerTitleRow 渲染无框进度环与完成态）
enum PlayerChapterDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case completed
    case failed
}

/// 播放器曲目信息与高频动作行（左对齐三行可点 + 右侧无框下载与收藏图标）
struct PlayerTitleRow: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dsReduceMotion) private var appReduceMotion

    let chapterTitle: String
    let bookTitle: String
    let narrator: String
    let downloadState: PlayerChapterDownloadState
    let inShelf: Bool
    let downloadBounceCount: Int
    let heartBounceCount: Int
    private let onTapChapterTitle: () -> Void
    private let onTapBookTitle: () -> Void
    private let onTapNarrator: (String) -> Void
    private let onTapDownload: () -> Void
    private let onTapShelf: () -> Void

    init(
        chapterTitle: String,
        bookTitle: String,
        narrator: String,
        downloadState: PlayerChapterDownloadState,
        inShelf: Bool,
        downloadBounceCount: Int,
        heartBounceCount: Int,
        onTapChapterTitle: @escaping () -> Void,
        onTapBookTitle: @escaping () -> Void,
        onTapNarrator: @escaping (String) -> Void,
        onTapDownload: @escaping () -> Void,
        onTapShelf: @escaping () -> Void
    ) {
        self.chapterTitle = chapterTitle
        self.bookTitle = bookTitle
        self.narrator = narrator
        self.downloadState = downloadState
        self.inShelf = inShelf
        self.downloadBounceCount = downloadBounceCount
        self.heartBounceCount = heartBounceCount
        self.onTapChapterTitle = onTapChapterTitle
        self.onTapBookTitle = onTapBookTitle
        self.onTapNarrator = onTapNarrator
        self.onTapDownload = onTapDownload
        self.onTapShelf = onTapShelf
    }

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTapChapterTitle) {
                    Text(chapterTitle.isEmpty ? "未选择章节" : chapterTitle)
                        .font(DSTypography.bookTitleMedium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前章节：\(chapterTitle.isEmpty ? "未选择章节" : chapterTitle)，点击打开章节目录")

                Button(action: onTapBookTitle) {
                    HStack(spacing: 4) {
                        Text(bookTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(DSTypography.caption2)
                    }
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.white.opacity(0.76))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("书名：\(bookTitle)，点击查看书籍详情")

                if !narrator.isEmpty {
                    Button {
                        onTapNarrator(narrator)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(narrator)
                                .lineLimit(1)
                        }
                        .font(DSTypography.caption)
                        .foregroundStyle(.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("演播或作者：\(narrator)，点击搜索同演播作品")
                }
            }

            Spacer(minLength: 4)

            Button(action: onTapDownload) {
                Group {
                    switch downloadState {
                    case .notDownloaded:
                        if reduceMotion {
                            Image(systemName: "arrow.down.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.86))
                                .contentTransition(.identity)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.86))
                                .symbolEffect(.bounce, value: downloadBounceCount)
                        }
                    case .downloading(let prog):
                        DSProgress(value: prog, style: .ring(size: 22, lineWidth: 2.2))
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(DSColors.success)
                    case .failed:
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(DSTypography.body.weight(.semibold))
                            .foregroundStyle(DSColors.warning)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载或管理离线章节")
            .accessibilityValue(downloadAccessibilityValue)

            Button(action: onTapShelf) {
                Group {
                    if reduceMotion {
                        Image(systemName: inShelf ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(inShelf ? DSColors.accent : .white.opacity(0.86))
                            .contentTransition(.identity)
                    } else {
                        Image(systemName: inShelf ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(inShelf ? DSColors.accent : .white.opacity(0.86))
                            .symbolEffect(.bounce, value: heartBounceCount)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inShelf ? "已在书架" : "加入书架")
        }
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    private var downloadAccessibilityValue: String {
        switch downloadState {
        case .notDownloaded: return "当前章节未下载，点击下载或打开批量下载面板"
        case .downloading(let prog): return "正在下载 \(Int((prog * 100).rounded()))%"
        case .completed: return "当前章节已离线下载，点击打开下载管理"
        case .failed: return "下载失败，点击打开下载面板重试"
        }
    }
}
