import SwiftUI

enum DSTypography {
    static let bookTitleLarge = Font.system(.title2, design: .serif).weight(.semibold)
    static let bookTitleMedium = Font.system(.title3, design: .serif).weight(.semibold)
    static let sectionHeader = Font.title3.weight(.semibold)
    static let rowTitle = Font.headline
    static let body = Font.body
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let subtitle = Font.footnote
    static let caption = Font.caption
    static let caption2 = Font.caption2
    static let numericFootnote = Font.footnote.monospacedDigit()
    static let numericCaption = Font.caption.monospacedDigit()
}
