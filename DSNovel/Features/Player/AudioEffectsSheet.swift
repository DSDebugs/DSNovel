import SwiftUI
import AVKit

struct AudioEffectsSheet: View {
    @Bindable var player: PlayerEngine
    private let onClose: () -> Void

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    private var routeSnapshot: AudioRouteSnapshot {
        AudioRouteSnapshot.current()
    }

    private var isBoosted: Bool {
        player.bookVolume > 1.01 || player.audioBoostDB > 0.1
    }

    private var balanceText: String {
        if abs(player.audioBalance) < 0.03 {
            return "居中"
        } else if player.audioBalance < 0 {
            return String(format: "左偏 %.0f%%", abs(player.audioBalance) * 100)
        } else {
            return String(format: "右偏 %.0f%%", player.audioBalance * 100)
        }
    }

    var body: some View {
        DSSheetScaffold(title: "音质与音效", onClose: onClose) {
            List {
                Section("当前输出设备与路由") {
                    HStack(spacing: Spacing.s3) {
                        Image(systemName: routeSnapshot.iconName)
                            .font(.title3)
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(routeSnapshot.portName)
                                .font(DSTypography.rowTitle)
                            Text(
                                player.isPlayingLocalFile
                                    ? "正在播放本地离线文件 · 原生 5 段 EQ 与响度增强已就绪"
                                    : "正在流式播放（\(player.streamStatusBadgeText)）· 人声增强通道与响度补偿实时生效"
                            )
                            .font(DSTypography.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        AirPlayRoutePickerRepresentable()
                            .frame(width: 36, height: 36)
                    }
                }

                Section("在线播放与下载音质档位") {
                    ForEach(AudioQualityTier.allCases) { tier in
                        let isSelected = (player.audioQualityTier == tier)
                        Button {
                            DSHapticPolicy.fire(.selection)
                            player.setAudioQualityTier(tier, reloadCurrent: false)
                        } label: {
                            HStack(spacing: Spacing.s3) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: Spacing.s2) {
                                        Text(tier.title)
                                            .font(DSTypography.rowTitle)
                                            .foregroundStyle(isSelected ? Color.dsAccent : .primary)
                                        Text(tier.badgeText)
                                            .font(DSTypography.caption2.weight(.semibold))
                                            .foregroundStyle(isSelected ? Color.dsOnAccent : Color.dsAccent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(isSelected ? Color.dsAccent : Color.dsAccent.opacity(0.15))
                                            )
                                    }
                                    Text(tier.subtitle)
                                        .font(DSTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.dsAccent)
                                }
                            }
                        }
                    }

                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.setAudioQualityTier(player.audioQualityTier, reloadCurrent: true)
                        BannerCenter.shared.show("正在以「\(player.audioQualityTier.title)」重载当前章节", kind: .info)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("立即以所选音质重新加载本章")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(Color.dsAccent)
                    }
                }

                Section("听书专属音效模式") {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: Spacing.s2), GridItem(.flexible(), spacing: Spacing.s2)],
                        spacing: Spacing.s2
                    ) {
                        ForEach(AudioEffectPreset.allCases) { preset in
                            let isSelected = (player.audioEffectPreset == preset)
                            Button {
                                DSHapticPolicy.fire(.selection)
                                player.setAudioEffectPreset(preset)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: preset.iconName)
                                            .foregroundStyle(isSelected ? Color.dsAccent : .secondary)
                                        Spacer()
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(DSTypography.caption)
                                                .foregroundStyle(Color.dsAccent)
                                        }
                                    }
                                    Text(preset.title)
                                        .font(DSTypography.cardTitle)
                                        .foregroundStyle(isSelected ? Color.dsAccent : .primary)
                                    Text(preset.subtitle)
                                        .font(DSTypography.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(Spacing.s3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                        .fill(isSelected ? Color.dsAccent.opacity(0.15) : Color.dsSurfaceGrouped)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                        .strokeBorder(isSelected ? Color.dsAccent : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, Spacing.s1)
                }

                Section("人声响度增强（最高 200% / +12dB）与声道平衡") {
                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        HStack {
                            Text("本书音量增益")
                                .font(DSTypography.body)
                            Spacer()
                            Text("\(Int((player.bookVolume * 100.0).rounded()))%")
                                .font(DSTypography.numericFootnote.weight(.semibold))
                                .foregroundStyle(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
                        }
                        Slider(value: $player.bookVolume, in: 0.0...2.0, step: 0.05)
                            .tint(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
                            .onChange(of: player.bookVolume) { _, _ in
                                player.saveBookAudioSettings()
                            }
                    }

                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        HStack {
                            Text("额外人声推力（AVAudioMix）")
                                .font(DSTypography.body)
                            Spacer()
                            Text(String(format: "+%.1f dB", player.audioBoostDB))
                                .font(DSTypography.numericFootnote.weight(.semibold))
                                .foregroundStyle(player.audioBoostDB > 0.1 ? .orange : .secondary)
                        }
                        Slider(value: $player.audioBoostDB, in: 0.0...12.0, step: 0.5)
                            .tint(player.audioBoostDB > 0.1 ? .orange : Color.dsAccent)
                    }

                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        HStack {
                            Text("左右声道平衡")
                                .font(DSTypography.body)
                            Spacer()
                            Text(balanceText)
                                .font(DSTypography.numericFootnote)
                                .foregroundStyle(abs(player.audioBalance) > 0.03 ? Color.dsAccent : .secondary)
                        }
                        Slider(value: $player.audioBalance, in: -1.0...1.0, step: 0.05)
                            .tint(Color.dsAccent)
                    }

                    if isBoosted {
                        HStack(spacing: Spacing.s2) {
                            Image(systemName: "ear.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                            Text("已开启超过 100% 的响度增强，适合低音量录制音源；佩戴耳机时请注意护耳。")
                                .font(DSTypography.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("五段人声均衡器（-12dB ~ +12dB）") {
                    if !player.isPlayingLocalFile {
                        HStack(spacing: Spacing.s2) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.dsAccent)
                            Text("当前为在线流式播放：已自动启用人声增强（系统通道）与频段响度补偿；下载离线章节后将激活完整 5 段硬件滤波器。")
                                .font(DSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let activeBands = player.activeEQBandsDb
                    ForEach(EqualizerBandSpec.standardFiveBands) { spec in
                        let val = spec.index < activeBands.count ? activeBands[spec.index] : 0.0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(spec.label) · \(spec.role)")
                                    .font(DSTypography.caption)
                                Spacer()
                                Text(String(format: "%+.1f dB", val))
                                    .font(DSTypography.numericCaption)
                                    .foregroundStyle(abs(val) > 0.1 ? Color.dsAccent : .secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { val },
                                    set: { newGain in
                                        player.updateCustomEQBand(index: spec.index, gainDb: newGain)
                                    }
                                ),
                                in: -12.0...12.0,
                                step: 0.5
                            )
                            .tint(Color.dsAccent)
                        }
                    }

                    Button("重置均衡器、声道平衡与增益为默认") {
                        DSHapticPolicy.fire(.selection)
                        player.audioBalance = 0.0
                        player.resetEQToOriginal()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
}
