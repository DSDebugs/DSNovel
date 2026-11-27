import SwiftUI

/// 全尺寸封面「已下载」翡翠玉珠圆章几何参数
public struct DSDownloadedBadgeMetrics: Equatable, Sendable {
    public let diameter: CGFloat
    public let inset: CGFloat
    public let arrowStrokeWidth: CGFloat

    public init(diameter: CGFloat, inset: CGFloat, arrowStrokeWidth: CGFloat) {
        self.diameter = diameter
        self.inset = inset
        self.arrowStrokeWidth = arrowStrokeWidth
    }

    /// 依据封面边长连续缩放（0.5pt 对齐），并按同心圆角原则严格内嵌于封面右上角内部
    public static func resolve(forCoverSide side: CGFloat) -> DSDownloadedBadgeMetrics {
        let safeSide = Swift.max(24, side)
        let rawDiameter: CGFloat
        if safeSide <= 52 {
            rawDiameter = 13.0
        } else if safeSide <= 68 {
            rawDiameter = 14.5
        } else if safeSide <= 125 {
            rawDiameter = 16.0
        } else {
            rawDiameter = 17.5
        }

        let rawInset: CGFloat
        if safeSide <= 52 {
            rawInset = 3.5
        } else if safeSide <= 68 {
            rawInset = 4.0
        } else if safeSide <= 125 {
            rawInset = 5.0
        } else {
            rawInset = 6.0
        }

        let stroke = ((rawDiameter * 0.115) * 4).rounded() / 4
        return DSDownloadedBadgeMetrics(
            diameter: rawDiameter,
            inset: rawInset,
            arrowStrokeWidth: Swift.max(1.25, stroke)
        )
    }
}

/// 纯矢量精雕居中向下箭头路径（不受动态字体放大撑破圆章）
private struct DSDownloadedArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let midX = rect.midX
        let topY = rect.minY + h * 0.25
        let tipY = rect.minY + h * 0.74
        let wingY = rect.minY + h * 0.52
        let wingHalf = w * 0.22

        path.move(to: CGPoint(x: midX, y: topY))
        path.addLine(to: CGPoint(x: midX, y: tipY))

        path.move(to: CGPoint(x: midX - wingHalf, y: wingY))
        path.addLine(to: CGPoint(x: midX, y: tipY))
        path.addLine(to: CGPoint(x: midX + wingHalf, y: wingY))
        return path
    }
}

/// 全尺寸统一「已下载」翡翠玉珠微渐变圆章（45° 翡翠渐变 + 顶部微高光 + 0.5pt 暖白内环 + 精雕单箭头 + 克制贴面投影）
public struct DSDownloadedBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    public let coverSide: CGFloat

    public init(coverSide: CGFloat) {
        self.coverSide = coverSide
    }

    private var topJadeColor: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.72, blue: 0.44)
            : Color(red: 0.19, green: 0.77, blue: 0.45)
    }

    private var bottomJadeColor: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.48, blue: 0.28)
            : Color(red: 0.09, green: 0.54, blue: 0.31)
    }

    public var body: some View {
        let metrics = DSDownloadedBadgeMetrics.resolve(forCoverSide: coverSide)
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [topJadeColor, bottomJadeColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.26),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.38, y: 0.22),
                        startRadius: 0,
                        endRadius: metrics.diameter * 0.55
                    )
                )

            Circle()
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.30 : 0.48),
                    lineWidth: 0.5
                )

            DSDownloadedArrowShape()
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: metrics.arrowStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .shadow(color: Color.black.opacity(0.18), radius: 0.5, x: 0, y: 0.5)
        }
        .frame(width: metrics.diameter, height: metrics.diameter)
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.22),
            radius: 2,
            x: 0,
            y: 1
        )
        .padding(.top, metrics.inset)
        .padding(.trailing, metrics.inset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
