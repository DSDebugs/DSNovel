import DSCore
import DSDesignSystem
import DSDownloads
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 5：均衡器与音效（L-IOS-3：HLS 降级时自动禁用 EQ 并给出明确说明）
struct AudioEffectsSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        let isHLSFallback = playback.dsp.isUsingNativeVolumeFallback
        DSSheetScaffold(title: "均衡器与音效", banner: banner, onDismiss: onDismiss) {
            Form {
                if isHLSFallback {
                    Section {
                        Text(playback.dsp.fallbackReason ?? "当前为 HLS 流媒体，系统不支持音频 Tap，均衡器已自动禁用。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.warning)
                    }
                }

                Section("预设音效") {
                    ForEach(AudioEQPreset.allCases) { preset in
                        Button {
                            playback.dsp.preset = preset
                        } label: {
                            HStack {
                                Text(preset.title)
                                Spacer()
                                if !playback.dsp.isCustomEQ && playback.dsp.preset == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DSColors.accent)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isHLSFallback)
                    }
                }

                Section("五段均衡微调（-12dB ~ +12dB）") {
                    let labels = ["60Hz 低频", "230Hz 暖度", "910Hz 人声", "3.6kHz 清晰", "14kHz 明亮"]
                    ForEach(0..<5, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(labels[idx])
                                    .font(DSTypography.caption)
                                Spacer()
                                Text(String(format: "%+.1f dB", safeBandGain(at: idx)))
                                    .font(DSTypography.monoCaption)
                                    .foregroundStyle(DSColors.inkSecondary)
                            }
                            Slider(value: Binding(
                                get: { safeBandGain(at: idx) },
                                set: { val in
                                    var next = playback.dsp.customBands
                                    if next.count < 5 {
                                        next.append(contentsOf: repeatElement(Float(0), count: 5 - next.count))
                                    }
                                    next[idx] = val
                                    playback.dsp.customBands = next
                                }
                            ), in: -12...12, step: 0.5)
                        }
                    }
                    .disabled(isHLSFallback)

                    Button("恢复默认平直均衡") {
                        playback.dsp.preset = .flat
                        playback.dsp.stereoBalance = 0
                        playback.dsp.volumeBoostEnabled = false
                    }
                    .disabled(isHLSFallback)
                    .frame(minHeight: 44)
                }

                Section("声道与增强") {
                    HStack {
                        Text("声道平衡")
                        Slider(value: Binding(
                            get: { playback.dsp.stereoBalance },
                            set: { playback.dsp.stereoBalance = $0 }
                        ), in: -1...1)
                    }
                    .disabled(isHLSFallback)

                    Toggle("人声响度增强", isOn: Binding(
                        get: { playback.dsp.volumeBoostEnabled },
                        set: { playback.dsp.volumeBoostEnabled = $0 }
                    ))
                    .disabled(isHLSFallback)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func safeBandGain(at idx: Int) -> Float {
        let bands = playback.dsp.customBands
        return bands.indices.contains(idx) ? bands[idx] : 0
    }
}

/// 弹窗 6：音质切换
struct AudioQualitySheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "播放音质", banner: banner, onDismiss: onDismiss) {
            List {
                ForEach(AudioQualityTier.availableTiers(builtinParserUnlocked: container.canUseUltraHighQuality)) { tier in
                    Button {
                        settings.preferredQuality = tier
                        if playback.activeStream?.url.isFileURL == true {
                            playback.preferredQuality = tier
                            banner.show("已保存音质「\(tier.displayName)」，当前为离线音频，下次在线播放生效", tone: .info)
                        } else {
                            playback.switchQuality(tier)
                            banner.show("已切换音质为「\(tier.displayName)」", tone: .success)
                        }
                        onDismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tier.displayName)
                                    .font(DSTypography.headline)
                                Text(tier.badgeLabel(allowUltraHigh: container.canUseUltraHighQuality))
                                    .font(DSTypography.caption)
                                    .foregroundStyle(DSColors.inkSecondary)
                            }
                            Spacer()
                            if playback.preferredQuality == tier {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSColors.accent)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// 弹窗 7：播放器快捷下载
struct PlayerDownloadSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var isEnqueuing = false
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        let hasNoBook = (playback.currentBook == nil)
        let cannotDownload = hasNoBook || playback.chapters.isEmpty
        DSSheetScaffold(title: "下载离线音频", banner: banner, onDismiss: onDismiss) {
            List {
                if cannotDownload {
                    Section {
                        Text(hasNoBook ? "请先选择书籍后再下载离线章节。" : "当前书籍暂无章节目录，无法加入下载队列。")
                            .font(DSTypography.footnote)
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }
                Section("快捷缓存到本机") {
                    Button("下载当前章节") { enqueue(count: 1) }
                        .disabled(cannotDownload || isEnqueuing)
                        .frame(minHeight: 44)
                    Button("下载后续 10 章") { enqueue(count: 10) }
                        .disabled(cannotDownload || isEnqueuing)
                        .frame(minHeight: 44)
                    Button("下载后续 50 章") { enqueue(count: 50) }
                        .disabled(cannotDownload || isEnqueuing)
                        .frame(minHeight: 44)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func enqueue(count: Int) {
        guard !isEnqueuing, let book = playback.currentBook, !playback.chapters.isEmpty else { return }
        let start = min(max(0, playback.currentChapterIndex), playback.chapters.count - 1)
        let end = min(playback.chapters.count, start + max(1, count))
        guard start < end else { return }
        isEnqueuing = true
        let slice = Array(playback.chapters[start..<end])
        Task {
            defer { isEnqueuing = false }
            await downloads.enqueueManual(book: book, chapters: slice, quality: settings.preferredQuality)
            banner.show("已添加 \(slice.count) 章至下载队列", tone: .success)
            onDismiss()
        }
    }
}
