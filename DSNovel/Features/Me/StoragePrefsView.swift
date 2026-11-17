import SwiftUI

struct StoragePrefsView: View {
    @Bindable var settings: AppSettingsStore
    let manualBytes: Int64
    let tempBytes: Int64
    private let onOpenDownloads: () -> Void
    private let onClearTempCache: () -> Void

    init(
        settings: AppSettingsStore = .shared,
        manualBytes: Int64,
        tempBytes: Int64,
        onOpenDownloads: @escaping () -> Void,
        onClearTempCache: @escaping () -> Void
    ) {
        self.settings = settings
        self.manualBytes = manualBytes
        self.tempBytes = tempBytes
        self.onOpenDownloads = onOpenDownloads
        self.onClearTempCache = onClearTempCache
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        Group {
            Toggle("仅在 Wi-Fi 下下载", isOn: $settings.wifiOnlyDownload)
                .onChange(of: settings.wifiOnlyDownload) { _, newValue in
                    Task { await DownloadManager.shared.handleWiFiOnlySettingChanged(newValue) }
                }

            Button(action: onOpenDownloads) {
                DSSettingsRow(
                    icon: "arrow.down.circle",
                    title: "下载管理",
                    valueText: "已下载 \(formatBytes(manualBytes))"
                )
            }
            .buttonStyle(.plain)

            Button(action: onClearTempCache) {
                DSSettingsRow(
                    icon: "trash.circle",
                    title: "清理预缓存与封面缓存",
                    valueText: formatBytes(tempBytes)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
