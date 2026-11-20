import SwiftUI
import AVFoundation
import AVKit

/// 重新设计的高定卡片式「音质与音效」面板（已按实测反馈调整）：
/// 1. 在线播放与下载音质：点击任意档位立即切换并以所选音质重新加载当前章节，去除多余的重载按钮；
/// 2. 听书专属音效：除「自定义 EQ」外其余 5 项均为固定黄金预设（不可修改且隐藏 EQ 调节项），仅点击「自定义 EQ」后才平滑展开五段均衡器精调面板；
/// 3. 全局采用精致深色卡片式分区排版。
struct AudioEffectsSheet: View {
    @Bindable var player: PlayerEngine
    @Environment(\.dsReduceMotion) private var reduceMotion
    @State private var routeSnapshot: AudioRouteSnapshot = AudioRouteSnapshot.current()
    private let onClose: () -> Void

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    private var isBoosted: Bool {
        player.bookVolume > 1.01 || player.audioBoostDB > 0.1
    }

    private var balanceText: String {
        if abs(player.audioBalance) < 0.03 {
            return "声道居中"
        } else if player.audioBalance < 0 {
            return String(format: "左偏 %.0f%%", abs(player.audioBalance) * 100)
        } else {
            return String(format: "右偏 %.0f%%", player.audioBalance * 100)
        }
    }

