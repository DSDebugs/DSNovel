import DSCore
import DSDesignSystem
import DSStorage
import SwiftUI

/// 数据库异常修复与备份一键还原页（L-IOS-4：绝不 fatalError 闪退，引导用户从最近 5 份 WAL 备份还原）
struct DataRepairView: View {
    @Environment(AppContainer.self) private var container
    @State private var backups: [StoreBackupInfo] = []
    @State private var statusMessage: String?
    @State private var showResetAlert = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("存储状态异常") {
                    Text(container.storageResult.startupErrorDescription ?? "本地数据库无法打开，已切换为临时只读保护模式。")
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }

                Section("可用一致性备份（最近 5 份）") {
                    if backups.isEmpty {
                        Text("暂无历史备份快照")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    } else {
                        ForEach(backups) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                                    Text(item.id)
                                        .font(DSTypography.subheadline)
                                    Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                                        .font(DSTypography.caption)
                                        .foregroundStyle(DSColors.inkSecondary)
                                }
                                Spacer()
                                Button("还原") {
                                    Task { await restore(item) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorking)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }

                Section("无备份应急方案") {
                    Button("归档损坏库并重建空白数据库", role: .destructive) {
                        showResetAlert = true
                    }
                    .disabled(isWorking)
                    .frame(minHeight: 44)
                }

                if let msg = statusMessage {
                    Section("处理结果") {
                        Text(msg)
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.accent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceBase)
            .navigationTitle("数据修复")
            .navigationBarTitleDisplayMode(.inline)
            .alert("确认重置并重建空库", isPresented: $showResetAlert) {
                Button("取消", role: .cancel) {}
                Button("确认重建", role: .destructive) {
                    Task { await resetCorruptedStore() }
                }
            } message: {
                Text("损坏的旧库将自动归档至 .corrupted 目录保留，主库将被清空。重启应用后即可正常进入。")
            }
            .task {
                backups = await container.backupManager.listBackups()
            }
        }
    }

    private func restore(_ item: StoreBackupInfo) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await container.backupManager.restoreBackup(item)
            container.settings.bundledSourcesSeededVersion = ""
            backups = await container.backupManager.listBackups()
            statusMessage = "已成功还原备份 \(item.id)，请重新启动应用生效。"
        } catch {
            statusMessage = "还原失败：\(error.localizedDescription)"
        }
    }

    private func resetCorruptedStore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await container.backupManager.archiveCorruptedAndResetStore()
            container.settings.bundledSourcesSeededVersion = ""
            backups = await container.backupManager.listBackups()
            statusMessage = "已归档损坏库并重置主库，请彻底关闭并重新启动应用。"
        } catch {
            statusMessage = "重置失败：\(error.localizedDescription)"
        }
    }
}
