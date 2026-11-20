import SwiftUI
import UIKit

enum DSColor {
    static var primary: Color { Color.dsAccent }
    static var contentBackground: Color { Color.dsSurfaceBase }
    static var groupedBackground: Color { Color.dsSurfaceGrouped }
    static var cardSurface: Color { Color.dsSurfaceCard }

    static func placeholder(for key: String) -> Color {
        let palette = CoverPlaceholder.palettes[CoverPlaceholder.paletteIndex(for: key)]
        return palette.topColor
    }
}

enum DSSpacing {
    static let xs: CGFloat = Spacing.s1
    static let sm: CGFloat = Spacing.s2
    static let md: CGFloat = Spacing.s3
    static let lg: CGFloat = Spacing.s4
    static let xl: CGFloat = Spacing.s6
}

