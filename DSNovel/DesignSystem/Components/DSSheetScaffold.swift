import SwiftUI

struct DSSheetScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    private let onClose: (() -> Void)?
    private let content: Content
    @State private var bannerCenter = BannerCenter.shared

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
        ZStack(alignment: .top) {
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if let subtitle, !subtitle.isEmpty {
                            ToolbarItem(placement: .principal) {
                                VStack(spacing: 1) {
                                    Text(title)
                                        .font(DSTypography.cardTitle.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(subtitle)
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        if let onClose {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成", action: onClose)
                            }
                        }
                    }
            }

            if let banner = bannerCenter.currentBanner {
                DSBanner(
                    item: banner,
                    onUndo: { bannerCenter.triggerUndo() },
                    onDismiss: { bannerCenter.dismissCurrent() }
                )
                .padding(.top, Spacing.s2)
                .zIndex(20)
            }
        }
    }
}

#Preview("Light") {
    DSSheetScaffold(title: "倍速调节", subtitle: "支持 0.5x - 3.0x", onClose: {}) {
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
