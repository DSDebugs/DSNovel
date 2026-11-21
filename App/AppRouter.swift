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
    case appearancePrefs
    case playbackPrefs
    case storagePrefs
    case about
    case diagnostics
}

/// 强类型 4 Tab 独立导航栈与弹窗协调路由器
@Observable
@MainActor
final class AppRouter {
    var selectedTab: DSMainTab = .library
    var discoverPath: [AppDestination] = []
    var searchPath: [AppDestination] = []
    var libraryPath: [AppDestination] = []
    var mePath: [AppDestination] = []

    var isPlayerPresented: Bool = false
    var scrollToTopTrigger: [DSMainTab: Int] = [:]

    func selectTab(_ tab: DSMainTab) {
        if selectedTab == tab {
            if !path(for: tab).isEmpty {
                setPath([], for: tab)
            } else {
                scrollToTopTrigger[tab, default: 0] += 1
            }
        } else {
            selectedTab = tab
        }
    }

    func push(_ destination: AppDestination, on tab: DSMainTab? = nil) {
        let target = tab ?? selectedTab
        var current = path(for: target)
        current.append(destination)
        setPath(current, for: target)
    }

    func popToRoot(on tab: DSMainTab? = nil) {
        setPath([], for: tab ?? selectedTab)
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
