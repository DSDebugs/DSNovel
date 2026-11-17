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
    @State private var localScrollAnchor: String?

    init() {}

    private var currentSourceName: String {
        let name = sourceStore.sourceName(for: discoverStore.currentSourceID)
        return name.isEmpty ? "发现" : name
    }

    private var truncatedSourceTitle: String {
        if currentSourceName.count > 8 {
            return String(currentSourceName.prefix(8)) + "…"
        }
        return currentSourceName
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
        contentArea
            .background(Color.dsSurfaceBase)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !sectionChips.isEmpty || tabChips.count > 1 {
                    VStack(spacing: Spacing.s2) {
                        if !sectionChips.isEmpty {
                            DSChipBar(
                                items: sectionChips,
                                selection: Binding(
                                    get: { discoverStore.selectedSectionIndex },
                                    set: { idx in
                                        discoverStore.saveAnchor(localScrollAnchor)
                                        Task {
                                            await discoverStore.selectSection(idx)
                                            localScrollAnchor = discoverStore.savedScrollAnchor()
                                        }
                                    }
                                )
                            )
                        }

                        if tabChips.count > 1 {
                            DSChipBar(
                                items: tabChips,
                                selection: Binding(
                                    get: { discoverStore.selectedTabIndex },
                                    set: { idx in
                                        discoverStore.saveAnchor(localScrollAnchor)
                                        Task {
                                            await discoverStore.selectTab(idx)
                                            localScrollAnchor = discoverStore.savedScrollAnchor()
                                        }
                                    }
                                )
                            )
                        }
                    }
                    .padding(.vertical, Spacing.s2)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
                        SourceTitleMenu(
                            sources: sourceStore.discoverableSources,
                            currentSourceID: discoverStore.currentSourceID,
                            onSelectSource: { sid in
                                discoverStore.saveAnchor(localScrollAnchor)
                                Task {
                                    await discoverStore.switchSource(to: sid)
                                    localScrollAnchor = discoverStore.savedScrollAnchor()
                                }
                            },
                            onMoreSources: { showMoreSourcesSheet = true },
                            onManageSources: { AppRouter.shared.open(.sourceList) }
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Text(truncatedSourceTitle)
                                .font(DSTypography.rowTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.dsSurfaceGrouped))
                    }
                    .accessibilityIdentifier("discover.sourceSwitcher")
                }

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
                            discoverStore.saveAnchor(localScrollAnchor)
                            Task {
                                await discoverStore.switchSource(to: src.id)
                                localScrollAnchor = discoverStore.savedScrollAnchor()
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
                    }
                }
            }
            .onDisappear {
                discoverStore.saveAnchor(localScrollAnchor)
            }
            .task {
                sourceStore.modelContext = modelContext
                libraryStore.modelContext = modelContext
                if discoverStore.currentSourceID.isEmpty,
                   let first = sourceStore.discoverableSources.first {
                    discoverStore.currentSourceID = first.id
                }
                await discoverStore.loadCategoryMenusAndFirstPage(forceReload: false)
                localScrollAnchor = discoverStore.savedScrollAnchor()
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
            DiscoverContent(
                books: discoverStore.currentBooks,
                shelfBookIDs: libraryStore.shelfBookIDs,
                layoutStyle: settings.discoverLayout,
                isLoadingMore: discoverStore.isLoadingMore,
                loadMoreFailed: discoverStore.loadMoreFailed,
                localScrollAnchor: $localScrollAnchor,
                onSelectBook: { ref in AppRouter.shared.open(.book(ref)) },
                onAddToShelf: { ref in addRefToShelf(ref) },
                onCopyLink: { ref in
                    UIPasteboard.general.string = ref.bookURL
                    DSHapticPolicy.fire(.selection)
                    BannerCenter.shared.show("已复制", kind: .info)
                },
                onReachLoadMoreTrigger: { itemID in
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
