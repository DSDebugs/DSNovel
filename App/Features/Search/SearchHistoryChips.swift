import DSDesignSystem
import SwiftUI

/// 搜索历史横向胶囊芯片条（1:1 复刻 v2.8 SearchHistoryChips：支持单条 × 删除与全部清空）
struct SearchHistoryChips: View {
    let histories: [String]
    private let onTapKeyword: (String) -> Void
    private let onDeleteKeyword: (String) -> Void
    private let onClearAll: () -> Void

    init(
        histories: [String],
        onTapKeyword: @escaping (String) -> Void,
        onDeleteKeyword: @escaping (String) -> Void,
        onClearAll: @escaping () -> Void
    ) {
        self.histories = histories
        self.onTapKeyword = onTapKeyword
        self.onDeleteKeyword = onDeleteKeyword
        self.onClearAll = onClearAll
    }

    var body: some View {
        if !histories.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                DSSectionHeader(
                    title: "搜索历史",
                    actionTitle: "清空",
                    onAction: onClearAll
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpacing.xs) {
                        ForEach(Array(histories.prefix(12)), id: \.self) { keyword in
                            HStack(spacing: 0) {
                                Button {
                                    onTapKeyword(keyword)
                                } label: {
                                    Text(keyword)
                                        .font(DSTypography.subtitle)
                                        .foregroundStyle(DSColors.inkPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 200)
                                        .padding(.leading, DSSpacing.sm)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }

                                Button {
                                    onDeleteKeyword(keyword)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("删除搜索历史 \(keyword)")
                            }
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceGrouped))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                }
                .contentMargins(.bottom, 0, for: .scrollContent)
            }
        }
    }
}
