import SwiftUI

/// 数据库初始化失败时的安全降级页（T0-04 / D-3：仅含「重试」与「备份并重建」两个按钮，不含导出备份入口）
struct DataRepairView: View {
    let errorDescription: String
    let onRetry: () -> Void
    let onBackupAndRebuild: () -> Void

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
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.orange)

            Text("本地数据库未能正常打开")
                .font(.headline)

            Text("可先尝试重新加载；若多次失败，可将旧数据库自动备份至应用目录后重建空库。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            DisclosureGroup("详情") {
                Text(errorDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("重试")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("data_repair_retry_button")

                Button(role: .destructive, action: onBackupAndRebuild) {
                    Text("备份并重建")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("data_repair_rebuild_button")
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .padding()
    }
}
