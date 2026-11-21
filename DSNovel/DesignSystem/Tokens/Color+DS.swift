import SwiftUI
import UIKit

private struct DSNightDimEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var dsNightDimEnabled: Bool {
        get { self[DSNightDimEnabledKey.self] }
        set { self[DSNightDimEnabledKey.self] = newValue }
    }
}

enum DSColorTokenSpec {
    struct RGB: Equatable, Sendable {
        let r: Double
        let g: Double
        let b: Double

        var relativeLuminance: Double {
            func channel(_ c: Double) -> Double {
                c <= 0.03928 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
            let l1 = max(a.relativeLuminance, b.relativeLuminance)
            let l2 = min(a.relativeLuminance, b.relativeLuminance)
            return (l1 + 0.05) / (l2 + 0.05)
        }
    }

    static let surfaceBaseLight = RGB(r: 0xFB / 255.0, g: 0xF9 / 255.0, b: 0xF6 / 255.0)
    static let surfaceBaseDark = RGB(r: 0x12 / 255.0, g: 0x11 / 255.0, b: 0x10 / 255.0)
    static let surfaceBaseNightDim = RGB(r: 0x0A / 255.0, g: 0x09 / 255.0, b: 0x08 / 255.0)

    static let surfaceGroupedLight = RGB(r: 0xF3 / 255.0, g: 0xF0 / 255.0, b: 0xEB / 255.0)
    static let surfaceGroupedDark = RGB(r: 0x17 / 255.0, g: 0x15 / 255.0, b: 0x13 / 255.0)
    static let surfaceGroupedNightDim = RGB(r: 0x10 / 255.0, g: 0x0F / 255.0, b: 0x0E / 255.0)

    static let surfaceCardLight = RGB(r: 1.0, g: 1.0, b: 1.0)
    static let surfaceCardDark = RGB(r: 0x1C / 255.0, g: 0x1A / 255.0, b: 0x18 / 255.0)
    static let surfaceCardNightDim = RGB(r: 0x15 / 255.0, g: 0x13 / 255.0, b: 0x12 / 255.0)

    static let accentLight = RGB(r: 0xC4 / 255.0, g: 0x54 / 255.0, b: 0x1F / 255.0)
    static let accentDark = RGB(r: 0xFF / 255.0, g: 0x8A / 255.0, b: 0x4C / 255.0)
    static let accentNightDim = RGB(r: 0xE5 / 255.0, g: 0x7E / 255.0, b: 0x47 / 255.0)

    static let onAccentLight = RGB(r: 1.0, g: 1.0, b: 1.0)
    static let onAccentDark = RGB(r: 0x1A / 255.0, g: 0x0E / 255.0, b: 0x08 / 255.0)

    static func resolveSurfaceBase(isDark: Bool, nightDim: Bool) -> RGB {
        guard isDark else { return surfaceBaseLight }
        return nightDim ? surfaceBaseNightDim : surfaceBaseDark
    }

    static func resolveAccent(isDark: Bool, nightDim: Bool) -> RGB {
        guard isDark else { return accentLight }
        return nightDim ? accentNightDim : accentDark
    }
}

extension Color {
    /// 读取实时夜间降亮开关：主线程直接订阅 `@Observable AppSettingsStore.shared.nightDimEnabled`，
    /// 确保全 Tab 与 Sheet 在切换开关时即时刷新，且避免与外层黑罩双层叠暗。
    private static var currentNightDimEnabled: Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { AppSettingsStore.shared.nightDimEnabled }
        }
        return UserDefaults.standard.bool(forKey: "nightDimEnabled")
    }

    static var dsSurfaceBase: Color {
        let nightDim = currentNightDimEnabled
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = DSColorTokenSpec.resolveSurfaceBase(isDark: isDark, nightDim: nightDim)
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }

    static var dsSurfaceGrouped: Color {
        let nightDim = currentNightDimEnabled
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark
                ? (nightDim ? DSColorTokenSpec.surfaceGroupedNightDim : DSColorTokenSpec.surfaceGroupedDark)
                : DSColorTokenSpec.surfaceGroupedLight
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }

    static var dsSurfaceCard: Color {
        let nightDim = currentNightDimEnabled
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark
                ? (nightDim ? DSColorTokenSpec.surfaceCardNightDim : DSColorTokenSpec.surfaceCardDark)
                : DSColorTokenSpec.surfaceCardLight
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }

    static var dsAccent: Color {
        let nightDim = currentNightDimEnabled
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = DSColorTokenSpec.resolveAccent(isDark: isDark, nightDim: nightDim)
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }

    static var dsOnAccent: Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark ? DSColorTokenSpec.onAccentDark : DSColorTokenSpec.onAccentLight
            return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        })
    }

    static let dsSeparator = Color(uiColor: .separator)
}
