import SwiftUI

struct PlayerBottomAlbumBar: View {
    let book: BookRef?
    let sourceName: String
    let inShelf: Bool
    let heartBounceCount: Int
    private let onOpenBookDetail: () -> Void
    private let onToggleShelf: () -> Void

    init(
        book: BookRef?,
        sourceName: String,
        inShelf: Bool,
        heartBounceCount: Int = 0,
        onOpenBookDetail: @escaping () -> Void,
        onToggleShelf: @escaping () -> Void
    ) {
        self.book = book
        self.sourceName = sourceName
        self.inShelf = inShelf
        self.heartBounceCount = heartBounceCount
        self.onOpenBookDetail = onOpenBookDetail
        self.onToggleShelf = onToggleShelf
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Button(action: onOpenBookDetail) {
                HStack(spacing: Spacing.s3) {
                    DSCover(
                        url: book?.cover ?? "",
                        title: book?.title ?? "有声书",
                        side: 40
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(book?.title ?? "未选择有声书")
                            .font(DSTypography.cardTitle)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        let narrator = book?.author ?? ""
                        Text(narrator.isEmpty ? "来源：\(sourceName)" : "主播：\(narrator) · \(sourceName)")
                            .font(DSTypography.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: Spacing.s2)

            Button(action: onToggleShelf) {
                HStack(spacing: 4) {
                    Image(systemName: inShelf ? "checkmark" : "plus")
                        .font(DSTypography.caption2.weight(.bold))
                    Text(inShelf ? "已订阅" : "订阅专辑")
                        .font(DSTypography.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(inShelf ? Color.dsAccent : Color.white.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .symbolEffect(.bounce, value: heartBounceCount)
        }
        .padding(Spacing.s2)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}
