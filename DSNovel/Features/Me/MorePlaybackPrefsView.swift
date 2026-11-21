import SwiftUI

struct MorePlaybackPrefsView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: Spacing.s3) {
                    Image(systemName: "waveform")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsAccent.opacity(0.10))
                        )
                        .accessibilityHidden(true)

                    Picker("音频通道", selection: $settings.audioChannel) {
                        ForEach(AudioChannelMode.allCases) { ch in
                            Text(ch.title).tag(ch)
                        }
                    }
                    .onChange(of: settings.audioChannel) { _, _ in
                        PlayerEngine.shared.syncAudioChannelFromSettings()
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(Color.dsSurfaceCard)
            } header: {
                Text("声音")
            } footer: {
                Text("\(settings.audioChannel.subtitle)。切换后即时生效。")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: Spacing.s3) {
                    Image(systemName: "moon.zzz")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsAccent.opacity(0.10))
                        )
                        .accessibilityHidden(true)

                    Toggle("睡眠定时结束前渐弱", isOn: $settings.sleepFadeOutEnabled)
                        .tint(Color.dsAccent)
                }
                .frame(minHeight: 44)
                .listRowBackground(Color.dsSurfaceCard)

                HStack(spacing: Spacing.s3) {
                    Image(systemName: "arrow.down.to.line")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsAccent.opacity(0.10))
                        )
                        .accessibilityHidden(true)

                    Stepper("预缓存后续章节：\(settings.precacheCount) 章", value: $settings.precacheCount, in: 0...5)
                }
                .frame(minHeight: 44)
                .listRowBackground(Color.dsSurfaceCard)

                HStack(spacing: Spacing.s3) {
                    Image(systemName: "speaker.wave.2")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsAccent.opacity(0.10))
                        )
                        .accessibilityHidden(true)

                    Toggle("记住每本书的音量", isOn: $settings.rememberBookVolume)
                        .tint(Color.dsAccent)
                }
                .frame(minHeight: 44)
                .listRowBackground(Color.dsSurfaceCard)
            } header: {
                Text("睡眠与缓存")
            } footer: {
                Text("开启「记住每本书的音量」后，在播放页调整单书音量增益将按书保存；每本书的倍速始终会自动记住。")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: Spacing.s3) {
                    Image(systemName: "play.circle")
                        .font(DSTypography.subtitle.weight(.semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.coverSmall, style: .continuous)
                                .fill(Color.dsAccent.opacity(0.10))
                        )
                        .accessibilityHidden(true)

                    Picker("启动时的行为", selection: $settings.launchBehavior) {
                        ForEach(LaunchBehavior.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                }
                .frame(minHeight: 44)
                .listRowBackground(Color.dsSurfaceCard)
            } header: {
                Text("启动")
            } footer: {
                Text("选择每次冷启动应用时是否自动恢复上次收听位置。")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Color.dsSurfaceGrouped)
        .contentMargins(.top, Spacing.s2, for: .scrollContent)
        .contentMargins(.bottom, Spacing.s4, for: .scrollContent)
        .navigationTitle("更多播放设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
