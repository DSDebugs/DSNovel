import SwiftUI

/// 液态玻璃主题与语义色彩令牌（规则 #3：Features 层严禁硬编码 RGB/Hex，统一引用此处）
/// 说明（AUD-61）：语义色集存放于主应用 `App/Resources/Assets.xcassets`（与 `project.yml` 的 `AccentColor` 保持完全兼容），
/// 通过显式 `bundle: .main` 解析确保在独立 Swift Package 模块中稳定加载主应用色彩资产。
public enum DSColors {
    /// 从主应用 Asset Catalog 解析命名色彩资产（与 `App/Resources/Assets.xcassets` 保持同名映射）
    private static func mainAssetColor(_ name: String) -> Color {
        Color(name, bundle: .main)
    }

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
}

/// 间距与圆角令牌
public enum DSSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
}

public enum DSRadius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 18
    public static let pill: CGFloat = 999
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
}

/// 减弱动态感知的动画工具（规则 #4/#5：严禁 repeatForever 与无 value 动画）
public enum DSMotion {
    public static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    public static func withResolved<Result>(
        _ animation: Animation? = .snappy(duration: 0.24),
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if reduceMotion {
            return try body()
        }
        return try withAnimation(animation, body)
    }
}
