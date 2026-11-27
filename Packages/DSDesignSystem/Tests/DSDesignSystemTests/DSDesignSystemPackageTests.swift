import DSDesignSystem
import Foundation
import XCTest

final class DSDesignSystemPackageTests: XCTestCase {
    func testScrubberTimeFormattingEdgeCases() {
        XCTAssertEqual(DSScrubber.formatTime(0), "00:00")
        XCTAssertEqual(DSScrubber.formatTime(65), "01:05")
        XCTAssertEqual(DSScrubber.formatTime(3661), "1:01:01")
        XCTAssertEqual(DSScrubber.formatTime(-10), "00:00")
        XCTAssertEqual(DSScrubber.formatTime(.nan), "00:00")
        XCTAssertEqual(DSScrubber.formatTime(.infinity), "00:00")
        XCTAssertEqual(DSScrubberLogic.formatTime(0), "00:00")
        XCTAssertEqual(DSScrubberLogic.formatTime(65), "01:05")
        XCTAssertEqual(DSScrubberLogic.formatTime(3661), "1:01:01")
        XCTAssertEqual(DSScrubberLogic.formatTime(-10), "00:00")
        XCTAssertEqual(DSScrubberLogic.formatTime(.nan), "00:00")
        XCTAssertEqual(DSScrubberLogic.formatTime(.infinity), "00:00")
    }

    func testMotionResolvedRespectsReduceMotion() {
        XCTAssertNil(DSMotion.resolved(.default, reduceMotion: true))
        XCTAssertNotNil(DSMotion.resolved(.default, reduceMotion: false))
    }

    func testMainTabMetadataAndIdentifiers() {
        XCTAssertEqual(DSMainTab.allCases.map(\.rawValue), ["discover", "library", "me"])
        XCTAssertEqual(DSMainTab.allCases.map(\.title), ["首页", "书架", "设置"])
        for tab in DSMainTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }
    }

    @MainActor
    func testBannerCoordinatorNestedSheetReferenceCounting() {
        let banner = DSBannerCoordinator()
        XCTAssertFalse(banner.isSheetPresenting)
        banner.registerSheetAppear()
        banner.registerSheetAppear()
        XCTAssertTrue(banner.isSheetPresenting)
        banner.registerSheetDisappear()
        XCTAssertTrue(banner.isSheetPresenting)
        banner.registerSheetDisappear()
        XCTAssertFalse(banner.isSheetPresenting)

        banner.show("已保存", tone: .success, duration: 5)
        XCTAssertEqual(banner.current?.text, "已保存")
        banner.dismiss()
        XCTAssertNil(banner.current)
    }

    func testCoverPipelineRejectsInvalidPayloads() {
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: Data(), contentType: "image/png"))
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: Data("<html>403</html>".utf8), contentType: "text/html"))
        XCTAssertNil(CoverImagePipeline.validateAndDecodeImage(data: Data("not-an-image".utf8), contentType: "image/jpeg"))
    }
}
