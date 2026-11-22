import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 2：睡眠定时（1:1 复刻 v2.8：激活时顶部 +15 分钟延长钮 + 5 档时长 + 4 档按章 + 自定义 5–180 分钟 Stepper）
struct SleepTimerSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var customMinutes: Int = 25
    private let onDismiss: () -> Void
    private let minutePresets = [15, 30, 45, 60, 90]
    private let chapterPresets = [1, 2, 3, 5]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        DSSheetScaffold(title: "睡眠定时", banner: banner, onDismiss: onDismiss) {
            List {
                if playback.sleepTimer.isActive {
                    Section("当前定时状态") {
                        SleepActiveStatusRow(
                            sleepTimer: playback.sleepTimer,
                            onExtend15: { extendBy15Minutes() },
                            onCancel: {
                                DSHaptics.selection()
                                playback.sleepTimer.cancel()
                                banner.show("已取消睡眠定时", tone: .info)
                            }
                        )
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section("按时长定时（墙钟防漂移）") {
                    ForEach(minutePresets, id: \.self) { min in
                        Button {
                            DSHaptics.selection()
                            startMinutes(min)
                            banner.show("已设定 \(min) 分钟后自动暂停", tone: .success)
                            onDismiss()
                        } label: {
                            HStack {
                                Text("\(min) 分钟")
                                    .foregroundStyle(DSColors.inkPrimary)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section("按章节关闭（播完自动预定位下章片头）") {
                    ForEach(chapterPresets, id: \.self) { count in
                        let isSelected: Bool = {
                            if case .afterChapters(let rem) = playback.sleepTimer.mode {
                                return rem == count
                            }
                            return false
                        }()
                        Button {
                            DSHaptics.selection()
                            playback.sleepTimer.startAfterChapters(count)
                            banner.show("已设定播完 \(count) 章后暂停", tone: .success)
                            onDismiss()
                        } label: {
                            HStack {
                                Text(count == 1 ? "播完本章后暂停" : "再听 \(count) 章后暂停")
                                    .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkPrimary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DSColors.accent)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DSColors.surfaceCard)
                    }
                }

                Section("自定义时长（5–180 分钟）") {
                    Stepper("自定义：\(customMinutes) 分钟", value: $customMinutes, in: 5...180, step: 5)
                        .listRowBackground(DSColors.surfaceCard)
                    Button {
                        DSHaptics.selection()
                        startMinutes(customMinutes)
                        banner.show("已设定 \(customMinutes) 分钟后自动暂停", tone: .success)
                        onDismiss()
                    } label: {
                        HStack {
                            Image(systemName: "timer")
                            Text("启动 \(customMinutes) 分钟定时")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(DSColors.accent)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColors.surfaceCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func startMinutes(_ minutes: Int) {
        playback.sleepTimer.startCountdown(
            minutes: minutes,
            onFadeFactor: { playback.applySleepFade(factor: $0) },
            onFire: { playback.pause() }
        )
    }

    private func extendBy15Minutes() {
        DSHaptics.selection()
        let baseMinutes: Int
        if case .countdown = playback.sleepTimer.mode {
            baseMinutes = max(1, Int(ceil(Double(playback.sleepTimer.remainingSeconds) / 60.0)))
        } else {
            baseMinutes = 0
        }
        let target = min(180, baseMinutes + 15)
        startMinutes(target)
        banner.show("睡眠定时已延长 15 分钟", tone: .info)
    }
}

private struct SleepActiveStatusRow: View {
    let sleepTimer: SleepTimerEngine
    let onExtend15: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("正在倒计时")
                    .font(DSTypography.cardTitle)
                    .foregroundStyle(DSColors.inkSecondary)
                Text(sleepTimer.displayBadge ?? "")
                    .font(DSTypography.rowTitle.monospacedDigit())
                    .foregroundStyle(DSColors.accent)
            }
            Spacer(minLength: DSSpacing.xs)
            HStack(spacing: DSSpacing.xs) {
                Button(action: onExtend15) {
                    Text("+15 分钟")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.accent)
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(DSColors.accent.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("关闭")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(DSColors.danger.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DSSpacing.xxs)
    }
}

/// 弹窗 3：倍速调节（1:1 复刻 v2.8：-0.05 / 大号倍速 / +0.05 + 连续滑块 + 4 列网格 8 档胶囊）
struct SpeedSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettingsStore.self) private var settings
    @Environment(DSBannerCoordinator.self) private var banner
    private let onDismiss: () -> Void
    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private func applySpeed(_ raw: Double) {
        let snapped = min(3.0, max(0.5, (raw * 20.0).rounded() / 20.0))
        if abs(snapped - playback.playbackRate) > 0.001 {
            DSHaptics.selection()
        }
        playback.playbackRate = snapped
        settings.playbackRate = snapped
    }

    var body: some View {
        DSSheetScaffold(title: "播放倍速", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(spacing: DSSpacing.s5) {
                    HStack(spacing: DSSpacing.s5) {
                        Button {
                            applySpeed(playback.playbackRate - 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "minus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceCard))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.playbackRate <= 0.5)
                        .accessibilityLabel("减速 0.05 倍")

                        Text(PlayerSpeedFormatter.format(playback.playbackRate))
                            .font(DSTypography.bookTitleLarge.monospacedDigit())
                            .foregroundStyle(DSColors.accent)
                            .contentTransition(.numericText())
                            .frame(minWidth: 100)

                        Button {
                            applySpeed(playback.playbackRate + 0.05)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus")
                                Text("0.05")
                            }
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(DSColors.inkPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(DSColors.surfaceCard))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.playbackRate >= 3.0)
                        .accessibilityLabel("加速 0.05 倍")
                    }

                    Slider(
                        value: Binding(
                            get: { playback.playbackRate },
                            set: { applySpeed($0) }
                        ),
                        in: 0.5...3.0,
                        step: 0.05
                    )
                    .tint(DSColors.accent)
                    .padding(.horizontal, DSSpacing.pageHorizontal)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.xs), count: 4),
                        spacing: DSSpacing.xs
                    ) {
                        ForEach(presets, id: \.self) { rate in
                            let isSelected = abs(playback.playbackRate - rate) < 0.01
                            Button {
                                applySpeed(rate)
                            } label: {
                                Text(PlayerSpeedFormatter.format(rate))
                                    .font(DSTypography.numericCaption.weight(.semibold))
                                    .foregroundStyle(isSelected ? DSColors.onAccent : DSColors.inkPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Capsule().fill(isSelected ? DSColors.accent : DSColors.surfaceCard))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpacing.pageHorizontal)
                }
                .padding(.vertical, DSSpacing.md)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
