import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var libraryStore = LibraryStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var player = PlayerEngine.shared
    @State private var showClearConfirm = false

    init() {}

    var body: some View {
        let sections = libraryStore.cachedHistorySections
        Group {
            if sections.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无播放历史",
                    messageOverride: "收听过的有声书会自动记录在这里",
                    primaryTitleOverride: "去发现",
                    onPrimary: { AppRouter.shared.selectedTab = .discover },
                    onSecondary: nil
                )
            } else {
                List {
                    ForEach(sections, id: \.group) { section in
                        Section(section.group.title) {
                            ForEach(section.books) { book in
                                historyRow(book)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(sections.isEmpty)
            }
        }
        .alert("清空播放历史", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空播放历史", role: .destructive) {
                libraryStore.clearAllHistory()
            }
        } message: {
            Text("确认清空全部播放历史？")
        }
        .task {
            libraryStore.modelContext = modelContext
            libraryStore.refreshHistoryCache()
        }
    }

    private func historyRow(_ book: Book) -> some View {
        let model = LibraryCardMapper.makeModel(from: book, sourceStore: sourceStore, player: player)
        return HStack(spacing: Spacing.s3) {
            DSBookRow(
                model: model,
                onSelect: { AppRouter.shared.open(.book(book.bookRef)) },
                onPlayTap: nil
            )

            Button {
                if !book.inShelf {
                    book.inShelf = true
                    try? modelContext.save()
                    DSHapticPolicy.fire(.success)
                    BannerCenter.shared.show("已加入书架", kind: .success)
                    libraryStore.refreshNow()
                }
            } label: {
                Text(book.inShelf ? "已在书架" : "＋书架")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(book.inShelf ? .secondary : Color.dsAccent)
                    .padding(.horizontal, Spacing.s3)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.dsSurfaceGrouped)
                    )
            }
            .buttonStyle(.plain)
            .disabled(book.inShelf)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                DSHapticPolicy.fire(.warning)
                libraryStore.deleteHistoryDeferred(book)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}
