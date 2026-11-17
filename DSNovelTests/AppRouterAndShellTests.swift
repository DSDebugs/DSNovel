import XCTest
import SwiftUI
@testable import DSNovel

final class AppRouterAndShellTests: XCTestCase {

    @MainActor
    func testAppRouterNavigationAndDeduplication() {
        let router = AppRouter.shared
        router.resetForTesting()

        let ref = BookRef(sourceID: "s1", bookURL: "https://e.com/1", title: "测试书")
        // 1. 同标签追加
        router.selectedTab = .library
        router.open(.book(ref), now: 100.0)
        XCTAssertEqual(router.selectedTab, .library)
        XCTAssertEqual(router.libraryPath.count, 1)

        // 2. 重复调用去重（250ms 内相同路由忽略）
        router.open(.book(ref), now: 100.1)
        XCTAssertEqual(router.libraryPath.count, 1)

        // 3. 跨标签跳转（播放器展开时自动收起）
        router.isPlayerPresented = true
        router.open(.downloads, now: 105.0)
        XCTAssertFalse(router.isPlayerPresented)
        XCTAssertEqual(router.selectedTab, .me)
        XCTAssertTrue(router.mePath.contains(.downloads))

        // 4. openBuiltinParser 转调 .sourceDetail(id, focus: .builtinParser)
        router.openBuiltinParser(sourceID: "xmly_source")
        XCTAssertEqual(router.selectedTab, .me)
        XCTAssertTrue(router.mePath.contains(.sourceList))
        XCTAssertTrue(router.mePath.contains(.sourceDetail(id: "xmly_source", focus: .builtinParser)))
        XCTAssertEqual(router.consumePendingParserFocus(), "xmly_source")
        XCTAssertNil(router.consumePendingParserFocus())

        router.resetForTesting()
    }

    @MainActor
    func testMiniPlayerStaticPartDoesNotReevaluateOnClockTicks() {
        MiniPlayerRenderCounter.shared.reset()
        let staticView = MiniPlayerStaticContent(
            bookTitle: "诡秘之主",
            coverURL: "",
            chapterTitle: "第 1 章",
            isFailed: false,
            density: .expanded
        )
        _ = staticView.body

        let clock = PlaybackClock()
        clock.durationSec = 600
        for step in 1...10 {
            clock.currentTimeSec = Double(step * 5)
        }
        XCTAssertLessThanOrEqual(MiniPlayerRenderCounter.shared.staticBodyEvaluations, 1)
    }
}
