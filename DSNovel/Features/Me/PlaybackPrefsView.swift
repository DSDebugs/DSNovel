import SwiftUI

struct PlaybackPrefsView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    var body: some View {
        Group {
            Picker("默认倍速", selection: $settings.defaultSpeed) {
                ForEach(SpeedSheet.presets, id: \.self) { spd in
                    Text(PlayerSpeedFormatter.format(spd)).tag(spd)
                }
            }

            Picker("在线与下载音质", selection: $settings.audioQualityTier) {
                ForEach(AudioQualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .onChange(of: settings.audioQualityTier) { _, newTier in
                PlayerEngine.shared.setAudioQualityTier(newTier, reloadCurrent: false)
            }

            Picker("听书音效模式", selection: $settings.audioEffectPreset) {
                ForEach(AudioEffectPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .onChange(of: settings.audioEffectPreset) { _, newPreset in
                PlayerEngine.shared.setAudioEffectPreset(newPreset)
            }

            Toggle("睡眠定时结束前渐弱", isOn: $settings.sleepFadeOutEnabled)

            NavigationLink(value: Route.skipSettings) {
                DSSettingsRow(
                    icon: "forward.frame",
                    title: "跳过片头片尾",
                    valueText: "片头 \(settings.defaultSkipIntroSec)s · 片尾 \(settings.defaultSkipOutroSec)s"
                )
            }

            Stepper("预缓存后续章节：\(settings.precacheCount) 章", value: $settings.precacheCount, in: 0...5)

            Toggle("为每本书记住音量与倍速", isOn: $settings.rememberBookVolume)

            Picker("音频通道", selection: $settings.audioChannel) {
                ForEach(AudioChannelMode.allCases) { ch in
                    Text(ch.title).tag(ch)
                }
            }

            Picker("启动时的行为", selection: $settings.launchBehavior) {
                ForEach(LaunchBehavior.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        }
    }
}

struct SkipSettingsDetailView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    var body: some View {
        Form {
            Section("全局默认跳过时长") {
                Stepper("默认跳过片头：\(settings.defaultSkipIntroSec) 秒", value: $settings.defaultSkipIntroSec, in: 0...180, step: 5)
                Stepper("默认跳过片尾：\(settings.defaultSkipOutroSec) 秒", value: $settings.defaultSkipOutroSec, in: 0...180, step: 5)
            }
        }
        .navigationTitle("跳过片头片尾")
    }
}
