import SwiftUI

enum DSRailSize: CGFloat {
    case compact = 96
    case regular = 132
}

struct DSRail: View {
    let items: [BookCardModel]
    let size: DSRailSize
    private let onSelect: (BookCardModel) -> Void

    init(
        items: [BookCardModel],
        size: DSRailSize = .compact,
        onSelect: @escaping (BookCardModel) -> Void = { _ in }
    ) {
        self.items = items
        self.size = size
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Spacing.gridColumnSpacing) {
                ForEach(items) { item in
                    DSBookCard(
                        model: item,
                        side: size.rawValue,
                        onAction: { onSelect(item) }
                    )
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Spacing.pageHorizontal)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

#Preview("Light") {
    DSRail(items: [
        BookCardModel(id: "1", title: "茶花女", author: "白云出岫"),
        BookCardModel(id: "2", title: "道德经", author: "国学")
    ])
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    DSRail(items: [
        BookCardModel(id: "1", title: "全唐诗", author: "李白")
    ], size: .regular)
    .preferredColorScheme(.dark)
}

#Preview("AX") {
    DSRail(items: [
        BookCardModel(id: "1", title: "儒林外史", author: "吴敬梓")
    ])
    .environment(\.sizeCategory, .accessibilityExtraExtraLarge)
}
