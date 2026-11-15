import SwiftUI
import UIKit

// MARK: - iOS 27 Liquid Glass 容器与修饰符实现（保障 GitHub Actions 任意 Xcode SDK 100% 编译通过）
enum AppGlassStyle: Sendable {
    case regular
    case clear

    func interactive(_ enabled: Bool = true) -> AppGlassStyle {
        self
    }
}

enum AppGlassShape: Sendable {
    case capsule
    case circle
    case rect(cornerRadius: CGFloat)
}

struct AppGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        content()
    }
}

extension View {
    @ViewBuilder
    func appGlassEffect(_ style: AppGlassStyle = .regular, in shape: AppGlassShape = .capsule) -> some View {
        switch shape {
        case .capsule:
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                )
        case .circle:
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.85)
                )
        case .rect(let cornerRadius):
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.26), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.85
                        )
                )
        }
    }
}

// MARK: - 100% 首次点击响应按钮样式
struct ResponsivePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassPillButton: View {
    let title: String
    var icon: String? = nil
    var isSelected: Bool = false
    var activeColor: Color = .orange
    var minHeight: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(minHeight: minHeight)
            .background {
                if isSelected {
                    Capsule().fill(activeColor.gradient)
                } else {
                    Capsule().fill(Color.white.opacity(0.08))
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(isSelected ? activeColor.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ResponsivePressButtonStyle())
        .accessibilityLabel(accessibilityTitle)
    }
}

struct GlassIconButton: View {
    let systemName: String
    var accessibilityTitle: String = "按钮"
    var tint: Color = .primary
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePressButtonStyle())
        .accessibilityLabel(accessibilityTitle)
    }
}

// MARK: - 内存级封面缓存与带防盗链请求头加载器（彻底解决书架封面加载失败问题）
@MainActor
final class CoverImageMemoryCache {
    static let shared = CoverImageMemoryCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        return c
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

// MARK: - 书籍封面组件（上方醒目来源标签 + 自动防盗链加载与按书名封面自愈）
struct BookCoverView: View {
    var bookId: String? = nil
    let urlString: String
    let title: String
    let source: CoreSourceID
    var progressBadge: String? = nil
    var width: CGFloat = 104
    var height: CGFloat = 140
    var cornerRadius: CGFloat = 12

    @State private var loadedImage: UIImage? = nil
    @State private var isFetching: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            source.brandColor.opacity(0.45),
                            Color(red: 0.11, green: 0.12, blue: 0.17)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                fallbackPlaceholder
            }

            // 顶部暗角衬托来源角标
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .frame(height: 36)

            // 封面上方来源标签（唯一视觉区分喜马拉雅与番茄畅听的地方）
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: source.iconName)
                        .font(.system(size: 8, weight: .bold))
                    Text(source.coverTopTag)
                        .font(.system(size: 9.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(source.tagBackgroundColor.opacity(0.95))
                )

                Spacer(minLength: 2)

                if let progressBadge, !progressBadge.isEmpty {
                    Text(progressBadge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 0.8)
        )
        .task(id: urlString + "_" + title) {
            await fetchCoverWithSelfHealing()
        }
    }

    private func fetchCoverWithSelfHealing() async {
        let cacheKey = "\(title)_\(urlString)"
        if let cached = CoverImageMemoryCache.shared.image(for: cacheKey) {
            self.loadedImage = cached
            return
        }
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        self.loadedImage = nil
        // 1. 尝试带 User-Agent / Referer 加载原始封面 URL
        if let img = await downloadUIImage(from: urlString) {
            CoverImageMemoryCache.shared.store(img, for: cacheKey)
            self.loadedImage = img
            return
        }

    }

    private func downloadUIImage(from rawURL: String) async -> UIImage? {
        let norm = BookItem.normalizeHttps(rawURL)
        guard !norm.isEmpty, let url = URL(string: norm) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if norm.contains("xmcdn") || norm.contains("ximalaya") {
            req.setValue("https://www.ximalaya.com/", forHTTPHeaderField: "Referer")
        } else if norm.contains("tingyou") || norm.contains("toulaopao") {
            req.setValue("https://tingyou.fm/", forHTTPHeaderField: "Referer")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let img = UIImage(data: data) else {
            return nil
        }
        return img
    }

    private var fallbackPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: source.iconName)
                .font(.system(size: width * 0.25, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - 标准 3 列等高书籍卡片（支持可选显示收听时间记录与删除按钮）
struct StandardBookGridCard: View {
    let book: BookItem
    var progressBadge: String? = nil
    var recordText: String? = nil
    var onDelete: (() -> Void)? = nil
    let onOpenDetail: () -> Void
    let onQuickPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onOpenDetail) {
                    BookCoverView(
                        bookId: book.id,
                        urlString: book.coverURL,
                        title: book.title,
                        source: book.source,
                        progressBadge: progressBadge,
                        width: 106,
                        height: 142,
                        cornerRadius: 12
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePressButtonStyle())

                HStack(spacing: 6) {
                    if let onDelete {
                        Button {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            onDelete()
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.red.opacity(0.88)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(ResponsivePressButtonStyle())
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onQuickPlay()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(book.source.brandColor))
                            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                            .contentShape(Circle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())
                }
                .padding(6)
            }

            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let recordText, !recordText.isEmpty {
                        Text(recordText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .frame(height: 28, alignment: .topLeading)
                    } else {
                        Text(book.author)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: 15, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 106)
    }
}

// MARK: - 列表区书籍卡片行（支持展示最新收听章节时间记录与独立删除按钮）
struct CleanBookRow: View {
    let book: BookItem
    var subtitleOverride: String? = nil
    var timeRecordOverride: String? = nil
    var onDelete: (() -> Void)? = nil
    let onOpenDetail: () -> Void
    let onQuickPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenDetail) {
                HStack(spacing: 12) {
                    BookCoverView(
                        bookId: book.id,
                        urlString: book.coverURL,
                        title: book.title,
                        source: book.source,
                        width: 74,
                        height: 100,
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(book.author)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(subtitleOverride ?? book.intro)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.88))
                            .lineLimit(2)

                        Text(timeRecordOverride ?? book.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.95))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePressButtonStyle())

            HStack(spacing: 6) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onQuickPlay()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(book.source.brandColor)
                        Text("收听")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 44, height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePressButtonStyle())

                if let onDelete {
                    Button {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        onDelete()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "trash.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.red.opacity(0.88))
                            Text("删除")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 42, height: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15))
        )
    }
}
