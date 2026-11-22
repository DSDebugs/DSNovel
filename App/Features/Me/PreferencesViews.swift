import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI
import UIKit

/// 应用作者与动态版本信息
enum AuthorInfo {
    static let name = "DS"
    static let role = "设计与开发"
    static let copyrightText = "© 2026 DS"

    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.0.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static var appVersionDisplay: String {
        "v\(shortVersion) (\(buildNumber))"
    }
}

/// 外观设置页（兼容现有路由，浅色外观下自动禁用夜间降亮并提示）
struct AppearancePrefsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettingsStore.self) private var settings

    private var isEffectiveDarkAppearance: Bool {
        switch settings.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    var body: some View {
        @Bindable var bindable = settings
        Form {
            Section("外观模式") {
                Picker("主题", selection: $bindable.themeMode) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(DSColors.surfaceCard)
            }
            Section {
                Toggle("夜间降亮遮罩", isOn: $bindable.nightDimEnabled)
                    .tint(DSColors.accent)
                    .disabled(!isEffectiveDarkAppearance)
                    .listRowBackground(DSColors.surfaceCard)
            } header: {
                Text("夜间护眼")
            } footer: {
                if !isEffectiveDarkAppearance {
                    Text("夜间降亮遮罩仅在深色外观下生效，切换至深色主题后可开启。")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("外观设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 播放偏好页（规则 #17：严禁提供全局跳过片头片尾；默认音质严格仅在 isDiscoverSourceXimalaya 时显示）
struct PlaybackPrefsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        @Bindable var bindable = settings
        Form {
            Section("音质与连播") {
                if container.isDiscoverSourceXimalaya {
                    Picker("默认播放音质", selection: $bindable.preferredQuality) {
                        ForEach(AudioQualityTier.availableTiers(builtinParserUnlocked: container.canUseUltraHighQuality)) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                    .onChange(of: settings.preferredQuality) { _, _ in
                        container.syncSettingsToEngines()
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }
                Toggle("播完自动连播下一章", isOn: $bindable.autoPlayNextChapter)
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)
            }
            Section("下载策略") {
                Toggle("仅在 Wi-Fi 下自动下载", isOn: $bindable.wifiOnlyDownload)
                    .tint(DSColors.accent)
                    .listRowBackground(DSColors.surfaceCard)
                Stepper("同时下载任务数：\(settings.maxConcurrentDownloads)", value: $bindable.maxConcurrentDownloads, in: 1...6)
                    .listRowBackground(DSColors.surfaceCard)
                Stepper("自动预缓存后续章数：\(settings.precacheNextCount)", value: $bindable.precacheNextCount, in: 0...5)
                    .listRowBackground(DSColors.surfaceCard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("播放偏好")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.autoPlayNextChapter) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.wifiOnlyDownload) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.maxConcurrentDownloads) { _, _ in container.syncSettingsToEngines() }
        .onChange(of: settings.precacheNextCount) { _, _ in container.syncSettingsToEngines() }
    }
}

/// 存储、WAL 备份与 JSON 书架导出页
struct StoragePrefsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var backups: [StoreBackupInfo] = []
    @State private var pendingImportPayload: LibraryBackupPayload?
    @State private var isCreatingBackup = false

    var body: some View {
        List {
            Section("缓存清理") {
                Button("清理封面图片缓存") {
                    Task {
                        await container.coverPipeline.clearAll()
                        banner.show("已清理封面缓存", tone: .success)
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)

                Button("清理章节目录缓存") {
                    Task {
                        await container.chapterCache.clearAll()
                        banner.show("已清理章节目录缓存", tone: .success)
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)
            }

            Section("数据库一致性备份（WAL Checkpoint，保留 5 份）") {
                Button(isCreatingBackup ? "正在创建备份..." : "立即创建数据库备份") {
                    guard !isCreatingBackup else { return }
                    isCreatingBackup = true
                    Task {
                        defer { isCreatingBackup = false }
                        do {
                            _ = try await container.backupManager.createBackup()
                            backups = await container.backupManager.listBackups()
                            banner.show("数据库快照已创建", tone: .success)
                        } catch {
                            banner.show("创建数据库备份失败：\(error.localizedDescription)", tone: .error)
                        }
                    }
                }
                .disabled(isCreatingBackup)
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)

                ForEach(backups) { b in
                    HStack {
                        Text(b.id)
                            .font(DSTypography.caption)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: b.sizeBytes, countStyle: .file))
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }
            }

            Section("版本化 JSON 书架与进度备份") {
                Button("生成 JSON 备份并复制到剪贴板") {
                    Task {
                        do {
                            let payload = try await container.persistence.exportLibraryBackup(appVersion: AuthorInfo.shortVersion)
                            let data = try LibraryBackupCodec.encode(payload)
                            guard let text = String(data: data, encoding: .utf8) else {
                                banner.show("导出书架备份失败：UTF-8 编码异常", tone: .error)
                                return
                            }
                            UIPasteboard.general.string = text
                            banner.show("已导出 \(payload.books.count) 本书并复制 JSON", tone: .success)
                        } catch {
                            banner.show("导出书架备份失败：\(error.localizedDescription)", tone: .error)
                        }
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)

                Button("从剪贴板还原 JSON 书架备份") {
                    guard let raw = UIPasteboard.general.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        banner.show("剪贴板为空或未授予粘贴权限，请先复制备份 JSON", tone: .warning)
                        return
                    }
                    guard raw.utf8.count <= 8 * 1024 * 1024 else {
                        banner.show("剪贴板备份体积超过 8 MB 上限，无法直接导入", tone: .error)
                        return
                    }
                    Task {
                        let decoded = await Task.detached(priority: .userInitiated) { () -> LibraryBackupPayload? in
                            guard let data = raw.data(using: .utf8) else { return nil }
                            return try? LibraryBackupCodec.decode(data)
                        }.value
                        guard let decoded else {
                            banner.show("剪贴板内容不是有效的 DSNovel JSON 备份格式", tone: .error)
                            return
                        }
                        pendingImportPayload = decoded
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("存储与备份")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认导入书架备份", isPresented: Binding(
            get: { pendingImportPayload != nil },
            set: { if !$0 { pendingImportPayload = nil } }
        )) {
            Button("取消", role: .cancel) { pendingImportPayload = nil }
            Button("确认导入") {
                if let payload = pendingImportPayload {
                    Task {
                        do {
                            let count = try await container.persistence.importLibraryBackup(payload)
                            container.notifyLibraryChanged()
                            banner.show("已还原 \(count) 本书架与进度记录", tone: .success)
                        } catch {
                            banner.show("导入书架备份失败：\(error.localizedDescription)", tone: .error)
                        }
                    }
                }
                pendingImportPayload = nil
            }
        } message: {
            Text("检测到 \(pendingImportPayload?.books.count ?? 0) 本书的备份记录，将合并写入当前书架与进度。")
        }
        .task {
            backups = await container.backupManager.listBackups()
        }
    }
}

/// 脱敏诊断日志视图
struct DiagnosticsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var entries: [DSDiagnosticEntry] = []

    var body: some View {
        List {
            Section {
                Button("复制脱敏诊断报告") {
                    Task {
                        let report = await container.logger.exportSanitizedReport(appVersion: AuthorInfo.appVersionDisplay)
                        UIPasteboard.general.string = report
                        banner.show("已复制脱敏诊断报告（已擦除 Cookie 与 Token）", tone: .success)
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(DSColors.surfaceCard)
            }

            Section("最近日志（\(entries.count)）") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("[\(entry.level)] [\(entry.category.rawValue)]")
                            .font(DSTypography.monoCaption)
                            .foregroundStyle(DSColors.accent)
                        Text(entry.message)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColors.surfaceGrouped)
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = await container.logger.snapshot(limit: 120)
        }
    }
}
