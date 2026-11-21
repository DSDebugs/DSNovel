import DSCore
import DSDesignSystem
import SwiftUI

/// 独立收听历史视图（与书架彻底解耦）
struct HistoryView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var items: [BookSummaryDTO] = []
    @State private var showClearAllAlert = false

    var body: some View {
        List {
            if items.isEmpty {
                DSStateView(
                    icon: "clock",
                    title: "暂无收听历史",
                    message: "开始播放有声书后，进度将自动记录在此处。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(items) { book in
                    DSBookRow(book: book, pipeline: container.coverPipeline) {
                        router.push(.bookDetail(book))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除记录", role: .destructive) {
                            Task { await deleteHistory(book) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceBase)
        .navigationTitle("收听历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) {
                    showClearAllAlert = true
                }
                .disabled(items.isEmpty)
                .frame(minHeight: 44)
            }
        }
        .alert("清空全部收听历史", isPresented: $showClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                Task { await clearAllHistory() }
            }
        } message: {
            Text("仅清空收听历史记录，不会影响书架书籍与本地离线音频。")
        }
        .task { await reload() }
    }

    private func reload() async {
        if let loaded = try? await container.persistence.fetchHistoryBooks(limit: 200) {
            items = loaded
        }
    }

    private func clearAllHistory() async {
        do {
            try await container.persistence.clearAllHistory()
            await reload()
            banner.show("已清空全部收听历史", tone: .info)
        } catch {
            banner.show("清空收听历史失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func deleteHistory(_ book: BookSummaryDTO) async {
        do {
            try await container.persistence.clearHistory(bookID: book.id)
            await reload()
            banner.show("已清除《\(book.title)》的收听历史", tone: .info)
        } catch {
            banner.show("删除收听历史失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
