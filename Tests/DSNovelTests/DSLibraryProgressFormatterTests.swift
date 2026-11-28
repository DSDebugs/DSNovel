import XCTest
@testable import DSNovel

final class DSLibraryProgressFormatterTests: XCTestCase {
    func testSegmentedPercentageFormattingAndFallbacks() {
        // 未收听返回 nil
        XCTAssertNil(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 1754,
                lastChapterIndex: 0,
                lastPositionMs: 0,
                lastDurationMs: 0,
                hasPlayed: false
            )
        )

        // 千章长篇极早期显示 <0.1%
        XCTAssertEqual(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 1754,
                lastChapterIndex: 0,
                lastPositionMs: 10_000,
                lastDurationMs: 600_000,
                hasPlayed: true
            ),
            "已听 <0.1%"
        )

        // <10% 保留 1 位小数（如 4.5%）
        XCTAssertEqual(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 1754,
                lastChapterIndex: 78,
                lastPositionMs: 300_000,
                lastDurationMs: 600_000,
                hasPlayed: true
            ),
            "已听 4.5%"
        )

        // >=10% 取整
        XCTAssertEqual(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 1000,
                lastChapterIndex: 679,
                lastPositionMs: 300_000,
                lastDurationMs: 600_000,
                hasPlayed: true
            ),
            "已听 68%"
        )

        // 末章播完显示 已听完 100%
        XCTAssertEqual(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 100,
                lastChapterIndex: 99,
                lastPositionMs: 595_000,
                lastDurationMs: 600_000,
                hasPlayed: true
            ),
            "已听完 100%"
        )

        // 总章数缺失时优雅降级为 本章 XX%
        XCTAssertEqual(
            LibraryBookItem.formatProgressBadge(
                totalChapters: 0,
                lastChapterIndex: 3,
                lastPositionMs: 420_000,
                lastDurationMs: 600_000,
                hasPlayed: true
            ),
            "本章 70%"
        )
    }
}
