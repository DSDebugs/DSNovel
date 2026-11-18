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

    @MainActor
    func testAppRouterSearchByNarratorDismissesPlayerAndSwitchesToSearch() {
        let router = AppRouter.shared
        router.resetForTesting()
        SearchStore.shared.reset()

        router.selectedTab = .discover
        router.searchPath = [.history]
        router.isPlayerPresented = true
        router.isBottomBarHidden = true

        router.searchByNarrator("  头陀渊讲故事  ")
        XCTAssertFalse(router.isPlayerPresented)
        XCTAssertFalse(router.isBottomBarHidden)
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertTrue(router.searchPath.isEmpty)
        XCTAssertEqual(SearchStore.shared.keyword, "头陀渊讲故事")

        SearchStore.shared.reset()
        router.resetForTesting()
    }

    @MainActor
    func testAudioSubtitleEngineFallbackAndActiveCueLookup() {
        let engine = AudioSubtitleEngine()
        let book = BookRef(
            sourceID: "xmly",
            bookURL: "https://e.com/1",
            title: "凡人修仙传",
            author: "光合积木",
            intro: "一股辛辣的气味冲了上来。他抬起头望了一下莫大夫，对方正似笑非笑地看着他。他略微犹豫了一下，有些怀疑此药。"
        )
        let chapter = ChapterDTO(id: "c25", title: "第25集 暗算与獠牙", url: "https://e.com/c25", index: 24, hintDurationSec: 120)
        let cues = AudioSubtitleEngine.makeFallbackCues(book: book, chapter: chapter, durationSec: 120)
        XCTAssertGreaterThanOrEqual(cues.count, 4)

        engine.loadOrTranscribe(book: book, chapter: chapter, asset: nil, playURL: nil, headers: [:], durationHintSec: 120)
        XCTAssertFalse(engine.cues.isEmpty)
        let idx0 = engine.activeCueIndex(at: 1.0)
        XCTAssertEqual(idx0, 0)
    }
}
