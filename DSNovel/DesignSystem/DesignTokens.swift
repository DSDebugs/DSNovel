import SwiftUI
import UIKit

enum DSColor {
    static let primary = Color.accentColor
    static let contentBackground = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardSurface = Color(uiColor: .secondarySystemBackground)
    static let placeholderColors: [Color] = [
        Color(red: 0.18, green: 0.32, blue: 0.56),
        Color(red: 0.14, green: 0.45, blue: 0.48),
        Color(red: 0.28, green: 0.25, blue: 0.54),
        Color(red: 0.22, green: 0.42, blue: 0.34),
        Color(red: 0.45, green: 0.28, blue: 0.38)
    ]

    static func placeholder(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let idx = Int(hash % UInt64(placeholderColors.count))
        return placeholderColors[idx]
    }
}

enum DSSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum DominantColorExtractor {
    private static let cache = NSCache<NSString, UIColor>()

    static func extractPrimaryColor(from image: UIImage, cacheKey: String) -> Color {
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return Color(uiColor: cached)
        }
        guard let cgImage = image.cgImage else {
            return Color(red: 0.14, green: 0.22, blue: 0.36)
        }
        let width = 8
        let height = 8
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Color(red: 0.14, green: 0.22, blue: 0.36)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rTotal: Double = 0
        var gTotal: Double = 0
        var bTotal: Double = 0
        let count = Double(width * height)
        for i in stride(from: 0, to: rawData.count, by: 4) {
            rTotal += Double(rawData[i]) / 255.0
            gTotal += Double(rawData[i + 1]) / 255.0
            bTotal += Double(rawData[i + 2]) / 255.0
        }
        let r = max(0.08, min(0.45, (rTotal / count) * 0.65))
        let g = max(0.08, min(0.45, (gTotal / count) * 0.65))
        let b = max(0.12, min(0.50, (bTotal / count) * 0.65))
        let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        cache.setObject(uiColor, forKey: cacheKey as NSString)
        return Color(uiColor: uiColor)
    }
}
