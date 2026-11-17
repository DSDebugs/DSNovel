import SwiftUI

struct SearchHistoryChips: View {
    let histories: [SearchHistory]
    private let onTapKeyword: (String) -> Void
    private let onDeleteKeyword: (SearchHistory) -> Void
    private let onClearAll: () -> Void

    init(
        histories: [SearchHistory],
        onTapKeyword: @escaping (String) -> Void,
        onDeleteKeyword: @escaping (SearchHistory) -> Void,
        onClearAll: @escaping () -> Void
    ) {
        self.histories = histories
        self.onTapKeyword = onTapKeyword
        self.onDeleteKeyword = onDeleteKeyword
        self.onClearAll = onClearAll
    }

    var body: some View {
        if !histories.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s3) {
                DSSectionHeader(
                    title: "搜索历史",
                    actionTitle: "清空",
                    onAction: onClearAll
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s2) {
                        ForEach(histories.prefix(10), id: \.keyword) { item in
                            HStack(spacing: Spacing.s1) {
                                Button(item.keyword) {
                                    onTapKeyword(item.keyword)
                                }
                                .font(DSTypography.subtitle)
                                .foregroundStyle(.primary)

                                Button {
                                    onDeleteKeyword(item)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, Spacing.s3)
                            .padding(.vertical, Spacing.s2)
                            .background(Capsule().fill(Color.dsSurfaceGrouped))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.pageHorizontal)
                }
            }
        }
    }
}
