import CoreGraphics
import Foundation
import Testing
@testable import DSDesignSystem

@Suite("翡翠玉珠已下载圆章全尺寸几何闭环测试")
struct DSDownloadedBadgeTests {
    @Test("全尺寸直径、内边距与严格内嵌不等式校验")
    func metricsScaleProportionallyAndStayInsideCover() {
        let sizes: [(side: CGFloat, expectedDiameter: CGFloat, expectedInset: CGFloat)] = [
            (50, 13.0, 3.5),
            (60, 14.5, 4.0),
            (64, 14.5, 4.0),
            (105, 16.0, 5.0),
            (110, 16.0, 5.0),
            (160, 17.5, 6.0)
        ]
        for item in sizes {
            let m = DSDownloadedBadgeMetrics.resolve(forCoverSide: item.side)
            #expect(m.diameter == item.expectedDiameter)
            #expect(m.inset == item.expectedInset)
            #expect(m.arrowStrokeWidth >= 1.25)
            #expect(m.inset + m.diameter <= item.side * 0.40)
        }
    }
}
