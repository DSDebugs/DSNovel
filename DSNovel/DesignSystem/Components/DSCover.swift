import SwiftUI
import UIKit

enum DSCoverBadge: Equatable, Hashable, Sendable {
    case progress(Double)
    case downloaded
    case updated
    case vip

    var priority: Int {
        switch self {
        case .progress: return 0
        case .downloaded: return 1
        case .updated: return 2
        case .vip: return 3
        }
    }
}

struct DSCover: View {
    @Environment(\.dsReduceMotion) private var reduceMotion
    let url: String
    let title: String
    let side: CGFloat
    let badges: [DSCoverBadge]
    let showsBorder: Bool
    let showsSoftShadow: Bool
    private let onImageLoaded: ((UIImage) -> Void)?

    @State private var loadedImage: UIImage?
    @State private var loadedURL: String = ""
    @State private var animateAppearance = false

    init(
        url: String,
        title: String,
        side: CGFloat = 96,
        badges: [DSCoverBadge] = [],
        showsBorder: Bool = true,
        showsSoftShadow: Bool = false,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.url = url
        self.title = title
        self.side = side
        self.badges = badges
        self.showsBorder = showsBorder
        self.showsSoftShadow = showsSoftShadow
        self.onImageLoaded = onImageLoaded
    }

    static func topTwoBadges(_ badges: [DSCoverBadge]) -> [DSCoverBadge] {
        Array(badges.sorted(by: { $0.priority < $1.priority }).prefix(2))
    }

    private var cornerRadius: CGFloat {
        Radius.cover(forSide: side)
    }

    private var effectiveImage: UIImage? {
        if loadedURL == url, let loadedImage {
            return loadedImage
        }
        return CoverImagePipeline.shared.cachedInMemory(for: url, side: side)
    }

    var body: some View {
        let visibleBadges = Self.topTwoBadges(badges)
        ZStack(alignment: .topTrailing) {
            coverBody(image: effectiveImage)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.dsSeparator.opacity(0.35), lineWidth: 0.5)
                    }
                }

            badgeOverlay(visibleBadges)
        }
        .frame(width: side, height: side)
        .shadow(
            color: showsSoftShadow ? Color.black.opacity(0.10) : .clear,
            radius: showsSoftShadow ? 6 : 0,
            x: 0,
            y: showsSoftShadow ? 3 : 0
        )
        .task(id: url) {
            if let mem = CoverImagePipeline.shared.cachedInMemory(for: url, side: side) {
                loadedImage = mem
                loadedURL = url
                onImageLoaded?(mem)
                return
            }
            if loadedURL != url {
                loadedImage = nil
                animateAppearance = false
            }
            if let fetched = await CoverImagePipeline.shared.image(
                for: url,
                targetSize: CGSize(width: side, height: side)
            ) {
                loadedImage = fetched
                loadedURL = url
                withAnimation(Motion.resolve(.easeOut(duration: 0.25), reduce: reduceMotion)) {
                    animateAppearance = true
                }
                onImageLoaded?(fetched)
            }
        }
    }

    @ViewBuilder
    private func coverBody(image: UIImage?) -> some View {
        if let image {
            let isAspectNearlySquare: Bool = {
                guard image.size.height > 0 else { return true }
                let ratio = image.size.width / image.size.height
                return ratio >= 0.85 && ratio <= 1.15
            }()
            if side >= 200 && !isAspectNearlySquare {
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

    @ViewBuilder
    private func badgeOverlay(_ items: [DSCoverBadge]) -> some View {
        ZStack {
            HStack(spacing: 4) {
                Spacer()
                ForEach(Array(items.enumerated()), id: \.offset) { _, badge in
                    switch badge {
                    case .downloaded:
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    case .updated:
                        Circle()
                            .fill(Color.dsAccent)
                            .frame(width: 8, height: 8)
                            .padding(6)
                    case .vip:
                        Text("VIP")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.dsOnAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.dsAccent))
                            .padding(4)
                    case .progress:
                        EmptyView()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let prog = items.compactMap({ badge -> Double? in
                if case .progress(let v) = badge { return v }
                return nil
            }).first {
                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(height: 3)
                        Rectangle()
                            .fill(Color.dsAccent)
                            .frame(width: max(0, min(1, prog)) * side, height: 3)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
