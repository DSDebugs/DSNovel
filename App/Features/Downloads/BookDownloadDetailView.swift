import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import SwiftUI

/// 单本书离线下载详情页（缓存派生章节列表，零视图内集合过滤）
struct BookDownloadDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var showDeleteAllAlert = false
    @State private var completedItems: [DownloadRecordSnapshot] = []

    private let bookID: String
    private let bookTitle: String

    init(bookID: String, bookTitle: String) {
        self.bookID = bookID
        self.bookTitle = bookTitle
    }

    var body: some View {
        List {
            if completedItems.isEmpty {
                DSStateView(
                    icon: "tray",
                    title: "暂无离线章节",
                    message: "该书所有本地音频已清理。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(completedItems.enumerated()), id: \.element.id) { idx, rec in
                    Button {
                        Task { await playOffline(records: completedItems, startAt: idx) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                                Text(rec.chapterTitle)
                                    .font(DSTypography.subheadline)
                                    .foregroundStyle(DSColors.inkPrimary)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: rec.totalBytes, countStyle: .file))
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .foregroundStyle(DSColors.accent)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            Task { await downloads.cancelAndDelete(id: rec.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceBase)
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空本书", role: .destructive) {
                    showDeleteAllAlert = true
                }
                .disabled(completedItems.isEmpty)
            }
        }
        .alert("清空本书离线音频", isPresented: $showDeleteAllAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                Task {
                    await downloads.deleteBookDownloads(bookID: bookID)
                    banner.show("已清空《\(bookTitle)》的离线文件", tone: .info)
                }
            }
        } message: {
            Text("将删除本地已下载音频，不会影响书架与收听进度。")
        }
        .onAppear { refreshCompletedItems() }
        .onChange(of: downloads.manualRecords) { _, _ in refreshCompletedItems() }
    }

    private func refreshCompletedItems() {
        completedItems = DownloadsDataHelper.completedChapters(for: bookID, from: downloads.manualRecords)
    }

    private func playOffline(records: [DownloadRecordSnapshot], startAt: Int) async {
        guard let first = records.first else { return }
        let existingBook = await resolvePersistedBook(bookID: first.bookID)
        let book = existingBook ?? BookSummaryDTO(
            id: first.bookID,
            sourceID: first.sourceID,
            bookURL: "",
            title: first.bookTitle,
            coverURL: first.coverURL
        )
        let chapters = records.map { rec in
            ChapterDTO(id: rec.chapterID, index: rec.chapterIndex, title: rec.chapterTitle, url: rec.chapterURL)
        }
        playback.play(book: book, chapters: chapters, startIndex: startAt, autoPlay: true)
        router.isPlayerPresented = true
    }

    private func resolvePersistedBook(bookID: String) async -> BookSummaryDTO? {
        if let exact = try? await container.persistence.fetchBook(id: bookID) {
            return exact
        }
        if let shelf = try? await container.persistence.fetchShelfBooks(),
           let found = shelf.first(where: { $0.id == bookID }) {
            return found
        }
        return nil
    }
}
