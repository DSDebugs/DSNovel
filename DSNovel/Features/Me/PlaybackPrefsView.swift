import SwiftUI

struct PlaybackPrefsView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    private var defaultSpeedOptions: [Double] {
        let current = settings.defaultSpeed
        var options = SpeedSheet.presets
        if let matchedIdx = options.firstIndex(where: { abs($0 - current) < 0.001 }) {
            if options[matchedIdx] != current {
                options[matchedIdx] = current
            }
        } else {
            var inserted = false
            for idx in options.indices where current < options[idx] {
                options.insert(current, at: idx)
                inserted = true
                break
            }
            if !inserted {
                options.append(current)
            }
        }
        return options
    }

    private func isPresetSpeed(_ value: Double) -> Bool {
        SpeedSheet.presets.contains { abs($0 - value) < 0.001 }
    }

    private var normalizedQualityTierBinding: Binding<AudioQualityTier> {
        Binding(
            get: { settings.audioQualityTier },
            set: { settings.audioQualityTier = $0 }
        )
    }

    var body: some View {
        Group {
            rowWithIcon("speedometer") {
                Picker("新书默认倍速", selection: $settings.defaultSpeed) {
                    ForEach(defaultSpeedOptions, id: \.self) { spd in
                        Text(
                            isPresetSpeed(spd)
                                ? PlayerSpeedFormatter.format(spd)
                                : "\(PlayerSpeedFormatter.format(spd))（自定义）"
                        )
                        .tag(spd)
                    }
                }
            }
            .listRowBackground(Color.dsSurfaceCard)

            VStack(alignment: .leading, spacing: Spacing.s1) {
                rowWithIcon("waveform.badge.magnifyingglass") {
                    Picker("在线与下载音质", selection: normalizedQualityTierBinding) {
                        ForEach(AudioQualityTier.visibleTiers) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .onChange(of: settings.audioQualityTier) { _, newTier in
                        PlayerEngine.shared.setAudioQualityTier(
                            newTier,
                            reloadCurrent: true,
                            applyToCurrentBookOnly: false
                        )
                    }
                }

                Text("仅对支持多音质的书源生效，作为新书与未单独调整书籍的默认音质；已在播放页调整过的书籍按该书所选音质播放。")
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
