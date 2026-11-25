import SwiftUI
import UIKit

private struct DSNightDimEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct DSReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var dsNightDimEnabled: Bool {
        get { self[DSNightDimEnabledKey.self] }
        set { self[DSNightDimEnabledKey.self] = newValue }
    }

    var dsReduceMotion: Bool {
        get { self[DSReduceMotionKey.self] }
        set { self[DSReduceMotionKey.self] = newValue }
    }

    var dsEffectiveReduceMotion: Bool {
        accessibilityReduceMotion || dsReduceMotion
    }
}

/// 液态玻璃主题与语义色彩令牌（规则 #3：Features 层严禁硬编码 RGB/Hex，统一引用此处）
public enum DSColors {
    public struct RGB: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public var color: Color {
            Color(red: r, green: g, blue: b)
        }
    }

    /// 从主应用 Asset Catalog 解析命名色彩资产（与 `App/Resources/Assets.xcassets` 保持同名映射）
    private static func mainAssetColor(_ name: String) -> Color {
        Color(name, bundle: .main)
    }

    // MARK: - v3.0 语义色彩（全量保留）
    public static let accent = mainAssetColor("AccentColor")
    public static let onAccent = mainAssetColor("OnAccent")
    public static let surfaceBase = mainAssetColor("SurfaceBase")
    public static let surfaceCard = mainAssetColor("SurfaceCard")
    public static let surfaceGrouped = mainAssetColor("SurfaceGrouped")
    public static let inkPrimary = Color.primary
    public static let inkSecondary = Color.secondary
    public static let success = Color.green
    public static let warning = Color.orange
    public static let danger = Color.red
    public static let nightDimOverlay = Color.black.opacity(0.32)

    // MARK: - v2.8 分割线与夜间降亮色阶
    public static let separator = Color(uiColor: .separator)

    public static let surfaceBaseLightRGB = RGB(r: 0xFB / 255.0, g: 0xF9 / 255.0, b: 0xF6 / 255.0)
    public static let surfaceBaseDarkRGB = RGB(r: 0x12 / 255.0, g: 0x11 / 255.0, b: 0x10 / 255.0)
    public static let surfaceBaseNightDimRGB = RGB(r: 0x0A / 255.0, g: 0x09 / 255.0, b: 0x08 / 255.0)

    public static let surfaceGroupedLightRGB = RGB(r: 0xF3 / 255.0, g: 0xF0 / 255.0, b: 0xEB / 255.0)
    public static let surfaceGroupedDarkRGB = RGB(r: 0x17 / 255.0, g: 0x15 / 255.0, b: 0x13 / 255.0)
    public static let surfaceGroupedNightDimRGB = RGB(r: 0x10 / 255.0, g: 0x0F / 255.0, b: 0x0E / 255.0)

    public static let surfaceCardLightRGB = RGB(r: 1.0, g: 1.0, b: 1.0)
    public static let surfaceCardDarkRGB = RGB(r: 0x1C / 255.0, g: 0x1A / 255.0, b: 0x18 / 255.0)
    public static let surfaceCardNightDimRGB = RGB(r: 0x15 / 255.0, g: 0x13 / 255.0, b: 0x12 / 255.0)

    public static let accentLightRGB = RGB(r: 0xC4 / 255.0, g: 0x54 / 255.0, b: 0x1F / 255.0)
    public static let accentDarkRGB = RGB(r: 0xFF / 255.0, g: 0x8A / 255.0, b: 0x4C / 255.0)
    public static let accentNightDimRGB = RGB(r: 0xE5 / 255.0, g: 0x7E / 255.0, b: 0x47 / 255.0)

    public static let surfaceBaseNightDim: Color = dynamicColor(light: surfaceBaseLightRGB, dark: surfaceBaseNightDimRGB)
    public static let surfaceGroupedNightDim: Color = dynamicColor(light: surfaceGroupedLightRGB, dark: surfaceGroupedNightDimRGB)
    public static let surfaceCardNightDim: Color = dynamicColor(light: surfaceCardLightRGB, dark: surfaceCardNightDimRGB)
    public static let accentNightDim: Color = dynamicColor(light: accentLightRGB, dark: accentNightDimRGB)

    public static func resolvedSurfaceBase(nightDim: Bool) -> Color {
        nightDim ? surfaceBaseNightDim : surfaceBase
    }

    public static func resolvedSurfaceGrouped(nightDim: Bool) -> Color {
        nightDim ? surfaceGroupedNightDim : surfaceGrouped
    }

    public static func resolvedSurfaceCard(nightDim: Bool) -> Color {
        nightDim ? surfaceCardNightDim : surfaceCard
    }

    public static func resolvedAccent(nightDim: Bool) -> Color {
        nightDim ? accentNightDim : accent
    }

    private static func dynamicColor(light: RGB, dark: RGB) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }
}

