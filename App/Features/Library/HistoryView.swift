import DSCore
import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftData
import SwiftUI

/// 播放历史页（1:1 复刻 v2.8：标题「播放历史」、按今天/昨天/更早分组、每行 DSBookRow + 右侧「＋书架/已在书架」胶囊 + 左滑删除 + 清空）
struct HistoryView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(DSBannerCoordinator.self) private var banner

    @State private var sections: [HistorySectionGroup] = []
    @State private var showClearAllAlert = false

    var body: some View {
        Group {
            if sections.isEmpty {
                DSStateView(
                    kind: .empty,
                    titleOverride: "暂无播放历史",
                    messageOverride: "收听过的有声书会自动记录在这里",
                    primaryTitleOverride: "去发现",
                    onPrimary: { router.selectTab(.discover) },
                    onSecondary: nil
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.group.title) {
                            ForEach(section.items) { item in
                                historyRow(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(DSColors.surfaceBase)
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) {
                    showClearAllAlert = true
                }
                .disabled(sections.isEmpty)
                .frame(minHeight: 44)
            }
        }
        .alert("清空播放历史", isPresented: $showClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("清空播放历史", role: .destructive) {
                Task { await clearAllHistory() }
            }
        } message: {
            Text("确认清空全部播放历史？仅清空播放记录，不会影响书架书籍与本地离线音频。")
        }
        .onChange(of: container.libraryRevision) { _, _ in
            Task { await reload() }
        }
        .task { await reload() }
    }

    private func historyRow(_ item: LibraryBookItem) -> some View {
        HStack(spacing: DSSpacing.sm) {
            DSBookRow(
                book: item.book,
                subtitle: item.progressSubtitle.isEmpty ? nil : item.progressSubtitle,
                pipeline: container.coverPipeline,
                progressFraction: item.progressFraction,
                isDownloaded: item.isDownloaded,
                onTap: { router.push(.bookDetail(item.book)) }
            )

            Button {
                guard !item.inShelf else { return }
                Task { await addToShelf(item) }
            } label: {
                Text(item.inShelf ? "已在书架" : "＋书架")
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(item.inShelf ? DSColors.inkSecondary : DSColors.accent)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(DSColors.surfaceGrouped))
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .disabled(item.inShelf)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await deleteHistory(item) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func reload() async {
        let dlStats = LibraryOrganizerHelper.downloadStatsByBookID(from: downloads.manualRecords)
        let context = ModelContext(container.modelContainer)
        var desc = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor<BookEntity>(\.lastPlayedAt, order: .reverse)]
        )
        desc.fetchLimit = 200
        let entities = (try? context.fetch(desc)) ?? []
        let items = entities.map { entity in
            let stat = dlStats[entity.id] ?? (0, 0)
            return LibraryBookItem(
                book: entity.toSummaryDTO(),
                isPinned: entity.isPinned,
                inShelf: entity.inShelf,
                addedToShelfAt: entity.addedToShelfAt,
                lastPlayedAt: entity.lastPlayedAt,
                lastChapterIndex: entity.lastChapterIndex,
                lastChapterTitle: entity.lastChapterTitle,
                lastPositionMs: entity.lastPositionMs,
                lastDurationMs: entity.lastDurationMs,
                downloadedCount: stat.count,
                downloadedBytes: stat.bytes,
                hasUpdate: false
            )
        }
        sections = LibraryOrganizerHelper.groupHistoryByDate(items)
    }

    private func addToShelf(_ item: LibraryBookItem) async {
        do {
            try await container.persistence.upsertBook(item.book, addToShelf: true)
            DSHaptics.selection()
            container.notifyLibraryChanged()
            banner.show("已加入书架", tone: .success)
            await reload()
        } catch {
            banner.show("加入书架失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func clearAllHistory() async {
        do {
            try await container.persistence.clearAllHistory()
            await reload()
            container.notifyLibraryChanged()
            banner.show("已清空全部播放历史", tone: .info)
        } catch {
            banner.show("清空播放历史失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func deleteHistory(_ item: LibraryBookItem) async {
        do {
            try await container.persistence.clearHistory(bookID: item.id)
            DSHaptics.lightImpact()
            await reload()
            container.notifyLibraryChanged()
            banner.show("已清除《\(item.book.title)》的播放历史", tone: .info)
        } catch {
            banner.show("删除播放历史失败：\(error.localizedDescription)", tone: .error)
        }
    }
}
