import SwiftUI

struct SourceHealthCard: View {
    let summary: SourceHealthSummary
    let isChecking: Bool
    private let onOpenSourceList: () -> Void
    private let onCheckAll: () -> Void
    private let onHandleAttention: () -> Void
    private let onImportSource: () -> Void

    init(
        summary: SourceHealthSummary,
        isChecking: Bool,
        onOpenSourceList: @escaping () -> Void,
        onCheckAll: @escaping () -> Void,
        onHandleAttention: @escaping () -> Void,
        onImportSource: @escaping () -> Void
    ) {
        self.summary = summary
        self.isChecking = isChecking
        self.onOpenSourceList = onOpenSourceList
        self.onCheckAll = onCheckAll
        self.onHandleAttention = onHandleAttention
        self.onImportSource = onImportSource
    }

    var body: some View {
        if summary.totalCount == 0 {
            VStack(alignment: .leading, spacing: Spacing.s3) {
                Text("导入书源后才能搜索与播放")
                    .font(DSTypography.rowTitle)
                    .foregroundStyle(.primary)
                DSActionButton(
                    title: "导入书源",
                    icon: "plus.circle.fill",
                    role: .primary,
                    action: onImportSource
                )
            }
            .padding(Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous)
                    .fill(Color.dsSurfaceCard)
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onOpenSourceList) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(summary.availableCount) / \(summary.enabledCount) 可用")
                                .font(DSTypography.sectionHeader.monospacedDigit())
                                .foregroundStyle(.primary)
                                .contentTransition(.numericText())
                            Text("\(summary.needAuthCount) 个需登录 · \(summary.unavailableCount) 个异常")
                                .font(DSTypography.numericFootnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: onCheckAll) {
                        if isChecking {
                            ProgressView()
                                .frame(width: 44, height: 44)
                        } else {
                            Text("检测全部")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(Color.dsAccent)
                                .padding(.horizontal, Spacing.s3)
                                .padding(.vertical, Spacing.s2)
                                .background(Capsule().fill(Color.dsSurfaceGrouped))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)
                }
                .padding(Spacing.s4)

                if summary.needAuthCount + summary.unavailableCount > 0 {
                    Divider()
                    Button(action: onHandleAttention) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("存在需处理的书源")
                                .font(DSTypography.caption.weight(.medium))
                                .foregroundStyle(.orange)
                            Spacer()
                            Text("去处理 ›")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, Spacing.s4)
                        .padding(.vertical, Spacing.s3)
                        .background(Color.orange.opacity(0.10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: Radius.heroCard, style: .continuous)
                    .fill(Color.dsSurfaceCard)
            )
        }
    }
}
