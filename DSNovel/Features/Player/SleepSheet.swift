import SwiftUI

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
                    Section("当前定时") {
                        HStack {
                            Text(player.sleepRemainingSec > 0 ? PlaybackClock.formatSeconds(Double(player.sleepRemainingSec)) : player.sleepOption.label)
                                .font(DSTypography.rowTitle.monospacedDigit())
                                .foregroundStyle(Color.dsAccent)
                            Spacer()
                            Button("关闭定时") {
                                player.setSleepTimer(.off)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }

                Section("预设时长") {
                    ForEach([15, 30, 45, 60], id: \.self) { mins in
                        Button("\(mins) 分钟") {
                            player.setSleepTimer(.minutes(mins))
                            onClose()
                        }
                    }
                    Button("本章结束") {
                        player.setSleepTimer(.endOfChapter)
                        onClose()
                    }
                    Button("再听 2 章后") {
                        player.setSleepTimer(.chaptersRemaining(2))
                        onClose()
                    }
                    Button("再听 5 章后") {
                        player.setSleepTimer(.chaptersRemaining(5))
                        onClose()
                    }
                }

                Section("自定义时长（1–180 分钟）") {
                    Stepper("\(customMinutes) 分钟", value: $customMinutes, in: 1...180)
                    Button("启动自定义定时") {
                        player.setSleepTimer(.minutes(customMinutes))
                        onClose()
                    }
                }

                Section {
                    Toggle("结束前 30 秒音量渐弱", isOn: Binding(
                        get: { AppSettingsStore.shared.sleepFadeOutEnabled },
                        set: { AppSettingsStore.shared.sleepFadeOutEnabled = $0 }
                    ))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
