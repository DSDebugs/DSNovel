import DSDesignSystem
import DSPlayback
import SwiftUI

/// 睡眠定时底部「睡前贴心选项」卡片（拆分自 SleepTimerSheet.swift 严守 384 行门禁，集成渐弱、回退、夜间自动定时与摇一摇延时）
struct SleepTimerOptionsCard: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var showNightScheduleConfig = false

    private let durationChoices = [15, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Label("睡前贴心选项", systemImage: "moon.zzz.fill")
                .font(DSTypography.cardTitle)

            Toggle(isOn: Binding(
                get: { playback.sleepTimer.fadeOutLastSeconds > 0 },
                set: { playback.sleepTimer.fadeOutLastSeconds = $0 ? 15 : 0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("结束前渐弱暂停")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("最后 15 秒平滑淡出，温柔入睡不突兀")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            .tint(DSColors.accent)

            Divider().overlay(Color.white.opacity(0.08))

            Toggle(isOn: Binding(
                get: { playback.sleepTimer.autoRewindOnSleepSeconds > 0 },
                set: { playback.sleepTimer.autoRewindOnSleepSeconds = $0 ? 30 : 0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("暂停后自动回退 30 秒")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("次日续听无缝衔接上次清醒处")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            .tint(DSColors.accent)

            Divider().overlay(Color.white.opacity(0.08))

            Toggle(isOn: Binding(
                get: { playback.sleepTimer.nightAutoSleepEnabled },
                set: { playback.sleepTimer.nightAutoSleepEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("夜间自动定时")
                            .font(DSTypography.subheadline)
                            .foregroundStyle(DSColors.inkPrimary)
                        Button {
                            showNightScheduleConfig.toggle()
                        } label: {
                            Text(nightWindowSummary)
                                .font(DSTypography.caption2.monospacedDigit())
                                .foregroundStyle(DSColors.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DSColors.accent.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("深夜时段起播自动开启睡眠倒计时")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            .tint(DSColors.accent)

            if showNightScheduleConfig {
                nightSchedulePickerRow
            }

            Divider().overlay(Color.white.opacity(0.08))

            Toggle(isOn: Binding(
                get: { playback.sleepTimer.shakeToExtendEnabled },
                set: { playback.sleepTimer.shakeToExtendEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最后 2 分钟摇一摇延时")
                        .font(DSTypography.subheadline)
                        .foregroundStyle(DSColors.inkPrimary)
                    Text("倒计时临近结束摇晃手机续期 15 分钟并轻震反馈")
                        .font(DSTypography.caption2)
                        .foregroundStyle(DSColors.inkSecondary)
                }
            }
            .tint(DSColors.accent)
        }
        .padding(DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(DSColors.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                )
        )
    }

    private var nightWindowSummary: String {
        let s = String(format: "%02d:00", playback.sleepTimer.nightAutoStartHour)
        let e = String(format: "%02d:00", playback.sleepTimer.nightAutoEndHour)
        return "\(s)–\(e) · \(playback.sleepTimer.nightAutoDurationMinutes)分"
    }

    private var nightSchedulePickerRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.xs) {
                Text("自动定时时长")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.inkSecondary)
                Spacer()
                ForEach(durationChoices, id: \.self) { mins in
                    let selected = playback.sleepTimer.nightAutoDurationMinutes == mins
                    Button {
                        DSHaptics.selection()
                        playback.sleepTimer.nightAutoDurationMinutes = mins
                    } label: {
                        Text("\(mins)分")
                            .font(DSTypography.caption2.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? DSColors.onAccent : DSColors.inkPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? DSColors.accent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }
}