/// 间距令牌（保留 v3.0 全部属性并补充 v2.8 语义间距）
public enum DSSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32

    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s7: CGFloat = 32
    public static let s8: CGFloat = 48

    public static let pageHorizontal: CGFloat = 16
    public static let sectionVertical: CGFloat = 20
    public static let gridColumnSpacing: CGFloat = 12
    public static let gridRowSpacing: CGFloat = 16
    public static let largeCardRowSpacing: CGFloat = 20
}

/// 圆角令牌（保留 v3.0 全部属性并补充 v2.8 封面与卡片圆角）
public enum DSRadius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 18
    public static let pill: CGFloat = 999

    public static let coverSmall: CGFloat = 8
    public static let coverLarge: CGFloat = 12
    public static let input: CGFloat = 14
    public static let card: CGFloat = 16
    public static let heroCard: CGFloat = 24

    public static func cover(forSide side: CGFloat) -> CGFloat {
        side >= 100 ? coverLarge : coverSmall
    }
}

/// 动态字体令牌（规则 #2：严禁在 Features/Components 中使用 .font(.system(size:))，全面适配 AX1–AX5）
public enum DSTypography {
    public static let largeTitle: Font = .largeTitle.weight(.bold)
    public static let title: Font = .title2.weight(.bold)
    public static let headline: Font = .headline
    public static let subheadline: Font = .subheadline
    public static let body: Font = .body
    public static let callout: Font = .callout
    public static let footnote: Font = .footnote
    public static let caption: Font = .caption
    public static let monoCaption: Font = .caption.monospacedDigit()

    // MARK: - v2.8 衬线书名与等宽数字令牌
    public static let bookTitleLarge: Font = .system(.title2, design: .serif).weight(.semibold)
    public static let bookTitleMedium: Font = .system(.title3, design: .serif).weight(.semibold)
    public static let sectionHeader: Font = .title3.weight(.semibold)
    public static let rowTitle: Font = .headline
    public static let cardTitle: Font = .subheadline.weight(.semibold)
    public static let subtitle: Font = .footnote
    public static let caption2: Font = .caption2
    public static let numericFootnote: Font = .footnote.monospacedDigit()
    public static let numericCaption: Font = .caption.monospacedDigit()
}

/// 减弱动态感知的动画工具（规则 #4/#5：严禁 repeatForever 与无 value 动画）
public enum DSMotion {
    public static let snappy: Animation = .snappy(duration: 0.28)
    public static let smooth: Animation = .smooth(duration: 0.38)
    public static let bouncy: Animation = .bouncy(duration: 0.45, extraBounce: 0.12)
    public static let ambient: Animation = .easeInOut(duration: 0.6)
    public static let quick: Animation = .easeOut(duration: 0.15)
    public static let follow: Animation = .interactiveSpring(response: 0.28, dampingFraction: 0.86)
    public static let progressLinear: Animation = .linear(duration: 0.35)

    public static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    public static func withResolved<Result>(
        _ animation: Animation? = DSMotion.snappy,
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if reduceMotion {
            return try body()
        }
        return try withAnimation(animation, body)
    }
}

/// v2.8 卡片按压微缩放样式（按压缩放 0.97，遵循减弱动态效果）
public struct DSCardButtonStyle: ButtonStyle {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == DSCardButtonStyle {
    static var dsCard: DSCardButtonStyle { DSCardButtonStyle() }
}

/// 轻量触觉反馈工具（主线程触发，支持节流防抖）
public enum DSHaptics {
    @MainActor
    private static var lastMinuteTickAt: TimeInterval = 0

    @MainActor
    public static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor
    public static func scrubberMinuteTick() {
        let now = Date().timeIntervalSince1970
        guard (now - lastMinuteTickAt) >= 0.15 else { return }
        lastMinuteTickAt = now
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor
    public static func lightImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
