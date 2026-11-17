import SwiftUI

struct DSSheetScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    private let onClose: (() -> Void)?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成", action: onClose)
                        }
                    }
                }
        }
    }
}

#Preview("Light") {
    DSSheetScaffold(title: "倍速调节", onClose: {}) {
        Text("0.5x - 3.0x")
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSSheetScaffold(title: "睡眠定时", onClose: {}) {
        Text("本章结束")
    }
    .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSSheetScaffold(title: "切换书源", onClose: {}) {
        Text("书源列表")
    }
    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
