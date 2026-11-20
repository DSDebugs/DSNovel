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
                HStack(spacing: Spacing.s3) {
                    Button(action: onOpenSourceList) {
                        HStack(spacing: Spacing.s2) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(summary.availableCount) / \(summary.enabledCount) 可用")
                                    .font(DSTypography.sectionHeader.monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .contentTransition(.numericText())
                                Text("\(summary.needAuthCount) 个需登录（可选） · \(summary.unavailableCount) 个异常")
                                    .font(DSTypography.numericFootnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("书源状态：\(summary.availableCount) 个可用，共 \(summary.enabledCount) 个已启用，点击管理书源")

                    Button(action: onCheckAll) {
                        HStack(spacing: 6) {
                            if isChecking {
                                ProgressView()
                                    .controlSize(.small)
                                Text("检测中")
                            } else {
                                Text("检测全部")
                            }
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(isChecking ? .secondary : Color.dsAccent)
                        .padding(.horizontal, Spacing.s3)
                        .frame(minWidth: 86, minHeight: 44)
                        .background(Capsule().fill(Color.dsSurfaceGrouped))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)
                    .accessibilityLabel(isChecking ? "正在检测全部书源" : "检测全部书源")
                }
                .padding(Spacing.s4)

                if summary.needAuthCount + summary.unavailableCount > 0 {
                    Divider()
                    Button(action: onHandleAttention) {
                        HStack {
                            Image(systemName: summary.unavailableCount > 0 ? "exclamationmark.triangle.fill" : "person.badge.key")
                                .foregroundStyle(summary.unavailableCount > 0 ? .red : .orange)
                            Text(summary.unavailableCount > 0 ? "存在异常书源" : "存在需登录书源")
                                .font(DSTypography.caption.weight(.medium))
                                .foregroundStyle(summary.unavailableCount > 0 ? .red : .orange)
                            Spacer()
                            Text("去处理 ›")
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(summary.unavailableCount > 0 ? .red : .orange)
                        }
                        .padding(.horizontal, Spacing.s4)
                        .padding(.vertical, Spacing.s3)
                        .background((summary.unavailableCount > 0 ? Color.red : Color.orange).opacity(0.10))
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
