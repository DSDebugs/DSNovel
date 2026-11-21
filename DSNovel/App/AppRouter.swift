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
    var isSourceImportPresented: Bool = false

    private(set) var pendingParserSourceID: String?
    private(set) var pendingSourceFocus: (sourceID: String, focus: SourceFocus)?
    private var lastProcessedRoute: Route?
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
        if lastProcessedRoute == route && (now - lastProcessedTime) < 0.25 {
            return
        }
        lastProcessedRoute = route
        lastProcessedTime = now

        if isPlayerPresented {
            isPlayerPresented = false
            isBottomBarHidden = false
        }

        if case .sourceImport = route {
            isSourceImportPresented = true
            return
        }

        let destinationTab = Self.targetTab(for: route, currentTab: selectedTab)
        if destinationTab != selectedTab {
            isBottomBarHidden = false
            selectedTab = destinationTab
        }

        if case .sourceDetail(let id, let focus) = route {
            if let focus {
                pendingSourceFocus = (id, focus)
            }
        }

        appendRoute(route, to: destinationTab)
    }

    func searchByNarrator(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isPlayerPresented {
            isPlayerPresented = false
        }
        isBottomBarHidden = false
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
            if case .sourceDetail(let targetID, _) = normalized {
                if mePath.first == .sourceList,
                   let existingIndex = mePath.firstIndex(where: {
                       if case .sourceDetail(let existingID, _) = $0 {
                           return existingID == targetID
                       }
                       return false
                   }) {
                    if existingIndex == mePath.count - 1 {
                        mePath[existingIndex] = normalized
                    } else {
                        mePath = Array(mePath.prefix(existingIndex)) + [normalized]
                    }
                } else {
                    mePath = [.sourceList, normalized]
                }
            } else if normalized == .sourceList || normalized == .downloads {
                if let existingIndex = mePath.firstIndex(of: normalized) {
                    mePath = Array(mePath.prefix(existingIndex + 1))
                } else {
                    mePath = [normalized]
                }
            } else if mePath.last != normalized {
                mePath.append(normalized)
            }
        case .search:
            if searchPath.last != normalized { searchPath.append(normalized) }
        }
    }

    func openBuiltinParser(sourceID: String?) {
        let trimmed = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            pendingParserSourceID = nil
            pendingSourceFocus = nil
            open(.sourceList)
            return
        }
        pendingParserSourceID = trimmed
        open(.sourceDetail(id: trimmed, focus: .builtinParser))
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
        isSourceImportPresented = false
        pendingParserSourceID = nil
        pendingSourceFocus = nil
        lastProcessedRoute = nil
        lastProcessedTime = 0
    }
}
