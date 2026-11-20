import SwiftUI

struct StoragePrefsView: View {
    @Bindable var settings: AppSettingsStore
    let manualBytes: Int64
    private let onOpenDownloads: () -> Void

    init(
        settings: AppSettingsStore = .shared,
        manualBytes: Int64,
        onOpenDownloads: @escaping () -> Void
    ) {
        self.settings = settings
        self.manualBytes = manualBytes
        self.onOpenDownloads = onOpenDownloads
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    var body: some View {
        Group {
            HStack(spacing: Spacing.s3) {
                Image(systemName: "wifi")
                    .font(DSTypography.subtitle.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                            .fill(Color.dsAccent.opacity(0.10))
                    )
                    .accessibilityHidden(true)

                Toggle("仅在 Wi-Fi 下下载", isOn: $settings.wifiOnlyDownload)
                    .tint(Color.dsAccent)
                    .onChange(of: settings.wifiOnlyDownload) { _, newValue in
                        Task { await DownloadManager.shared.handleWiFiOnlySettingChanged(newValue) }
                    }
            }
            .frame(minHeight: 44)
            .listRowBackground(Color.dsSurfaceCard)

            Button(action: onOpenDownloads) {
                DSSettingsRow(
                    icon: "arrow.down.circle",
                    title: "下载管理",
                    valueText: "已下载 \(formatBytes(manualBytes))",
                    style: .navigation
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.dsSurfaceCard)
        }
    }
}
