import DSDesignSystem
import SwiftUI

/// 书架精修统一白卡列表视图（50pt 封面 + 轻柔书源微标 + 演播/章节精炼副标 + 浅赤陶柔光播放钮 + 内缩细分隔线）
struct ShelfList: View {
    let items: [LibraryBookItem]
    let playingBookID: String?
    let isEnginePlaying: Bool
    let isEditing: Bool
    let selectedIDs: Set<String>
    let isDownloadedFilter: Bool
    let pipeline: CoverImagePipeline
    private let onSelectBook: (LibraryBookItem) -> Void
    private let onPlayBook: (LibraryBookItem) -> Void
    private let onTogglePin: (LibraryBookItem) -> Void
    private let onDownloadUnread: (LibraryBookItem) -> Void
    private let onRemove: (LibraryBookItem) -> Void

    init(
        items: [LibraryBookItem],
        playingBookID: String?,
        isEnginePlaying: Bool,
        isEditing: Bool,
        selectedIDs: Set<String>,
        isDownloadedFilter: Bool = false,
        pipeline: CoverImagePipeline,
        onSelectBook: @escaping (LibraryBookItem) -> Void,
        onPlayBook: @escaping (LibraryBookItem) -> Void,
        onTogglePin: @escaping (LibraryBookItem) -> Void,
        onDownloadUnread: @escaping (LibraryBookItem) -> Void,
        onRemove: @escaping (LibraryBookItem) -> Void
    ) {
        self.items = items
        self.playingBookID = playingBookID
        self.isEnginePlaying = isEnginePlaying
        self.isEditing = isEditing
        self.selectedIDs = selectedIDs
        self.isDownloadedFilter = isDownloadedFilter
        self.pipeline = pipeline
        self.onSelectBook = onSelectBook
        self.onPlayBook = onPlayBook
        self.onTogglePin = onTogglePin
        self.onDownloadUnread = onDownloadUnread
        self.onRemove = onRemove
    }

    private var removeLabel: String {
        isDownloadedFilter ? "删除离线" : "移出书架"
    }

    private func cleanSubtitle(for item: LibraryBookItem) -> String {
        let narrator = item.book.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = item.book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = narrator.isEmpty ? author : narrator
        let progress = item.progressSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voice.isEmpty && !progress.isEmpty {
            return "\(voice) · \(progress)"
        }
        return !progress.isEmpty ? progress : voice
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isPlayingThis = (playingBookID == item.id && isEnginePlaying)
                let isSelected = selectedIDs.contains(item.id)
                let isLast = (index + 1 == items.count)

                shelfRow(item: item, isPlaying: isPlayingThis, isSelected: isSelected)
                    .contextMenu {
                        rowMenuItems(for: item)
                    }

                if !isLast {
                    Divider()
                        .overlay(DSColors.separator.opacity(0.28))
                        .padding(.leading, 76)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.28), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        )
        .padding(.horizontal, DSSpacing.pageHorizontal)
    }

    private func shelfRow(item: LibraryBookItem, isPlaying: Bool, isSelected: Bool) -> some View {
        let sourceName = item.book.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = cleanSubtitle(for: item)

        return HStack(spacing: DSSpacing.sm) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkSecondary)
                    .frame(width: 24)
            }

            Button {
                onSelectBook(item)
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    ZStack(alignment: .topTrailing) {
                        DSCover(
                            url: item.book.coverURL,
                            title: item.book.title,
                            pipeline: pipeline,
                            side: 50,
                            showsBorder: true,
                            showsSoftShadow: false
                        )
                        if item.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(DSTypography.caption2)
                                .foregroundStyle(DSColors.success)
                                .background(Circle().fill(DSColors.surfaceCard).padding(1))
                                .offset(x: 3, y: -3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(DSColors.accent)
                            }
                            Text(BookTitleFormatter.cleanTitle(item.book.title))
                                .font(DSTypography.rowTitle.weight(.semibold))
                                .foregroundStyle(DSColors.inkPrimary)
                                .lineLimit(1)

                            if !sourceName.isEmpty {
                                Text(sourceName)
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(DSColors.inkSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(DSColors.surfaceGrouped)
                                    )
                            }
                        }

                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isEditing {
                Button {
                    onPlayBook(item)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(DSTypography.caption.weight(.bold))
                        .foregroundStyle(DSColors.accent)
                        .offset(x: isPlaying ? 0 : 1)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DSColors.accent.opacity(0.14)))
                        .frame(minWidth: 40, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停《\(item.book.title)》" : "播放《\(item.book.title)》")

                Menu {
                    rowMenuItems(for: item)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DSTypography.callout.weight(.medium))
                        .foregroundStyle(DSColors.inkSecondary)
                        .frame(minWidth: 32, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作：\(item.book.title)")
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rowMenuItems(for item: LibraryBookItem) -> some View {
        Button {
            onPlayBook(item)
        } label: {
            Label("继续播放", systemImage: "play.fill")
        }
        Button {
            onTogglePin(item)
        } label: {
            Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button {
            onDownloadUnread(item)
        } label: {
            Label("下载未听章节", systemImage: "arrow.down.circle")
        }
        Divider()
        Button(role: .destructive) {
            onRemove(item)
        } label: {
            Label(removeLabel, systemImage: "trash")
        }
    }
}
