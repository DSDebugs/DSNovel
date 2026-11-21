import DSDesignSystem
import DSDownloads
import DSStorage
import SwiftUI

/// 「我的」根视图（纯竖屏设置与诊断中心）
struct MeRootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        List {
            Section("内容与管理") {
                navRow(icon: "arrow.down.circle", title: "下载管理", detail: ByteCountFormatter.string(fromByteCount: downloads.totalDiskBytes, countStyle: .file)) {
                    router.push(.downloads)
                }
                navRow(icon: "globe", title: "书源管理", detail: "导入与分组") {
                    router.push(.sources)
                }
                if settings.builtinParserUnlocked {
                    navRow(icon: "cpu", title: "内置音频解析器", detail: "独立管理") {
                        router.push(.builtinParser)
                    }
                }
            }

            Section("偏好设置") {
                navRow(icon: "paintbrush", title: "外观与夜间降亮", detail: "") {
                    router.push(.appearancePrefs)
                }
                navRow(icon: "waveform", title: "播放与音质偏好", detail: "") {
                    router.push(.playbackPrefs)
                }
                navRow(icon: "externaldrive", title: "存储、备份与还原", detail: "") {
                    router.push(.storagePrefs)
                }
            }

            Section("支持与信息") {
                navRow(icon: "stethoscope", title: "脱敏诊断日志", detail: "") {
                    router.push(.diagnostics)
                }
                navRow(icon: "info.circle", title: "关于 DSNovel", detail: AuthorInfo.appVersionDisplay) {
                    router.push(.about)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("me_root")
        .background(DSColors.surfaceBase)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func navRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(DSColors.inkPrimary)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(DSTypography.footnote)
                        .foregroundStyle(DSColors.inkSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}
