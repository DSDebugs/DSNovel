import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    let hasSeededSource: Bool
    private let onUseBuiltIn: () -> Void
    private let onImportOwn: () -> Void

    init(
        hasSeededSource: Bool,
        onUseBuiltIn: @escaping () -> Void,
        onImportOwn: @escaping () -> Void
    ) {
        self.hasSeededSource = hasSeededSource
        self.onUseBuiltIn = onUseBuiltIn
        self.onImportOwn = onImportOwn
    }

    var body: some View {
        VStack(spacing: Spacing.s6) {
            Spacer()

            Image(systemName: "books.vertical.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Color.dsAccent)

            VStack(spacing: Spacing.s2) {
                Text("欢迎使用 DSNovel")
                    .font(DSTypography.bookTitleLarge)
                Text("DSNovel 通过书源播放有声书，首次启动已内置 1 个书源")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Spacing.s3) {
                DSActionButton(
                    title: hasSeededSource ? "使用内置书源（已就绪）" : "使用内置书源",
                    icon: "checkmark.circle.fill",
                    role: .primary,
                    action: onUseBuiltIn
                )

                DSActionButton(
                    title: "导入我自己的书源",
                    icon: "plus.circle",
                    role: .secondary,
                    action: onImportOwn
                )
            }
            .padding(.horizontal, Spacing.pageHorizontal)

            Spacer()
        }
        .padding(Spacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsSurfaceBase)
    }
}
