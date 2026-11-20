import SwiftUI

struct PlaybackPrefsView: View {
    @Bindable var settings: AppSettingsStore
    @State private var losslessAvailable = false

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    /// 设置页音质档位列表：若当前偏好已为 `.losslessHQ` 但解析器未声明无损能力，仍保留该 tag 避免 Picker 空白或改写偏好
    static func pickerTiers(losslessAvailable: Bool, currentTier: AudioQualityTier) -> [AudioQualityTier] {
        var tiers = QualityPolicy.visibleTiers(parserAvailable: losslessAvailable)
        if currentTier.normalizedForSelection == .losslessHQ && !tiers.contains(.losslessHQ) {
            tiers.append(.losslessHQ)
        }
        return tiers
    }

    private var normalizedQualityTierBinding: Binding<AudioQualityTier> {
        Binding(
            get: { settings.audioQualityTier.normalizedForSelection },
            set: { settings.audioQualityTier = $0 }
        )
    }

    var body: some View {
        Group {
            rowWithIcon("speedometer") {
                Picker("新书默认倍速", selection: $settings.defaultSpeed) {
                    ForEach(SpeedSheet.presets, id: \.self) { spd in
                        Text(PlayerSpeedFormatter.format(spd)).tag(spd)
                    }
                }
            }
            .listRowBackground(Color.dsSurfaceCard)

            VStack(alignment: .leading, spacing: Spacing.s1) {
                rowWithIcon("waveform.badge.magnifyingglass") {
                    Picker("在线与下载音质", selection: normalizedQualityTierBinding) {
                        ForEach(Self.pickerTiers(losslessAvailable: losslessAvailable, currentTier: settings.audioQualityTier)) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .onChange(of: settings.audioQualityTier) { _, newTier in
                        PlayerEngine.shared.setAudioQualityTier(newTier, reloadCurrent: true)
                    }
                }

                Text("「无损 · 最高音质」在内置解析支持时生效，其他书源自动回落至高清；切换后多码率在线流即时生效，已下载旧音质章节可在下载页按新音质重下。")
                    .font(DSTypography.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28 + Spacing.s3)
                    .padding(.bottom, Spacing.s1)
            }
            .listRowBackground(Color.dsSurfaceCard)

            rowWithIcon("slider.vertical.3") {
                Picker("听书音效模式", selection: $settings.audioEffectPreset) {
                    ForEach(AudioEffectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: settings.audioEffectPreset) { _, newPreset in
                    PlayerEngine.shared.setAudioEffectPreset(newPreset)
                }
            }
            .listRowBackground(Color.dsSurfaceCard)

            NavigationLink(value: Route.playbackMore) {
                DSSettingsRow(
                    icon: "ellipsis.circle",
                    title: "更多播放设置",
                    style: .value
                )
            }
            .listRowBackground(Color.dsSurfaceCard)
        }
        .task {
            let parsers = await BuiltinParserRuntime.shared.installedParsers()
            var declaredQualities = Set<String>()
            for parser in parsers {
                declaredQualities.formUnion(parser.meta.qualities)
            }
            losslessAvailable = QualityPolicy.parserDeclaresLossless(declaredQualities)
        }
    }

    private func rowWithIcon<Content: View>(_ icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: icon)
                .font(DSTypography.subtitle.weight(.semibold))
                .foregroundStyle(Color.dsAccent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                        .fill(Color.dsAccent.opacity(0.10))
                )
                .accessibilityHidden(true)

            content()
        }
        .frame(minHeight: 44)
    }
}
