import AVKit
import DSDesignSystem
import DSPlayback
import SwiftUI
import UIKit

/// AirPlay 音频输出路由选择器包装
struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = UIColor(DSColors.accent)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .white
        uiView.activeTintColor = UIColor(DSColors.accent)
    }
}

/// 弹窗 8：更多播放设置（1:1 复刻 v2.8：音质音效、批量下载、跳过片头片尾摘要、查看书籍详情、复制章节标题）
struct MoreSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner

    let supportsQualitySelection: Bool
    private let onOpenAudioEffects: () -> Void
    private let onOpenQuality: () -> Void
    private let onOpenDownloads: () -> Void
    private let onOpenSkip: () -> Void
    private let onOpenBookDetail: () -> Void
    private let onDismiss: () -> Void

    init(
        supportsQualitySelection: Bool,
        onOpenAudioEffects: @escaping () -> Void,
        onOpenQuality: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onOpenSkip: @escaping () -> Void,
        onOpenBookDetail: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.supportsQualitySelection = supportsQualitySelection
        self.onOpenAudioEffects = onOpenAudioEffects
        self.onOpenQuality = onOpenQuality
        self.onOpenDownloads = onOpenDownloads
        self.onOpenSkip = onOpenSkip
        self.onOpenBookDetail = onOpenBookDetail
        self.onDismiss = onDismiss
    }

    private var skipSummaryText: String {
        let cfg = playback.bookSkipConfig
        if !cfg.isEnabled { return "未开启" }
        var parts: [String] = []
        if cfg.introSeconds > 0 { parts.append("片头 \(cfg.introSeconds)s") }
        if cfg.outroSeconds > 0 { parts.append("片尾 \(cfg.outroSeconds)s") }
        return parts.isEmpty ? "未开启" : parts.joined(separator: " · ")
    }

    private var effectSummaryText: String {
        playback.dsp.isCustomEQ ? "自定义 EQ" : playback.dsp.preset.title
    }

    var body: some View {
        let hasNoBook = (playback.currentBook == nil)
        DSSheetScaffold(title: "更多播放设置", banner: banner, onDismiss: onDismiss) {
            Form {
                Section("高频听书增强") {
                    if supportsQualitySelection && !hasNoBook {
                        Button(action: onOpenQuality) {
                            HStack {
                                Label("播放音质切换", systemImage: "sparkles")
                                    .foregroundStyle(DSColors.inkPrimary)
                                Spacer()
                                Text(playback.activeStream?.displayBitrateBadge ?? playback.preferredQuality.displayName)
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.accent)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DSColors.surfaceCard)
                    }

                    Button(action: onOpenAudioEffects) {
                        HStack {
                            Label("均衡器与人声 EQ 音效", systemImage: "slider.vertical.3")
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Text(effectSummaryText)
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.accent)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)

                    Button(action: onOpenDownloads) {
                        HStack {
                            Label("章节批量离线下载", systemImage: "arrow.down.circle")
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasNoBook)
                    .listRowBackground(DSColors.surfaceCard)
                }

                Section("本书设置") {
                    Button(action: onOpenSkip) {
                        HStack {
                            Label("跳过片头片尾", systemImage: "forward.frame")
                                .foregroundStyle(DSColors.inkPrimary)
                            Spacer()
                            Text(skipSummaryText)
                                .font(DSTypography.caption)
                                .foregroundStyle(playback.bookSkipConfig.isEnabled ? DSColors.accent : DSColors.inkSecondary)
                            Image(systemName: "chevron.right")
                                .font(DSTypography.caption2)
                                .foregroundStyle(DSColors.inkSecondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasNoBook)
                    .listRowBackground(DSColors.surfaceCard)

                    HStack {
                        Label("AirPlay 无线音频输出", systemImage: "airplayaudio")
                        Spacer()
                        AirPlayRoutePickerRepresentable()
                            .frame(minWidth: 44, minHeight: 44)
                            .fixedSize()
                            .accessibilityLabel("切换 AirPlay 音频输出")
                    }
                    .listRowBackground(DSColors.surfaceCard)
                }

                Section("书籍信息") {
                    Button(action: onOpenBookDetail) {
                        Label("查看书籍详情页与简介", systemImage: "book.closed")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasNoBook)
                    .listRowBackground(DSColors.surfaceCard)

                    Button {
                        let title = playback.currentChapter?.title ?? ""
                        if !title.isEmpty {
                            UIPasteboard.general.string = title
                            banner.show("已复制当前章节标题", tone: .success)
                        }
                        onDismiss()
                    } label: {
                        Label("复制当前章节标题", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.currentChapter == nil)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
