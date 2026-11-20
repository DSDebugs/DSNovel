import SwiftUI

struct CoverWarmPalette: Equatable, Sendable {
    let topHex: UInt32
    let bottomHex: UInt32

    var topColor: Color { Self.color(from: topHex) }
    var bottomColor: Color { Self.color(from: bottomHex) }

    private static func color(from hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

struct CoverPlaceholder: View {
    let title: String
    let side: CGFloat

    init(title: String, side: CGFloat) {
        self.title = title
        self.side = side
    }

    static let palettes: [CoverWarmPalette] = [
        CoverWarmPalette(topHex: 0xA85734, bottomHex: 0x6B321C),
        CoverWarmPalette(topHex: 0x9C6B3B, bottomHex: 0x5E3E1F),
        CoverWarmPalette(topHex: 0x8F4B43, bottomHex: 0x542822),
        CoverWarmPalette(topHex: 0x7A5C49, bottomHex: 0x453226),
        CoverWarmPalette(topHex: 0x6E6248, bottomHex: 0x3D3626),
        CoverWarmPalette(topHex: 0x8A564A, bottomHex: 0x4C2D26)
    ]

    static func paletteIndex(for title: String) -> Int {
        var hash: UInt64 = 5381
        for b in title.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(b)
        }
        return Int(hash % UInt64(palettes.count))
    }

    static func firstCharacter(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "书" }
        return String(first)
    }

    var body: some View {
        let palette = Self.palettes[Self.paletteIndex(for: title)]
        ZStack {
            LinearGradient(
                colors: [palette.topColor, palette.bottomColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(Self.firstCharacter(for: title))
                .font(side >= 90 ? DSTypography.bookTitleLarge : DSTypography.bookTitleMedium)
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: side, height: side)
    }
}

#Preview("Light") {
    CoverPlaceholder(title: "诡秘之主", side: 120)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    CoverPlaceholder(title: "道德经", side: 120)
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    CoverPlaceholder(title: "人间失格", side: 120)
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
