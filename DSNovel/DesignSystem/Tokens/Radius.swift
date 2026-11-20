import CoreGraphics

enum Radius {
    static let coverSmall: CGFloat = 8
    static let coverLarge: CGFloat = 12
    static let input: CGFloat = 14
    static let card: CGFloat = 16
    static let heroCard: CGFloat = 24

    static func cover(forSide side: CGFloat) -> CGFloat {
        side >= 100 ? coverLarge : coverSmall
    }
}
