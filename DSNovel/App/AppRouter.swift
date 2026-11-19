import SwiftUI
import Observation

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: ShellTab = .library
    var libraryPath: [Route] = []
    var discoverPath: [Route] = []
    var mePath: [Route] = []
    var searchPath: [Route] = []
    var isPlayerPresented: Bool = false
    var isBottomBarHidden: Bool = false

    private(set) var pendingParserSourceID: String?
    private(set) var pendingSourceFocus: (sourceID: String, focus: SourceFocus)?
    private var lastProcessedRequestKey: String?
    private var lastProcessedTime: TimeInterval = 0

    init() {}

    func pathBinding(for tab: ShellTab) -> Binding<[Route]> {
        Binding(
            get: {
                switch tab {
                case .library: return self.libraryPath
                case .discover: return self.discoverPath
                case .me: return self.mePath
                case .search: return self.searchPath
                }
            },
            set: { newValue in
                switch tab {
                case .library: self.libraryPath = newValue
                case .discover: self.discoverPath = newValue
                case .me: self.mePath = newValue
                case .search: self.searchPath = newValue
                }
            }
        )
    }

    static func targetTab(for route: Route, currentTab: ShellTab) -> ShellTab {
        switch route {
        case .book:
            return currentTab
        case .history:
            return .library
        case .downloads, .downloadManager:
            return .me
        case .sourceList, .sourceDetail, .sourceImport, .pluginManager, .playbackMore, .about:
            return .me
        }
    }

    func open(_ route: Route, now: TimeInterval = Date().timeIntervalSince1970) {
        let reqKey = "\(route)"
        if lastProcessedRequestKey == reqKey && (now - lastProcessedTime) < 0.25 {
            return
        }
        lastProcessedRequestKey = reqKey
        lastProcessedTime = now

        if isPlayerPresented {
            isPlayerPresented = false
            isBottomBarHidden = false
        }

        let destinationTab = Self.targetTab(for: route, currentTab: selectedTab)
        selectedTab = destinationTab

        if case .sourceDetail(let id, let focus) = route {
            if let focus {
                pendingSourceFocus = (id, focus)
            }
            if destinationTab == .me && !mePath.contains(.sourceList) {
                mePath.append(.sourceList)
            }
        }

        appendRoute(route, to: destinationTab)
    }

    func searchByNarrator(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isPlayerPresented {
            isPlayerPresented = false
            isBottomBarHidden = false
        }
        selectedTab = .search
        popToRoot(for: .search)
        let sources = SearchStore.shared.activeTargetSources(
            from: SourceStore.shared.allSources,
            groups: SourceStore.shared.groups
        )
        SearchStore.shared.submit(
            keyword: name,
            sources: sources,
            modelContext: SourceStore.shared.modelContext
        )
    }

    private func appendRoute(_ route: Route, to tab: ShellTab) {
        let normalized: Route
        switch route {
        case .pluginManager:
            normalized = .sourceList
        case .downloadManager:
            normalized = .downloads
        default:
            normalized = route
        }

        switch tab {
        case .library:
            if libraryPath.last != normalized { libraryPath.append(normalized) }
        case .discover:
            if discoverPath.last != normalized { discoverPath.append(normalized) }
        case .me:
            if mePath.last != normalized { mePath.append(normalized) }
        case .search:
            if searchPath.last != normalized { searchPath.append(normalized) }
        }
    }

    func openBuiltinParser(sourceID: String?) {
        let sid = sourceID ?? ""
        pendingParserSourceID = sid
        open(.sourceDetail(id: sid, focus: .builtinParser))
    }

    func consumePendingParserFocus() -> String? {
        defer {
            pendingParserSourceID = nil
            pendingSourceFocus = nil
        }
        return pendingParserSourceID
    }

    func popToRoot(for tab: ShellTab) {
        switch tab {
        case .library: libraryPath.removeAll()
        case .discover: discoverPath.removeAll()
        case .me: mePath.removeAll()
        case .search: searchPath.removeAll()
        }
    }

    func isAtRoot(for tab: ShellTab) -> Bool {
        switch tab {
        case .library: return libraryPath.isEmpty
        case .discover: return discoverPath.isEmpty
        case .me: return mePath.isEmpty
        case .search: return searchPath.isEmpty
        }
    }

    func resetForTesting() {
        selectedTab = .library
        libraryPath.removeAll()
        discoverPath.removeAll()
        mePath.removeAll()
        searchPath.removeAll()
        isPlayerPresented = false
        isBottomBarHidden = false
        pendingParserSourceID = nil
        pendingSourceFocus = nil
        lastProcessedRequestKey = nil
        lastProcessedTime = 0
    }
}
