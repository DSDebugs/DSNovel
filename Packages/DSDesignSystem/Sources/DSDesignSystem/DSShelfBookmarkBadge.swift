import SwiftUI

/// 全尺寸封面「已在书架」丝带书签等比尺寸参数
public struct DSShelfBookmarkMetrics: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let trailingInset: CGFloat
    public let notchRatio: CGFloat

    public init(width: CGFloat, height: CGFloat, trailingInset: CGFloat, notchRatio: CGFloat = 0.24) {
        self.width = width
        self.height = height
        self.trailingInset = trailingInset
        self.notchRatio = notchRatio
    }

    /// 依据封面边长连续缩放，并保证右侧内距严格 ≥ 封面圆角半径，数学上杜绝圆角裁切
    public static func resolve(forCoverSide side: CGFloat) -> DSShelfBookmarkMetrics {
        let safeSide = Swift.max(24, side)
        let cornerRadius = DSRadius.cover(forSide: safeSide)
        let rawWidth = safeSide * 0.125
        let snappedWidth = (rawWidth * 2).rounded() / 2
        let width = Swift.min(14.5, Swift.max(7.5, snappedWidth))
        let height = ((width * 1.50) * 2).rounded() / 2
        return DSShelfBookmarkMetrics(
            width: width,
            height: height,
            trailingInset: cornerRadius,
            notchRatio: 0.24
        )
    }
}

/// 闭合燕尾丝带书签填充路径
private struct DSShelfBookmarkFillShape: Shape {
    let notchRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notchY = rect.maxY * (1 - notchRatio)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: notchY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 开放三边高光描边路径（顶边不描边，与封面顶部边缘无缝衔接）
private struct DSShelfBookmarkThreeSideStrokeShape: Shape {
    let notchRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 0.25
        let bottomInset: CGFloat = 0.35
        let notchY = rect.maxY * (1 - notchRatio) - bottomInset
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - bottomInset))
        path.addLine(to: CGPoint(x: rect.midX, y: notchY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - bottomInset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        return path
    }
}

/// 全尺寸统一「已在书架」丝带红书签角标（纯矢量 + 主题色丝绸渐变 + 三边细高光 + 克制贴面投影）
public struct DSShelfBookmarkBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    public let coverSide: CGFloat

    public init(coverSide: CGFloat) {
        self.coverSide = coverSide
    }

    public var body: some View {
        let metrics = DSShelfBookmarkMetrics.resolve(forCoverSide: coverSide)
        ZStack {
            DSShelfBookmarkFillShape(notchRatio: metrics.notchRatio)
                .fill(DSColors.accent)
            DSShelfBookmarkFillShape(notchRatio: metrics.notchRatio)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.clear,
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            DSShelfBookmarkThreeSideStrokeShape(notchRatio: metrics.notchRatio)
                .stroke(
                    Color.white.opacity(colorScheme == .dark ? 0.24 : 0.38),
                    style: StrokeStyle(lineWidth: 0.5, lineCap: .butt, lineJoin: .miter)
                )
        }
        .frame(width: metrics.width, height: metrics.height)
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.22),
            radius: 2,
            x: 0,
            y: 1.2
        )
        .padding(.trailing, metrics.trailingInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
