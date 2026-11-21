import SwiftUI

/// 播放器曲目信息与高频动作行组件（§2.1 Layer 3 & §4.2）：
/// 左侧展示章节标题（点击开目录）、书名（点击进详情）、演播者麦克风胶囊（点击搜同演播）；
/// 右侧提供单章离线下载状态圆钮（42×42pt）与加入书架红心圆钮（42×42pt）。
struct PlayerTitleRow: View {
    @Environment(\.dsReduceMotion) private var reduceMotion

    let chapterTitle: String
    let bookTitle: String
    let narrator: String
    let downloadState: ChapterDownloadState
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
        downloadState: ChapterDownloadState,
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

    var body: some View {
        HStack(spacing: Spacing.s3) {
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
                    .foregroundStyle(.white.opacity(0.78))
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
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("演播或作者：\(narrator)，点击搜索同演播作品")
                }
            }

            Spacer()

            Button(action: onTapDownload) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 42, height: 42)

                    switch downloadState {
                    case .notDownloaded:
                        if reduceMotion {
                            Image(systemName: "arrow.down.to.line")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.90))
                                .contentTransition(.identity)
                        } else {
                            Image(systemName: "arrow.down.to.line")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.90))
                                .symbolEffect(.bounce, value: downloadBounceCount)
                        }
                    case .downloading(let prog):
                        DSProgress(value: prog, style: .ring(size: 22, lineWidth: 2.2))
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载或管理离线章节")
            .accessibilityValue(downloadAccessibilityValue)

            Button(action: onTapShelf) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 42, height: 42)
                    if reduceMotion {
                        Image(systemName: inShelf ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(inShelf ? Color.dsAccent : .white.opacity(0.88))
                            .contentTransition(.identity)
                    } else {
                        Image(systemName: inShelf ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(inShelf ? Color.dsAccent : .white.opacity(0.88))
                            .symbolEffect(.bounce, value: heartBounceCount)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inShelf ? "已在书架" : "加入书架")
        }
        .padding(.horizontal, Spacing.pageHorizontal)
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
