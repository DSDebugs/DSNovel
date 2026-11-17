import SwiftUI
import SwiftData

struct BookDownloadDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let bookID: String
    let bookTitle: String
    @Query(sort: [SortDescriptor(\DownloadItem.createdAt)])
    private var allItems: [DownloadItem]

    init(bookID: String, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
    }

    var body: some View {
        let items = DownloadsDataHelper.itemsForBook(bookID, from: allItems)
        List {
            ForEach(items) { item in
                HStack {
                    Text(item.chapterTitle)
                        .font(DSTypography.body)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        DownloadManager.shared.invalidateLocalFile(bookID: item.bookID, chapterID: item.chapterID)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(bookTitle)
    }
}