    var body: some View {
        DSSheetScaffold(title: "音质与音效", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    if !player.isAudioTapSupportedForCurrentItem {
                        tapUnsupportedBanner
                    }
                    routeStatusCard
                    qualityTierCard
                    effectPresetsCard
                    if player.audioEffectPreset == .custom {
                        customEqualizerCard
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    loudnessAndBalanceCard
                }
                .padding(.horizontal, Spacing.pageHorizontal)
                .padding(.vertical, Spacing.s3)
                .dsAnimation(Motion.snappy, value: player.audioEffectPreset)
            }
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            routeSnapshot = AudioRouteSnapshot.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            routeSnapshot = AudioRouteSnapshot.current()
        }
    }

    private var tapUnsupportedBanner: some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: "info.circle.fill")
                .font(DSTypography.caption)
                .foregroundStyle(.orange)
            Text("当前流格式不支持 EQ 与声道平衡")
                .font(DSTypography.caption)
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s2)
        .background(
            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.6)
        )
    }

    // MARK: - 1. 顶部输出设备与路由状态卡

    private var routeStatusCard: some View {
        HStack(spacing: Spacing.s3) {
            ZStack {
                Circle()
                    .fill(Color.dsAccent.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: routeSnapshot.iconName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.s2) {
                    Text(routeSnapshot.portName)
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(.primary)
                    Text(player.streamStatusBadgeText)
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.dsAccent.opacity(0.16)))
                }
                Text(routeStatusSubtitle)
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            AirPlayRoutePickerRepresentable()
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .padding(Spacing.s3)
        .background(cardBackground)
    }

    // MARK: - 2. 在线播放与下载音质档位（点击立即重载本章）

    private var routeStatusSubtitle: String {
        switch player.currentAudioQualitySupportMode {
        case .localOffline:
            return "当前为本地离线音频 · 硬件级人声增强与增益实时生效"
        case .multiBitrate:
            return "当前音源支持多码率 · 切换音质将立即重载当前章节"
        case .fixedSingleBitrate:
            return "当前音源为固定单码率 · 硬件级人声增强与缓冲策略实时生效"
        }
    }

    private var qualityTierHintText: String {
        switch player.currentAudioQualitySupportMode {
        case .multiBitrate:
            return "支持多码率 · 点击即刻重载"
        case .fixedSingleBitrate:
            return "固定码率 · 仅调节缓冲"
        case .localOffline:
            return "本地离线 · 仅更新偏好"
        }
    }

    /// 严格按当前章节已走内置解析且解析器声明 lossless 能力时才显示「无损 · 最高音质」
    private var tierOptions: [AudioQualityTier] {
        let losslessAvailable = player.currentChapterHasBuiltinParser && player.currentChapterParserDeclaresLossless
        return QualityPolicy.visibleTiers(parserAvailable: losslessAvailable)
    }

    private var qualityTierCard: some View {
        let mode = player.currentAudioQualitySupportMode
        return VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Label("在线播放与下载音质", systemImage: "waveform.badge.magnifyingglass")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(qualityTierHintText)
                    .font(DSTypography.caption2)
                    .foregroundStyle(mode == .multiBitrate ? Color.dsAccent : .secondary)
            }

            if mode == .fixedSingleBitrate {
                Text("当前书源仅提供单一固定码率，切换档位将无损更新抗卡顿缓冲时长与全局偏好；如需优化听感可搭配下方「人声清澈」或「降噪增强」音效。")
                    .font(DSTypography.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Spacing.s2) {
                ForEach(tierOptions) { tier in
                    let isSelected = (player.audioQualityTier.normalizedForSelection == tier)
                    Button {
                        guard player.audioQualityTier.normalizedForSelection != tier else { return }
                        DSHapticPolicy.fire(.selection)
                        let shouldReload = (mode == .multiBitrate)
                        player.setAudioQualityTier(tier, reloadCurrent: shouldReload)
                        let msg: String = {
                            switch mode {
                            case .multiBitrate:
                                return "已切换至「\(tier.title)」音质并重新加载本章"
                            case .fixedSingleBitrate:
                                return "当前音源为固定码率，已更新缓冲策略与全局音质偏好"
                            case .localOffline:
                                return "已更新后续在线播放与下载音质偏好为「\(tier.title)」"
                            }
                        }()
                        BannerCenter.shared.show(
                            msg,
                            kind: .success,
                            bypassDeduplication: true
                        )
                    } label: {
                        HStack(spacing: Spacing.s3) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.dsAccent : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Spacing.s2) {
                                    Text(tier.title)
                                        .font(DSTypography.body.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.dsAccent : .primary)

                                    Text(tier.badgeText)
                                        .font(DSTypography.caption2.weight(.semibold))
                                        .foregroundStyle(isSelected ? Color.dsOnAccent : Color.dsAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            Capsule().fill(isSelected ? Color.dsAccent : Color.dsAccent.opacity(0.14))
                                        )
                                }
                                Text(tier.subtitle)
                                    .font(DSTypography.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                .fill(isSelected ? Color.dsAccent.opacity(0.12) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.dsAccent.opacity(0.55) : Color.white.opacity(0.06),
                                    lineWidth: 0.8
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Spacing.s3)
        .background(cardBackground)
    }

    // MARK: - 3. 听书专属音效矩阵（非自定义预设固定默认值，点击自定义 EQ 才展开调节项）

    private var effectPresetsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Label("听书专属音效", systemImage: "sparkles.tv")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(player.audioEffectPreset == .custom ? "自定义调节中" : "预设黄金频响")
                    .font(DSTypography.caption2)
                    .foregroundStyle(player.audioEffectPreset == .custom ? Color.dsAccent : .secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.s2),
                    GridItem(.flexible(), spacing: Spacing.s2),
                    GridItem(.flexible(), spacing: Spacing.s2)
                ],
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
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.dsAccent : .white.opacity(0.75))
                                Spacer()
                                if isSelected {
                                    Circle()
                                        .fill(Color.dsAccent)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            Text(preset.title)
                                .font(DSTypography.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.dsAccent : .primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                .fill(isSelected ? Color.dsAccent.opacity(0.16) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.dsAccent.opacity(0.65) : Color.white.opacity(0.06),
                                    lineWidth: 0.8
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 当前选中预设的说明与只读频响指示
            HStack(spacing: Spacing.s2) {
                Image(systemName: player.audioEffectPreset.iconName)
                    .font(DSTypography.caption)
                    .foregroundStyle(Color.dsAccent)
                Text(player.audioEffectPreset.subtitle)
                    .font(DSTypography.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.s2)
            .padding(.top, 2)
        }
        .padding(Spacing.s3)
        .background(cardBackground)
    }

    // MARK: - 4. 条件展开：五段自定义人声均衡器（仅当选中 .custom 时显示）

    private var customEqualizerCard: some View {
        let activeBands = player.customEQBandsDb
        return VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Label("五段自定义均衡器（-12dB ~ +12dB）", systemImage: "slider.vertical.3")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(Color.dsAccent)
                Spacer()
                Button {
                    DSHapticPolicy.fire(.selection)
                    player.updateCustomEQBands([0.0, 0.0, 0.0, 0.0, 0.0])
                } label: {
                    Text("频段归零")
                        .font(DSTypography.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.s2)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            ForEach(EqualizerBandSpec.standardFiveBands) { spec in
                let val = spec.index < activeBands.count ? activeBands[spec.index] : 0.0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(spec.label)
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, alignment: .leading)
                        Text(spec.role)
                            .font(DSTypography.caption2)
                            .foregroundStyle(.secondary)
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
        }
        .padding(Spacing.s3)
        .background(cardBackground)
    }

    // MARK: - 5. 人声响度增强与左右声道平衡卡

    private var loudnessAndBalanceCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Label("人声响度增益与声道平衡", systemImage: "speaker.wave.3.fill")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(.primary)
                Spacer()
                if isBoosted || abs(player.audioBalance) > 0.03 {
                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.bookVolume = 1.0
                        player.audioBoostDB = 0.0
                        player.audioBalance = 0.0
                        player.saveBookAudioSettings()
                    } label: {
                        Text("恢复默认")
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("本书音量（支持最高 200% 增强）")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((player.bookVolume * 100.0).rounded()))%")
                        .font(DSTypography.numericCaption.weight(.semibold))
                        .foregroundStyle(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
                }
                Slider(
                    value: $player.bookVolume,
                    in: 0.0...2.0,
                    step: 0.05,
                    onEditingChanged: { editing in
                        if !editing {
                            player.saveBookAudioSettings()
                        }
                    }
                )
                .tint(player.bookVolume > 1.01 ? .orange : Color.dsAccent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("额外人声推力（AVAudioMix 增益）")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "+%.1f dB", player.audioBoostDB))
                        .font(DSTypography.numericCaption.weight(.semibold))
                        .foregroundStyle(player.audioBoostDB > 0.1 ? .orange : .secondary)
                }
                Slider(value: $player.audioBoostDB, in: 0.0...12.0, step: 0.5)
                    .tint(player.audioBoostDB > 0.1 ? .orange : Color.dsAccent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("左右声道平衡")
                        .font(DSTypography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(balanceText)
                        .font(DSTypography.numericCaption)
                        .foregroundStyle(abs(player.audioBalance) > 0.03 ? Color.dsAccent : .secondary)
                }
                Slider(value: $player.audioBalance, in: -1.0...1.0, step: 0.05)
                    .tint(Color.dsAccent)
            }

            if isBoosted {
                HStack(spacing: Spacing.s2) {
                    Image(systemName: "ear.trianglebadge.exclamationmark")
                        .font(DSTypography.caption)
                        .foregroundStyle(.orange)
                    Text("当前已开启超过 100% 的人声响度增强，适合低电平有声书源；佩戴耳机时请注意适度调节。")
                        .font(DSTypography.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }
        }
        .padding(Spacing.s3)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.dsSurfaceCard)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
            )
    }
}
