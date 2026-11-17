import SwiftUI

struct HotBooksSection: View {
    let books: [BookRef]
    let sourceName: String
    let isLoading: Bool
    private let onSelectBook: (BookRef) -> Void
    private let onSelectNarrator: (String) -> Void
    private let onRefresh: () -> Void

    init(
        books: [BookRef],
        sourceName: String,
        isLoading: Bool,
        onSelectBook: @escaping (BookRef) -> Void,
        onSelectNarrator: @escaping (String) -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.books = books
        self.sourceName = sourceName
        self.isLoading = isLoading
        self.onSelectBook = onSelectBook
        self.onSelectNarrator = onSelectNarrator
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            DSSectionHeader(
                title: "热门书籍",
                subtitle: sourceName.isEmpty ? nil : "来自 \(sourceName)",
                actionTitle: books.isEmpty ? nil : "刷新",
                onAction: books.isEmpty ? nil : onRefresh
            )

            if isLoading && books.isEmpty {
                DSSkeleton(mode: .list(rows: 5))
                    .padding(.horizontal, Spacing.pageHorizontal)
            } else if !books.isEmpty {
                LazyVStack(spacing: Spacing.s2) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        hotBookRow(rank: index + 1, book: book)
                    }
                }
                .padding(.horizontal, Spacing.pageHorizontal)
            }
        }
    }

    private func hotBookRow(rank: Int, book: BookRef) -> some View {
        HStack(spacing: Spacing.s3) {
            Text("\(rank)")
                .font(DSTypography.numericCaption.weight(.bold))
                .foregroundStyle(rank <= 3 ? Color.dsAccent : .secondary)
                .frame(width: 24, alignment: .center)

            Button {
                onSelectBook(book)
            } label: {
                DSCover(
                    url: book.cover,
                    title: book.title,
                    side: 52
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onSelectBook(book)
                } label: {
                    Text(book.title)
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                let narrator = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if !narrator.isEmpty {
                    Button {
                        onSelectNarrator(narrator)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(DSTypography.caption2)
                            Text(narrator)
                                .lineLimit(1)
                        }
                        .font(DSTypography.subtitle)
                        .foregroundStyle(Color.dsAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s1)
        .padding(.horizontal, Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Radius.card)
                .fill(Color.dsSurfaceCard)
        )
    }
}
