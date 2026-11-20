import SwiftUI

struct PlaybackPrefsView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
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

            rowWithIcon("waveform.badge.magnifyingglass") {
                Picker("在线与下载音质", selection: $settings.audioQualityTier) {
                    ForEach(AudioQualityTier.visibleTiers) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                .onChange(of: settings.audioQualityTier) { _, newTier in
                    PlayerEngine.shared.setAudioQualityTier(newTier, reloadCurrent: false)
                }
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
