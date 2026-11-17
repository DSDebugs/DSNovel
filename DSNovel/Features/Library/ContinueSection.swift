import SwiftUI

struct ContinueSection: View {
    let continueModel: BookCardModel
    let recentModels: [BookCardModel]
    private let onOpenBook: (String) -> Void
    private let onTogglePlay: () -> Void
    private let onOpenHistory: () -> Void

    init(
        continueModel: BookCardModel,
        recentModels: [BookCardModel],
        onOpenBook: @escaping (String) -> Void,
        onTogglePlay: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.continueModel = continueModel
        self.recentModels = recentModels
        self.onOpenBook = onOpenBook
        self.onTogglePlay = onTogglePlay
        self.onOpenHistory = onOpenHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            DSContinueCard(
                model: continueModel,
                onOpenDetail: { onOpenBook(continueModel.id) },
                onTogglePlay: onTogglePlay
            )
            .padding(.horizontal, Spacing.pageHorizontal)

            if !recentModels.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    DSSectionHeader(
                        title: "最近在听",
                        subtitle: "\(recentModels.count) 本",
                        actionTitle: "全部历史 ›",
                        onAction: onOpenHistory
                    )
                    DSRail(
                        items: recentModels,
                        size: .compact,
                        onSelect: { item in onOpenBook(item.id) }
                    )
                }
            }
        }
    }
}
