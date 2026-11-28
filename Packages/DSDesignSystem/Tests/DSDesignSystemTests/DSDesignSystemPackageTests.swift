import CoreGraphics
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

    func testShelfBookmarkBadgeMetricsAndClearance() {
        for side in [CGFloat(44), 52, 72, 84, 100, 110, 160, 175] {
            let m = DSShelfBookmarkMetrics.resolve(forCoverSide: side)
            let cornerRadius = DSRadius.cover(forSide: side)
            XCTAssertGreaterThanOrEqual(m.trailingInset, cornerRadius)
            XCTAssertGreaterThanOrEqual(m.width, 7.5)
            XCTAssertLessThanOrEqual(m.width, 14.5)
            XCTAssertGreaterThan(m.height, m.width)
            XCTAssertLessThanOrEqual(m.trailingInset + m.width, side * 0.45)
        }
    }

    func testDownloadedBadgeMetricsAndContainment() {
        let cases: [(CGFloat, CGFloat, CGFloat)] = [
            (50, 13.0, 3.5),
            (60, 14.5, 4.0),
            (64, 14.5, 4.0),
            (105, 16.0, 5.0),
            (160, 17.5, 6.0)
        ]
        for (side, expectedDiameter, expectedInset) in cases {
            let m = DSDownloadedBadgeMetrics.resolve(forCoverSide: side)
            XCTAssertEqual(m.diameter, expectedDiameter)
            XCTAssertEqual(m.inset, expectedInset)
            XCTAssertGreaterThanOrEqual(m.arrowStrokeWidth, 1.25)
            XCTAssertLessThanOrEqual(m.inset + m.diameter, side * 0.40)
        }
    }
}
