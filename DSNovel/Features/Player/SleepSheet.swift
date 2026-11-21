import SwiftUI

/// 独立睡眠倒计时状态叶子视图：仅自身订阅 `player.estimatedSleepRemainingSec`，彻底隔离 1Hz 全表重绘
private struct SleepCountdownStatusRow: View {
    let player: PlayerEngine

    init(player: PlayerEngine) {
        self.player = player
    }

    var body: some View {
        let estimatedSec = player.estimatedSleepRemainingSec
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack(spacing: Spacing.s3) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.sleepOption.label)
                        .font(DSTypography.cardTitle)
                        .foregroundStyle(.secondary)
                    Text(
                        estimatedSec > 0
                            ? "预计剩余 \(PlaybackClock.formatSeconds(Double(estimatedSec)))"
                            : player.sleepOption.label
                    )
                    .font(DSTypography.rowTitle.monospacedDigit())
                    .foregroundStyle(Color.dsAccent)
                }

                Spacer(minLength: Spacing.s2)

                HStack(spacing: Spacing.s3) {
                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.extendSleepTimer(byMinutes: 15)
                        BannerCenter.shared.show("睡眠定时已延长 15 分钟", kind: .info)
                    } label: {
                        Text("+15 分钟")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.dsAccent)
                            .padding(.horizontal, Spacing.s3)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.dsAccent.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.setSleepTimer(.off)
                    } label: {
                        Text("关闭")
                            .font(DSTypography.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, Spacing.s3)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.red.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Spacing.s1)
    }
}

struct SleepSheet: View {
    let player: PlayerEngine
    @State private var customMinutes: Int = 25
    private let onClose: () -> Void

    init(player: PlayerEngine = .shared, onClose: @escaping () -> Void) {
        self.player = player
        self.onClose = onClose
    }

    var body: some View {
        DSSheetScaffold(title: "睡眠定时", onClose: onClose) {
            List {
                if player.sleepOption != .off {
                    Section("当前定时状态") {
                        SleepCountdownStatusRow(player: player)
                    }
                }

                Section("按时长定时") {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { mins in
                        let option = SleepTimerOption.minutes(mins)
                        let isSelected = (player.sleepOption == option)
                        Button {
                            DSHapticPolicy.fire(.selection)
                            player.setSleepTimer(option)
                            onClose()
                        } label: {
                            HStack {
                                Text("\(mins) 分钟")
                                    .foregroundStyle(isSelected ? Color.dsAccent : .primary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.dsAccent)
                                }
                            }
                        }
                    }
                }

                Section("按章节智能停播（按当前倍速动态折算）") {
                    sleepChapterRow(title: "播完本章后停止", option: .endOfChapter)
                    sleepChapterRow(title: "再听 2 章后停止", option: .chaptersRemaining(2))
                    sleepChapterRow(title: "再听 3 章后停止", option: .chaptersRemaining(3))
                    sleepChapterRow(title: "再听 5 章后停止", option: .chaptersRemaining(5))
                }

                Section("自定义时长（5–180 分钟）") {
                    Stepper("自定义：\(customMinutes) 分钟", value: $customMinutes, in: 5...180, step: 5)
                    Button {
                        DSHapticPolicy.fire(.selection)
                        player.setSleepTimer(.minutes(customMinutes))
                        onClose()
                    } label: {
                        HStack {
                            Image(systemName: "timer")
                            Text("启动 \(customMinutes) 分钟定时")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(Color.dsAccent)
                    }
                }

                Section("助眠护耳") {
                    Toggle("结束前 30 秒音量线性渐弱", isOn: Binding(
                        get: { AppSettingsStore.shared.sleepFadeOutEnabled },
                        set: { AppSettingsStore.shared.sleepFadeOutEnabled = $0 }
                    ))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.dsSurfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func sleepChapterRow(title: String, option: SleepTimerOption) -> some View {
        let isSelected = (player.sleepOption == option)
        Button {
            DSHapticPolicy.fire(.selection)
            player.setSleepTimer(option)
            onClose()
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(isSelected ? Color.dsAccent : .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.dsAccent)
                }
            }
        }
    }
}
