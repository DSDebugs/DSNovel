import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 5：均衡器与音效（1:1 复刻 v2.8：3 列网格预设 + 仅自定义时展开 5 段 EQ + 响度增强 + 左右平衡）
struct AudioEffectsSheet: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var selectedDetent: PresentationDetent = .fraction(0.76)
    private let onDismiss: () -> Void
    private let bandSpecs: [(idx: Int, freq: String, role: String)] = [
        (0, "100Hz", "低频"),
        (1, "300Hz", "暖度"),
        (2, "1kHz", "人声"),
        (3, "3.2kHz", "清晰"),
        (4, "8kHz", "明亮")
    ]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var boostStatusText: String {
        let db = Int(playback.dsp.volumeBoostDB.rounded())
        if db <= 0 { return "关闭" }
        if db <= 3 { return "+\(db) dB · 轻度" }
        if db <= 6 { return "+\(db) dB · 适中" }
        return "+\(db) dB · 强力"
    }

    private func presetIcon(for preset: AudioEQPreset) -> String {
        switch preset {
        case .flat: return "waveform"
        case .voiceBoost: return "mic.fill"
        case .warm: return "flame.fill"
        case .night: return "moon.stars.fill"
        case .bright: return "sparkles"
        }
    }

    var body: some View {
        let isHLSFallback = playback.dsp.isUsingNativeVolumeFallback
        DSSheetScaffold(title: "均衡器与音效", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if isHLSFallback {
                        HStack(spacing: DSSpacing.xs) {
                            Image(systemName: "info.circle.fill")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.warning)
                            Text(playback.dsp.fallbackReason ?? "当前为 HLS 流媒体，系统不支持音频 Tap，均衡器已自动禁用。")
                                .font(DSTypography.caption)
                                .foregroundStyle(DSColors.warning)
                        }
                        .padding(DSSpacing.sm)
                        .background(RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous).fill(DSColors.warning.opacity(0.12)))
                    }

                    AudioSmartRepairCard(dsp: playback.dsp, disabled: isHLSFallback)

                    presetsCard(disabled: isHLSFallback)

                    if playback.dsp.isCustomEQ {
                        customEQCard(disabled: isHLSFallback)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    loudnessAndLevelingCard(disabled: isHLSFallback)
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.vertical, DSSpacing.sm)
                .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: playback.dsp.isCustomEQ)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.76), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .onChange(of: playback.dsp.isCustomEQ) { _, isCustom in
            if isCustom { selectedDetent = .large }
        }
    }

    private func presetsCard(disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text("音色风格")
                    .font(DSTypography.cardTitle)
                Spacer()
                Text(
                    playback.dsp.isCustomEQ
                        ? "自定义调节中"
                        : (playback.dsp.smartRepairEnabled ? "与智能修音叠加" : "预设黄金频响")
                )
                    .font(DSTypography.caption2)
                    .foregroundStyle(playback.dsp.isCustomEQ ? DSColors.accent : DSColors.inkSecondary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xs), count: 3),
                spacing: DSSpacing.xs
            ) {
                ForEach(AudioEQPreset.allCases) { preset in
                    let isSelected = !playback.dsp.isCustomEQ && playback.dsp.preset == preset
                    presetTile(title: preset.title, icon: presetIcon(for: preset), isSelected: isSelected) {
                        DSHaptics.selection()
                        playback.dsp.preset = preset
                    }
                }
                presetTile(title: "自定义 EQ", icon: "slider.vertical.3", isSelected: playback.dsp.isCustomEQ) {
                    DSHaptics.selection()
                    playback.dsp.isCustomEQ = true
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func presetTile(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(DSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? DSColors.accent : .white.opacity(0.75))
                    Spacer()
                    if isSelected {
                        Circle().fill(DSColors.accent).frame(width: 6, height: 6)
                    }
                }
                Text(title)
                    .font(DSTypography.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                    .fill(isSelected ? DSColors.accent.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.input, style: .continuous)
                    .strokeBorder(isSelected ? DSColors.accent.opacity(0.65) : Color.white.opacity(0.06), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func customEQCard(disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Label("五段自定义均衡器（-12dB ~ +12dB）", systemImage: "slider.vertical.3")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.accent)
                Spacer()
                Button("频段归零") {
                    DSHaptics.selection()
                    playback.dsp.customBands = [0, 0, 0, 0, 0]
                }
                .font(DSTypography.caption2.weight(.semibold))
                .foregroundStyle(DSColors.inkSecondary)
                .buttonStyle(.plain)
            }

            ForEach(bandSpecs, id: \.idx) { spec in
                let gain = safeBandGain(at: spec.idx)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(spec.freq)
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .frame(width: 48, alignment: .leading)
                        Text(spec.role)
                            .font(DSTypography.caption2)
                            .foregroundStyle(DSColors.inkSecondary)
                        Spacer()
                        Text(String(format: "%+.1f dB", gain))
                            .font(DSTypography.numericCaption)
                            .foregroundStyle(abs(gain) > 0.1 ? DSColors.accent : DSColors.inkSecondary)
                    }
                    Slider(
                        value: Binding(
                            get: { safeBandGain(at: spec.idx) },
                            set: { val in
                                var next = playback.dsp.customBands
                                if next.count < 5 {
                                    next.append(contentsOf: repeatElement(Float(0), count: 5 - next.count))
                                }
                                next[spec.idx] = val
                                playback.dsp.customBands = next
                            }
                        ),
                        in: -12...12,
                        step: 0.5
                    )
                    .tint(DSColors.accent)
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func loudnessAndLevelingCard(disabled: Bool) -> some View {
        let boostPresets: [(label: String, db: Float)] = [("关闭", 0), ("轻度", 3), ("适中", 6), ("强力", 9)]
        let hasActiveEnhance = playback.dsp.volumeBoostDB > 0.05 || playback.dsp.dynamicLevelingEnabled
        let currentDB = Int(playback.dsp.volumeBoostDB.rounded())

        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                Text("响度与防爆音")
                    .font(DSTypography.cardTitle)
                Spacer()
                if hasActiveEnhance {
                    Button("重置") {
                        DSHaptics.selection()
                        playback.dsp.volumeBoostDB = 0
                        playback.dsp.dynamicLevelingEnabled = false
                    }
                    .font(DSTypography.caption2.weight(.semibold))
                    .foregroundStyle(DSColors.accent)
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack {
                    Text("人声响度增强")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Spacer()
                    Text(boostStatusText)
                        .font(DSTypography.numericCaption.weight(.semibold))
                        .foregroundStyle(currentDB > 0 ? DSColors.accent : DSColors.inkSecondary)
                }

                Slider(
                    value: Binding(
                        get: { playback.dsp.volumeBoostDB },
                        set: { playback.dsp.volumeBoostDB = $0.rounded() }
                    ),
                    in: 0...9,
                    step: 1
                )
                .tint(DSColors.accent)

                HStack {
                    ForEach(boostPresets, id: \.label) { item in
                        let isMatched = (item.db == 0 && currentDB == 0)
                            || (item.db == 3 && currentDB >= 1 && currentDB <= 3)
                            || (item.db == 6 && currentDB >= 4 && currentDB <= 6)
                            || (item.db == 9 && currentDB >= 7)
                        Button {
                            DSHaptics.selection()
                            playback.dsp.volumeBoostDB = item.db
                        } label: {
                            Text(item.label)
                                .font(DSTypography.caption2.weight(isMatched ? .semibold : .regular))
                                .foregroundStyle(isMatched ? DSColors.accent : DSColors.inkSecondary)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            Toggle(isOn: Binding(
                get: { playback.dsp.dynamicLevelingEnabled },
                set: { playback.dsp.dynamicLevelingEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("防爆音动态均衡")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("拉平忽大忽小，末端兜底防破音")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            .tint(DSColors.accent)
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
    }

    private func safeBandGain(at idx: Int) -> Float {
        let bands = playback.dsp.customBands
        return bands.indices.contains(idx) ? bands[idx] : 0
    }
}

/// 弹窗 6：音质切换（严格保留 v3.0 未解锁隐藏超清约束）
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
                        if let bookID = playback.currentBook?.id {
                            settings.setQuality(tier, forBookID: bookID)
                        }
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}
