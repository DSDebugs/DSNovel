import SwiftUI

/// 数据库初始化失败时的安全降级页（T0-04 / D-3：仅含「重试」与「备份并重建」两个按钮，不含导出备份入口）
struct DataRepairView: View {
    let errorDescription: String
    let onRetry: () -> Void
    let onBackupAndRebuild: () -> Void

    @State private var showRebuildConfirm = false

    init(
        errorDescription: String,
        onRetry: @escaping () -> Void,
        onBackupAndRebuild: @escaping () -> Void
    ) {
        self.errorDescription = errorDescription
        self.onRetry = onRetry
        self.onBackupAndRebuild = onBackupAndRebuild
    }

    var body: some View {
        VStack(spacing: Spacing.s5) {
            Spacer()

            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Color.dsAccent)

            Text("本地数据库未能正常打开")
                .font(DSTypography.sectionTitle)

            Text("可先尝试重新加载；若多次失败，可将旧数据库自动备份至应用目录后重建空库。")
                .font(DSTypography.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.s6)

            DisclosureGroup("详情") {
                Text(errorDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.s2)
            }
            .padding(.horizontal, Spacing.s6)

            VStack(spacing: Spacing.s3) {
                DSActionButton(
                    title: "重试",
                    icon: "arrow.clockwise",
                    role: .primary,
                    action: onRetry
                )
                .accessibilityIdentifier("data_repair_retry_button")

                DSActionButton(
                    title: "备份并重建",
                    icon: "externaldrive.badge.plus",
                    role: .destructive
                ) {
                    showRebuildConfirm = true
                }
                .accessibilityIdentifier("data_repair_rebuild_button")
            }
            .padding(.horizontal, Spacing.s6)

            Spacer()
        }
        .padding(Spacing.pageHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsSurfaceBase)
        .alert("确认备份并重建数据库？", isPresented: $showRebuildConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认备份并重建", role: .destructive) {
                onBackupAndRebuild()
            }
        } message: {
            Text("旧数据库文件会自动备份至应用目录，随后将清空当前损坏数据库并重建空库。")
        }
    }
}
