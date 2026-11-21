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
                            HStack(spacing: 0) {
                                Button {
                                    onTapKeyword(item.keyword)
                                } label: {
                                    Text(item.keyword)
                                        .font(DSTypography.subtitle)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 200)
                                        .padding(.leading, Spacing.s3)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }

                                Button {
                                    onDeleteKeyword(item)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("删除搜索历史 \(item.keyword)")
                            }
                            .frame(minHeight: 44)
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
