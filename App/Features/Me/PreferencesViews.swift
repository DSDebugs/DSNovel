import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 应用作者与动态版本信息
enum AuthorInfo {
    static let name = "DS"
    static let role = "设计与开发"
    static let copyrightText = "© 2026 DS"

    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.3.9"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static var appVersionDisplay: String {
        shortVersion
    }
}

/// 播放偏好页（规则 #17：严禁提供全局跳过片头片尾；默认音质严格在喜马拉雅可用时显示）
struct PlaybackPrefsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        @Bindable var bindable = settings
        Form {
            Section("连续播放") {
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
