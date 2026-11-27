import CoreGraphics
import Foundation
import Testing
@testable import DSDesignSystem

@Suite("丝带红书签角标全尺寸几何闭环测试")
struct DSShelfBookmarkBadgeTests {
    @Test("全尺寸缩放与圆角防撞不等式校验")
    func metricsPreventCornerClippingAcrossAllCoverSizes() {
        let coverSizes: [CGFloat] = [44, 52, 72, 84, 100, 110, 160, 175]
        for side in coverSizes {
            let m = DSShelfBookmarkMetrics.resolve(forCoverSide: side)
            let cornerRadius = DSRadius.cover(forSide: side)
            #expect(m.trailingInset >= cornerRadius)
            #expect(m.width >= 7.5 && m.width <= 14.5)
            #expect(m.height > m.width)
            #expect(m.trailingInset + m.width <= side * 0.45)
        }
    }

    @Test("发现页榜单排名角标与书签角标共存净空校验")
    func rankBadgeAndBookmarkNeverCollide() {
        let rankOccupiedWidth: CGFloat = 24 // 20pt badge + 4pt leading padding
        for side in [CGFloat(72), 84, 105, 110, 160] {
            let m = DSShelfBookmarkMetrics.resolve(forCoverSide: side)
            let bookmarkOccupiedWidth = m.trailingInset + m.width
            let centerGap = side - rankOccupiedWidth - bookmarkOccupiedWidth
            #expect(centerGap >= 28)
        }
    }
}
