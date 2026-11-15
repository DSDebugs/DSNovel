import SwiftUI

/// 控制层专用玻璃容器：同一区域的多个控制元素必须放入同一个 GlassEffectContainer，避免多层采样。
/// 严格遵循「控制层玻璃、内容层干净」与「降低透明度」无障碍回退规范。
struct GlassEffectContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let cornerRadius: CGFloat
    private let content: Content

    init(cornerRadius: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                        )
                }
            }
    }
}

/// 控制层玻璃按钮（仅限导航栏/工具栏、播放主控、书架多选悬浮条使用）
struct GlassButton<Label: View>: View {
    let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 书架编辑模式底部唯一玻璃悬浮操作栏
struct GlassFloatingBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(cornerRadius: 24) {
            HStack(spacing: DSSpacing.xl) {
                content
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.vertical, DSSpacing.md)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.bottom, DSSpacing.sm)
    }
}

extension View {
    /// 列表与滚动区边缘柔和衔接修饰器
    func dsSoftScrollEdge() -> some View {
        self
    }
}
