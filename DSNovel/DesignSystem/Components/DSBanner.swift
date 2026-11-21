import SwiftUI

struct DSBanner: View {
    let item: DSBannerItem
    private let onUndo: (() -> Void)?
    private let onDismiss: () -> Void

    init(
        item: DSBannerItem,
        onUndo: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.item = item
        self.onUndo = onUndo
        self.onDismiss = onDismiss
    }

    private var iconColor: Color {
        switch item.kind {
        case .info: return Color.dsAccent
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .undo: return Color.dsAccent
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: item.kind.iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(iconColor)

            Text(item.message)
                .font(DSTypography.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)

            if item.kind == .undo, let onUndo {
                Button("撤销", action: onUndo)
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(Color.dsAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            } else if item.kind == .error {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.vertical, Spacing.s2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Spacing.pageHorizontal)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -12 {
                        onDismiss()
                    }
                }
        )
    }
}

#Preview("Light") {
    DSBanner(item: DSBannerItem(message: "已移出书架", kind: .undo), onUndo: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSBanner(item: DSBannerItem(message: "书源连接超时，请稍后重试", kind: .error))
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSBanner(item: DSBannerItem(message: "已加入书架", kind: .success))
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
