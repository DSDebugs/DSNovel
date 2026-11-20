import Foundation
import Observation

@MainActor
@Observable
final class ScrollToTopCenter {
    static let shared = ScrollToTopCenter()

    private(set) var triggers: [ShellTab: Int] = [
        .library: 0,
        .discover: 0,
        .me: 0,
        .search: 0
    ]

    init() {}

    func requestScrollToTop(in tab: ShellTab) {
        triggers[tab, default: 0] &+= 1
    }

    func count(for tab: ShellTab) -> Int {
        triggers[tab, default: 0]
    }
}
