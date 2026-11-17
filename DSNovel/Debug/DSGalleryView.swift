#if DEBUG
import SwiftUI

struct DSGalleryView: View {
    @State private var selectedChip: String = "all"

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sectionVertical) {
                DSSectionHeader(title: "设计系统组件画廊", subtitle: "18 组件")

                DSChipBar(
                    items: [
                        DSChipItem(id: "all", title: "全部", count: 18),
                        DSChipItem(id: "cards", title: "卡片"),
                        DSChipItem(id: "states", title: "状态")
                    ],
                    selection: $selectedChip
                )

                DSContinueCard(
                    model: BookCardModel(
                        id: "demo",
                        title: "诡秘之主",
                        author: "爱潜水的乌贼",
                        progressFraction: 0.45,
                        lastChapterIndex: 102,
                        totalChapters: 2059,
                        progressSubtitle: "第 102/2059 章 · 02:45",
                        isPlaying: true
                    )
                )
                .padding(.horizontal, Spacing.pageHorizontal)

                DSRail(items: [
                    BookCardModel(id: "1", title: "道德经", author: "老子", isDownloaded: true),
                    BookCardModel(id: "2", title: "茶花女", author: "小仲马", hasUpdate: true),
                    BookCardModel(id: "3", title: "全唐诗", author: "李白", isVIP: true)
                ])

                DSStateView(kind: .empty, onPrimary: {}, onSecondary: {})
            }
            .padding(.vertical, Spacing.s4)
        }
        .background(Color.dsSurfaceBase)
        .navigationTitle("DSGallery")
    }
}
#endif
