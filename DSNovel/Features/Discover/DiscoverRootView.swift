import SwiftUI
import SwiftData
import UIKit

struct DiscoverRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var discoverStore = DiscoverStore.shared
    @State private var sourceStore = SourceStore.shared
    @State private var libraryStore = LibraryStore.shared
    @State private var settings = AppSettingsStore.shared
    @State private var showMoreSourcesSheet = false

    init() {}

    private var currentSourceName: String {
        sourceStore.sourceName(for: discoverStore.currentSourceID)
    }

    private var sectionChips: [DSChipItem<Int>] {
        discoverStore.currentSections.enumerated().map { idx, sec in
            DSChipItem(id: idx, title: sec.title)
        }
    }

    private var tabChips: [DSChipItem<Int>] {
        discoverStore.currentTabs.enumerated().map { idx, tab in
            DSChipItem(id: idx, title: tab.title)
        }
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            if !sectionChips.isEmpty {
                DSChipBar(
                    items: sectionChips,
                    selection: Binding(
                        get: { discoverStore.selectedSectionIndex },
                        set: { idx in Task { await discoverStore.selectSection(idx) } }
                    )
                )
            }

            if tabChips.count > 1 {
                DSChipBar(
                    items: tabChips,
                    selection: Binding(
                        get: { discoverStore.selectedTabIndex },
                        set: { idx in Task { await discoverStore.selectTab(idx) } }
                    )
                )
            }

            contentArea
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle(currentSourceName.isEmpty ? "发现" : currentSourceName)
        .toolbarTitleMenu {
            SourceTitleMenu(
                sources: sourceStore.discoverableSources,
                currentSourceID: discoverStore.currentSourceID,
                onSelectSource: { sid in Task { await discoverStore.switchSource(to: sid) } },
                onMoreSources: { showMoreSourcesSheet = true },
                onManageSources: { AppRouter.shared.open(.sourceList) }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("视图", selection: $settings.discoverLayout) {
                        ForEach(DiscoverLayoutStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("切换视图")
            }
        }
        .refreshable {
            await discoverStore.loadFirstPage(forceReload: true)
        }
        .sheet(isPresented: $showMoreSourcesSheet) {
            DSSheetScaffold(title: "选择书源", onClose: { showMoreSourcesSheet = false }) {
                List(sourceStore.discoverableSources) { src in
                    Button {
                        showMoreSourcesSheet = false
                        Task { await discoverStore.switchSource(to: src.id) }
                    } label: {
                        HStack {
                            DSSourceBadge(
                                name: src.name,
                                health: DSSourceHealthKind(rawValue: src.lastCheckStatus) ?? .untested,
                                latencyMs: src.lastLatencyMs > 0 ? src.lastLatencyMs : nil
                            )
                            Spacer()
                            if src.id == discoverStore.currentSourceID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }
                    }
                }
            }
        }
        .task {
            sourceStore.modelContext = modelContext
            libraryStore.modelContext = modelContext
            if discoverStore.currentSourceID.isEmpty,
               let first = sourceStore.discoverableSources.first {
                discoverStore.currentSourceID = first.id
            }
            await discoverStore.loadCategoryMenusAndFirstPage(forceReload: false)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if sourceStore.discoverableSources.isEmpty {
            DSStateView(
                kind: .noSource,
                onPrimary: { AppRouter.shared.open(.sourceImport) },
                onSecondary: { AppRouter.shared.open(.sourceList) }
            )
        } else if discoverStore.isLoadingInitial && discoverStore.currentBooks.isEmpty {
            DSSkeleton(mode: .grid)
                .padding(.top, Spacing.s3)
        } else if let err = discoverStore.lastError, discoverStore.currentBooks.isEmpty {
            let kind = UserFacingError.from(err, sourceName: currentSourceName)
            DSStateView(
                kind: kind,
                onPrimary: {
                    if case .needLogin = kind {
                        AuthCoordinator.shared.presentLogin(forSourceID: discoverStore.currentSourceID)
                    } else if case .needVerify = kind {
                        AuthCoordinator.shared.presentLogin(forSourceID: discoverStore.currentSourceID)
                    } else {
                        Task { await discoverStore.loadCategoryMenusAndFirstPage(forceReload: true) }
                    }
                },
                onSecondary: { showMoreSourcesSheet = true }
            )
        } else if discoverStore.currentBooks.isEmpty {
            DSStateView(
                kind: .empty,
                onPrimary: { showMoreSourcesSheet = true },
                onSecondary: { Task { await discoverStore.loadFirstPage(forceReload: true) } }
            )
        } else {
            let shelfSet = Set(libraryStore.allShelfBooks.map(\.id))
            DiscoverContent(
                books: discoverStore.currentBooks,
                shelfBookIDs: shelfSet,
                layoutStyle: settings.discoverLayout,
                isLoadingMore: discoverStore.isLoadingMore,
                loadMoreFailed: discoverStore.loadMoreFailed,
                scrollAnchor: Binding(
                    get: { discoverStore.currentScrollAnchor },
                    set: { discoverStore.currentScrollAnchor = $0 }
                ),
                onSelectBook: { ref in AppRouter.shared.open(.book(ref)) },
                onAddToShelf: { ref in addRefToShelf(ref) },
                onCopyLink: { ref in
                    UIPasteboard.general.string = ref.bookURL
                    DSHapticPolicy.fire(.selection)
                    BannerCenter.shared.show("已复制", kind: .info)
                },
                onAppearItem: { itemID in
                    discoverStore.recordScrollAnchor(itemID)
                    Task { await discoverStore.loadNextPageIfNeeded(currentItemID: itemID) }
                },
                onRetryLoadMore: {
                    Task { await discoverStore.loadNextPageIfNeeded(currentItemID: nil) }
                }
            )
        }
    }

    private func addRefToShelf(_ ref: BookRef) {
        let b = Book(
            id: ref.id,
            sourceID: ref.sourceID,
            bookURL: ref.bookURL,
            title: ref.title,
            author: ref.author,
            cover: ref.cover,
            intro: ref.intro,
            inShelf: true,
            totalChapters: ref.chapterCount
        )
        modelContext.insert(b)
        try? modelContext.save()
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已加入书架", kind: .success)
        libraryStore.refreshNow()
    }
}
