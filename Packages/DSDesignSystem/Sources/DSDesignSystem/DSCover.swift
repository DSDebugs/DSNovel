import SwiftUI
import UIKit

/// 暖色渐变占位色板（1:1 复刻 v2.8）
public struct CoverWarmPalette: Equatable, Sendable {
    public let topHex: UInt32
    public let bottomHex: UInt32

    public init(topHex: UInt32, bottomHex: UInt32) {
        self.topHex = topHex
        self.bottomHex = bottomHex
    }

    public var topColor: Color { Self.color(from: topHex) }
    public var bottomColor: Color { Self.color(from: bottomHex) }

    private static func color(from hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// 暖色渐变 + 衬线首字封面占位（1:1 复刻 v2.8）
public struct CoverPlaceholder: View {
    public let title: String
    public let side: CGFloat?

    public init(title: String, side: CGFloat? = nil) {
        self.title = title
        self.side = side
    }

    public static let palettes: [CoverWarmPalette] = [
        CoverWarmPalette(topHex: 0xA85734, bottomHex: 0x6B321C),
        CoverWarmPalette(topHex: 0x9C6B3B, bottomHex: 0x5E3E1F),
        CoverWarmPalette(topHex: 0x8F4B43, bottomHex: 0x542822),
        CoverWarmPalette(topHex: 0x7A5C49, bottomHex: 0x453226),
        CoverWarmPalette(topHex: 0x6E6248, bottomHex: 0x3D3626),
        CoverWarmPalette(topHex: 0x8A564A, bottomHex: 0x4C2D26)
    ]

    public static func paletteIndex(for title: String) -> Int {
        var hash: UInt64 = 5381
        for byte in title.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash % UInt64(palettes.count))
    }

    public static func firstCharacter(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "书" }
        return String(first)
    }

    public var body: some View {
        let palette = Self.palettes[Self.paletteIndex(for: title)]
        let useLargeFont = (side ?? 100) >= 90
        ZStack {
            LinearGradient(
                colors: [palette.topColor, palette.bottomColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(Self.firstCharacter(for: title))
                .font(useLargeFont ? DSTypography.bookTitleLarge : DSTypography.bookTitleMedium)
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: side, height: side)
    }
}

/// 封面角标类型与优先级（0 进度条 > 1 已下载 > 2 更新橙点 > 3 VIP）
public enum DSCoverBadge: Equatable, Hashable, Sendable {
    case progress(Double)
    case downloaded
    case updated
    case vip

    public var priority: Int {
        switch self {
        case .progress: return 0
        case .downloaded: return 1
        case .updated: return 2
        case .vip: return 3
        }
    }

    public static func topTwo(_ badges: [DSCoverBadge]) -> [DSCoverBadge] {
        Array(badges.sorted(by: { $0.priority < $1.priority }).prefix(2))
    }

    public static func progressValue(in badges: [DSCoverBadge]) -> Double? {
        for badge in badges {
            if case .progress(let value) = badge {
                return min(max(value, 0), 1)
            }
        }
        return nil
    }
}

/// 1:1 正方形封面组件（1:1 复刻 v2.8 DSCover，接入 v3.0 CoverImagePipeline）
public struct DSCover: View {
    private let url: String
    private let title: String
    private let pipeline: CoverImagePipeline
    private let side: CGFloat
    private let badges: [DSCoverBadge]
    private let showsBorder: Bool
    private let showsSoftShadow: Bool
    private let onImageLoaded: ((UIImage) -> Void)?
    @State private var loadedImage: UIImage?

    public init(
        url: String,
        title: String,
        pipeline: CoverImagePipeline,
        side: CGFloat = 96,
        badges: [DSCoverBadge] = [],
        showsBorder: Bool = true,
        showsSoftShadow: Bool = false,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.url = url
        self.title = title
        self.pipeline = pipeline
        self.side = side
        self.badges = badges
        self.showsBorder = showsBorder
        self.showsSoftShadow = showsSoftShadow
        self.onImageLoaded = onImageLoaded
        _loadedImage = State(initialValue: pipeline.cachedImageSync(for: url))
    }

    private var cornerRadius: CGFloat { DSRadius.cover(forSide: side) }

    public var body: some View {
        let visibleBadges = DSCoverBadge.topTwo(badges)
        ZStack(alignment: .topTrailing) {
            coverContent(image: loadedImage)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(DSColors.separator.opacity(0.35), lineWidth: 0.5)
                    }
                }
            DSCoverBadgeOverlay(badges: visibleBadges, cornerRadius: cornerRadius)
                .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .shadow(
            color: showsSoftShadow ? Color.black.opacity(0.10) : .clear,
            radius: showsSoftShadow ? 6 : 0,
            y: showsSoftShadow ? 3 : 0
        )
        .task(id: url) {
            let cached = pipeline.cachedImageSync(for: url)
            loadedImage = cached
            if let cached {
                onImageLoaded?(cached)
                return
            }
            let fetched = await pipeline.image(for: url)
            guard !Task.isCancelled else { return }
            loadedImage = fetched
            if let fetched { onImageLoaded?(fetched) }
        }
    }

    @ViewBuilder
    private func coverContent(image: UIImage?) -> some View {
        if let image {
            if side >= 200 && !Self.isAspectNearlySquare(image) {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .blur(radius: 18)
                        .overlay(Color.black.opacity(0.22))
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                }
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            }
        } else {
            CoverPlaceholder(title: title, side: side)
        }
    }

