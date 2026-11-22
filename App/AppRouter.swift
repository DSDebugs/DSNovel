import DSCore
import DSDesignSystem
import Foundation
import Observation
import SwiftUI

/// 应用级强类型路由目标
enum AppDestination: Hashable, Sendable {
    case bookDetail(BookSummaryDTO)
    case history
    case downloads
    case bookDownloadDetail(bookID: String, bookTitle: String)
    case sources
    case sourceDetail(sourceID: String)
    case builtinParser
    case playbackPrefs
    case storagePrefs
    case about
}

/// 强类型 4 Tab 独立导航栈与弹窗协调路由器（含 0.25s 路由防抖、底栏显隐与演播人跨 Tab 搜索）
@Observable
@MainActor
final class AppRouter {
    var selectedTab: DSMainTab = .library
    var discoverPath: [AppDestination] = []
    var searchPath: [AppDestination] = []
    var libraryPath: [AppDestination] = []
    var mePath: [AppDestination] = []

    var isPlayerPresented: Bool = false
    var isBottomBarHidden: Bool = false
    var pendingNarratorSearch: String?
    var scrollToTopTrigger: [DSMainTab: Int] = [:]

    private static let routeDebounceInterval: TimeInterval = 0.25
    private var lastPushedTargetTab: DSMainTab?
    private var lastPushedDestination: AppDestination?
    private var lastPushedTimestamp: TimeInterval = 0

    init() {}

    func selectTab(_ tab: DSMainTab) {
        if selectedTab == tab {
            if !path(for: tab).isEmpty {
                setPath([], for: tab)
            } else {
                scrollToTopTrigger[tab, default: 0] += 1
            }
        } else {
            isBottomBarHidden = false
            selectedTab = tab
        }
    }

    func push(
        _ destination: AppDestination,
        on tab: DSMainTab? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let target = tab ?? selectedTab
        if lastPushedTargetTab == target,
           lastPushedDestination == destination,
           (now - lastPushedTimestamp) < Self.routeDebounceInterval {
            return
        }
        lastPushedTargetTab = target
        lastPushedDestination = destination
        lastPushedTimestamp = now

        if isPlayerPresented {
            isPlayerPresented = false
            isBottomBarHidden = false
        }

        var current = path(for: target)
        if current.last != destination {
            current.append(destination)
            setPath(current, for: target)
        }
    }

    func popToRoot(on tab: DSMainTab? = nil) {
        let target = tab ?? selectedTab
        setPath([], for: target)
        if lastPushedTargetTab == target {
            lastPushedDestination = nil
            lastPushedTimestamp = 0
        }
    }

    func searchByNarrator(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isPlayerPresented {
            isPlayerPresented = false
        }
        isBottomBarHidden = false
        selectedTab = .search
        popToRoot(on: .search)
        pendingNarratorSearch = trimmed
    }

    func consumePendingNarratorSearch() -> String? {
        defer { pendingNarratorSearch = nil }
        return pendingNarratorSearch
    }

    func path(for tab: DSMainTab) -> [AppDestination] {
        switch tab {
        case .discover: return discoverPath
        case .search: return searchPath
        case .library: return libraryPath
        case .me: return mePath
        }
    }

    func setPath(_ newPath: [AppDestination], for tab: DSMainTab) {
        switch tab {
        case .discover: discoverPath = newPath
        case .search: searchPath = newPath
        case .library: libraryPath = newPath
        case .me: mePath = newPath
        }
    }
}
