import DSDesignSystem
import SwiftUI

/// 搜索历史横向紧致胶囊芯片条（支持单条 × 删除与全部清空）
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
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack {
                    Text("搜索历史")
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer()
                    Button(action: onClearAll) {
                        Text("清空")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                            .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索历史")
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpacing.xs) {
                        ForEach(Array(histories.prefix(12)), id: \.self) { keyword in
                            HStack(spacing: 2) {
                                Button {
                                    onTapKeyword(keyword)
                                } label: {
                                    Text(keyword)
                                        .font(DSTypography.caption)
                                        .foregroundStyle(DSColors.inkPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 168)
                                        .padding(.leading, DSSpacing.sm)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                }

                                Button {
                                    onDeleteKeyword(keyword)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(DSTypography.caption2.weight(.medium))
                                        .foregroundStyle(DSColors.inkSecondary)
                                        .frame(width: 28, height: 30)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("删除搜索历史 \(keyword)")
                            }
                            .background(Capsule().fill(DSColors.surfaceCard))
                            .overlay(Capsule().strokeBorder(DSColors.separator.opacity(0.25), lineWidth: 0.5))
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
