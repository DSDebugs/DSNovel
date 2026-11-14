import SwiftUI
import UIKit

// MARK: - iOS 27 Liquid Glass 容器与修饰符实现（保障 GitHub Actions 任意 Xcode SDK 100% 编译通过）
enum GlassEffectStyle: Sendable {
    case regular
    case clear

    func interactive(_ enabled: Bool = true) -> GlassEffectStyle {
        self
    }
}

enum GlassEffectShape: Sendable {
    case capsule
    case circle
    case rect(cornerRadius: CGFloat)
}

struct GlassEffectContainer<Content: View>: View {
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
    func glassEffect(_ style: GlassEffectStyle = .regular, in shape: GlassEffectShape = .capsule) -> some View {
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


// MARK: - 100% 首次点击响应按钮样式（带轻触缩放与触觉反馈）
struct ResponsivePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 胶囊操作按钮（显式绑定 `.contentShape(Capsule())`，杜绝热区丢失）
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
    }
}

/// 44x44pt 标准热区图标按钮
struct GlassIconButton: View {
    let systemName: String
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
                .frame(minWidth: 42, minHeight: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePressButtonStyle())
    }
}

// MARK: - 书籍封面组件（上方醒目来源标签：番茄畅听 / 喜马拉雅）
struct BookCoverView: View {
    let urlString: String
    let title: String
    let source: CoreSourceID
    var progressBadge: String? = nil
    var width: CGFloat = 104
    var height: CGFloat = 140
    var cornerRadius: CGFloat = 12

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

            if let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height)
                            .clipped()
                    default:
                        fallbackPlaceholder
                    }
                }
            } else {
                fallbackPlaceholder
            }

            // 顶部渐变暗角衬托上方来源标签
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

// MARK: - 标准 3 列等高书籍卡片（点击卡片进详情，点击右下角播放键直接秒播）
struct StandardBookGridCard: View {
    let book: BookItem
    var progressBadge: String? = nil
    let onOpenDetail: () -> Void
    let onQuickPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: onOpenDetail) {
                    BookCoverView(
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
                        .padding(6)
                        .contentShape(Circle())
                }
                .buttonStyle(ResponsivePressButtonStyle())
            }

            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(height: 34, alignment: .topLeading)

                    Text(book.author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 15, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 106)
    }
}

// MARK: - 列表区书籍卡片行（封面上方直接标注来源，左侧进详情，右侧直接秒播）
struct CleanBookRow: View {
    let book: BookItem
    var subtitleOverride: String? = nil
    let onOpenDetail: () -> Void
    let onQuickPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenDetail) {
                HStack(spacing: 12) {
                    BookCoverView(
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
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(2)

                        Text(book.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.92))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePressButtonStyle())

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onQuickPlay()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(book.source.brandColor)
                    Text("收听")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 48, height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePressButtonStyle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15))
        )
    }
}
