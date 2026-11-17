import SwiftUI

struct DSIconButton: View {
    let systemName: String
    let accessibilityTitle: String
    let isHighlighted: Bool
    private let action: () -> Void

    init(
        systemName: String,
        accessibilityTitle: String,
        isHighlighted: Bool = false,
        action: @escaping () -> Void = {}
    ) {
        self.systemName = systemName
        self.accessibilityTitle = accessibilityTitle
        self.isHighlighted = isHighlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(isHighlighted ? Color.dsAccent : .primary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.dsSurfaceGrouped)
                )
        }
        .buttonStyle(.dsCard)
        .accessibilityLabel(accessibilityTitle)
    }
}

#Preview("Light") {
    DSIconButton(systemName: "heart.fill", accessibilityTitle: "已加入书架", isHighlighted: true)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSIconButton(systemName: "arrow.down.circle", accessibilityTitle: "下载")
        .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSIconButton(systemName: "ellipsis", accessibilityTitle: "更多")
        .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
