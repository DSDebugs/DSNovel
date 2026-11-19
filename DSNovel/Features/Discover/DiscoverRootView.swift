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
    @FocusState private var isSearchFocused: Bool

    init() {}

    private var currentSourceName: String {
        let name = sourceStore.sourceName(for: discoverStore.currentSourceID)
        return name.isEmpty ? "发现" : name
    }

    private var currentSectionTitle: String {
        let secs = discoverStore.currentSections
        let idx = discoverStore.selectedSectionIndex
        return secs.indices.contains(idx) ? secs[idx].title : "分类"
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
        let _ = DiscoverRenderCounter.shared.recordRoot()
        VStack(spacing: 0) {
            DiscoverHeaderBar(
                currentSourceName: currentSourceName,
                searchKeyword: $discoverStore.searchKeyword,
                isSearchActive: discoverStore.isSearchActive,
                layoutStyle: $settings.discoverLayout,
                sectionChips: sectionChips,
                tabChips: tabChips,
                selectedSectionIndex: discoverStore.selectedSectionIndex,
                selectedTabIndex: discoverStore.selectedTabIndex,
                currentSectionTitle: currentSectionTitle,
                isSearchFocused: $isSearchFocused,
                onOpenSourcePicker: { showMoreSourcesSheet = true },
                onSubmitSearch: {
                    isSearchFocused = false
                    discoverStore.submitSourceSearch()
                },
                onClearSearch: {
                    isSearchFocused = false
                    discoverStore.clearSourceSearch()
                },
                onSelectSection: { idx in
                    Task {
                        await discoverStore.selectSection(idx)
                    }
                },
                onSelectTab: { idx in
                    Task {
                        await discoverStore.selectTab(idx)
                    }
                }
            )

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.dsSurfaceBase)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMoreSourcesSheet) {
            sourcePickerSheet
        }
        .onChange(of: discoverStore.searchKeyword) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && discoverStore.isSearchActive {
                discoverStore.clearSourceSearch()
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

    private var sourcePickerSheet: some View {
        let grouped = sourceStore.groupedSections(from: sourceStore.discoverableSources, includeEmptyGroups: false)
        return DSSheetScaffold(title: "选择书源", onClose: { showMoreSourcesSheet = false }) {
            List {
                ForEach(grouped) { section in
                    Section(section.title) {
                        ForEach(section.sources) { src in
                            Button {
                                showMoreSourcesSheet = false
                                Task {
                                    await discoverStore.switchSource(to: src.id)
                                }
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
                            .listRowBackground(Color.dsSurfaceCard)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if sourceStore.discoverableSources.isEmpty {
            centeredState {
                DSStateView(
                    kind: .noSource,
                    onPrimary: { AppRouter.shared.open(.sourceImport) },
                    onSecondary: { AppRouter.shared.open(.sourceList) }
                )
            }
        } else if discoverStore.isSearchActive {
            scopedSearchContent
        } else if discoverStore.isLoadingInitial && discoverStore.currentBooks.isEmpty {
            DSSkeleton(mode: .grid)
                .padding(.top, Spacing.s3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = discoverStore.lastError, discoverStore.currentBooks.isEmpty {
            let kind = UserFacingError.from(err, sourceName: currentSourceName)
            centeredState {
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
            }
        } else if discoverStore.currentBooks.isEmpty {
            centeredState {
                DSStateView(
                    kind: .empty,
                    onPrimary: { showMoreSourcesSheet = true },
                    onSecondary: { Task { await discoverStore.loadFirstPage(forceReload: true) } }
                )
            }
        } else {
            discoverBooksGrid(books: discoverStore.currentBooks, isPaged: true)
        }
    }

    @ViewBuilder
    private var scopedSearchContent: some View {
        if discoverStore.isSearchingInSource && discoverStore.searchResults.isEmpty {
            DSSkeleton(mode: .list(rows: 6))
                .padding(.top, Spacing.s3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = discoverStore.searchError, discoverStore.searchResults.isEmpty {
            let kind = UserFacingError.from(err, sourceName: currentSourceName)
            centeredState {
                DSStateView(
                    kind: kind,
                    onPrimary: {
                        if case .needLogin = kind {
                            AuthCoordinator.shared.presentLogin(forSourceID: discoverStore.currentSourceID)
                        } else {
                            discoverStore.submitSourceSearch()
                        }
                    },
                    onSecondary: { discoverStore.clearSourceSearch() }
                )
            }
        } else if discoverStore.searchResults.isEmpty {
            centeredState {
                DSStateView(
                    kind: .empty,
                    onPrimary: { discoverStore.clearSourceSearch() },
                    onSecondary: { discoverStore.submitSourceSearch() }
                )
            }
        } else {
            discoverBooksGrid(books: discoverStore.searchResults, isPaged: false)
        }
    }

    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: Spacing.s6)
            content()
            Spacer(minLength: Spacing.s6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func discoverBooksGrid(books: [BookRef], isPaged: Bool) -> some View {
        DiscoverContent(
            books: books,
            shelfBookIDs: libraryStore.shelfBookIDs,
            layoutStyle: settings.discoverLayout,
            isLoadingMore: isPaged ? discoverStore.isLoadingMore : false,
            loadMoreFailed: isPaged ? discoverStore.loadMoreFailed : false,
            onRefresh: {
                if discoverStore.isSearchActive {
                    discoverStore.submitSourceSearch()
                } else {
                    await discoverStore.loadFirstPage(forceReload: true)
                }
            },
            onSelectBook: { ref in AppRouter.shared.open(.book(ref)) },
            onAddToShelf: { ref in addRefToShelf(ref) },
            onCopyLink: { ref in
                UIPasteboard.general.string = ref.bookURL
                DSHapticPolicy.fire(.selection)
                BannerCenter.shared.show("已复制", kind: .info)
            },
            onReachLoadMoreTrigger: { itemID in
                if isPaged {
                    Task { await discoverStore.loadNextPageIfNeeded(currentItemID: itemID) }
                }
            },
            onRetryLoadMore: {
                if isPaged {
                    Task { await discoverStore.loadNextPageIfNeeded(currentItemID: nil) }
                }
            }
        )
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
            totalChapters: ref.chapterCount,
            speed: AppSettingsStore.shared.defaultSpeed
        )
        modelContext.insert(b)
        try? modelContext.save()
        DSHapticPolicy.fire(.success)
        BannerCenter.shared.show("已加入书架", kind: .success)
        libraryStore.refreshNow()
    }
}