    public static func isAspectNearlySquare(_ image: UIImage) -> Bool {
        guard image.size.height > 0 else { return true }
        let ratio = image.size.width / image.size.height
        return ratio >= 0.85 && ratio <= 1.15
    }
}

/// 兼容 v3.0 全部现有调用的异步封面视图（支持暖色占位、角标、毛玻璃兜底与加载回调）
public struct DSCoverImage: View {
    private let urlString: String
    private let pipeline: CoverImagePipeline
    private let cornerRadius: CGFloat
    private let title: String
    private let badges: [DSCoverBadge]
    private let showsBorder: Bool
    private let showsSoftShadow: Bool
    private let onCoverLoaded: ((UIImage) -> Void)?

    @State private var image: UIImage?
    @State private var renderedSide: CGFloat = 0

    public init(
        urlString: String,
        pipeline: CoverImagePipeline,
        cornerRadius: CGFloat = DSRadius.sm,
        title: String = "",
        badges: [DSCoverBadge] = [],
        showsBorder: Bool = false,
        showsSoftShadow: Bool = true,
        onCoverLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.urlString = urlString
        self.pipeline = pipeline
        self.cornerRadius = cornerRadius
        self.title = title
        self.badges = badges
        self.showsBorder = showsBorder
        self.showsSoftShadow = showsSoftShadow
        self.onCoverLoaded = onCoverLoaded
        _image = State(initialValue: pipeline.cachedImageSync(for: urlString))
    }

    public var body: some View {
        let visibleBadges = DSCoverBadge.topTwo(badges)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay {
                if let uiImage = image {
                    if renderedSide >= 200 && !DSCover.isAspectNearlySquare(uiImage) {
                        ZStack {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 18)
                                .overlay(Color.black.opacity(0.22))
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                        }
                    } else {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    }
                } else if !title.isEmpty {
                    CoverPlaceholder(title: title, side: nil)
                } else {
                    Image(systemName: "headphones")
                        .font(DSTypography.headline)
                        .foregroundStyle(DSColors.inkSecondary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if !visibleBadges.isEmpty {
                    DSCoverBadgeOverlay(badges: visibleBadges, cornerRadius: cornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(DSColors.separator.opacity(0.35), lineWidth: 0.5)
                }
            }
            .shadow(
                color: showsSoftShadow ? .black.opacity(0.08) : .clear,
                radius: showsSoftShadow ? 6 : 0,
                y: showsSoftShadow ? 3 : 0
            )
            .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { renderedSide = $0 }
            .task(id: urlString) {
                let cached = pipeline.cachedImageSync(for: urlString)
                image = cached
                if let cached {
                    onCoverLoaded?(cached)
                    return
                }
                let loaded = await pipeline.image(for: urlString)
                guard !Task.isCancelled else { return }
                image = loaded
                if let loaded { onCoverLoaded?(loaded) }
            }
    }
}

/// 封面顶部/底部优先级角标叠层（零 GeometryReader）
private struct DSCoverBadgeOverlay: View {
    let badges: [DSCoverBadge]
    let cornerRadius: CGFloat
    @State private var width: CGFloat = 0

    var body: some View {
        let progress = DSCoverBadge.progressValue(in: badges)
        ZStack {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    switch badge {
                    case .downloaded:
                        Image(systemName: "arrow.down.circle.fill")
                            .font(DSTypography.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    case .updated:
                        Circle()
                            .fill(DSColors.accent)
                            .frame(width: 8, height: 8)
                            .padding(6)
                    case .vip:
                        Text("VIP")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(DSColors.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DSColors.accent))
                            .padding(4)
                    case .progress:
                        EmptyView()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let progress {
                VStack {
                    Spacer(minLength: 0)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 3)
                        Rectangle().fill(DSColors.accent).frame(width: max(0, width * progress), height: 3)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}
