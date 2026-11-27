import DSCore
import DSDesignSystem
import DSPlayback
import DSStorage
import SwiftUI

/// 弹窗 2：睡眠定时（深色卡片 + 3×2 时长网格 + 单行按章胶囊 + 渐弱/回退睡前选项，一屏直达）
struct SleepTimerSheet: View {
    @Environment(\.dsEffectiveReduceMotion) private var reduceMotion
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DSBannerCoordinator.self) private var banner
    @State private var showCustomSlider = false
    @State private var customMinutes: Int = 25
    private let onDismiss: () -> Void
    private let minutePresets = [15, 30, 45, 60, 90]
    private let chapterPresets = [1, 2, 3, 5]

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs),
            GridItem(.flexible(), spacing: DSSpacing.xs)
        ]
    }

    var body: some View {
        DSSheetScaffold(title: "睡眠定时", banner: banner, onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if playback.sleepTimer.isActive {
                        activeStatusCard
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    durationGridCard
                    chapterPillsCard
                    sleepOptionsCard
                }
                .padding(.horizontal, DSSpacing.pageHorizontal)
                .padding(.vertical, DSSpacing.sm)
                .animation(DSMotion.resolved(DSMotion.snappy, reduceMotion: reduceMotion), value: playback.sleepTimer.isActive)
            }
            .background(DSColors.surfaceGrouped)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onAppear {
            customMinutes = playback.sleepTimer.lastCustomMinutes
        }
    }

    private var activeStatusCard: some View {
        let isChapterMode: Bool = {
            if case .afterChapters = playback.sleepTimer.mode { return true }
            return false
        }()

        return VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isChapterMode ? "按章节定时中" : "睡眠倒计时")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.inkSecondary)
                    Text(playback.sleepTimer.displayBadge ?? "")
                        .font(DSTypography.title.monospacedDigit())
                        .foregroundStyle(DSColors.accent)
                    if let endDate = playback.sleepTimer.estimatedEndDate {
                        Text("预计 \(Self.formatClockTime(endDate)) 自动暂停")
                            .font(DSTypography.caption2.monospacedDigit())
                            .foregroundStyle(DSColors.inkSecondary)
                    }
                }
                Spacer()
                Button {
                    DSHaptics.selection()
                    playback.sleepTimer.cancel()
                    banner.show("已关闭睡眠定时", tone: .info)
                } label: {
                    Text("关闭")
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(DSColors.danger)
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 34)
                        .background(Capsule().fill(DSColors.danger.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: DSSpacing.xs) {
                if isChapterMode {
                    quickExtendButton("+1 章") {
                        DSHaptics.selection()
                        playback.sleepTimer.extendChapters(by: 1)
                        banner.show("已延长 1 章", tone: .info)
                    }
                } else {
                    quickExtendButton("+5 分钟") { extendBy(minutes: 5) }
                    quickExtendButton("+15 分钟") { extendBy(minutes: 15) }
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
    }

    private var durationGridCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Label("按时长暂停", systemImage: "timer")
                    .font(DSTypography.cardTitle)
                Spacer()
                Text("预计 \(Self.formatClockTime(Date().addingTimeInterval(TimeInterval(customMinutes * 60)))) 停")
                    .font(DSTypography.caption2.monospacedDigit())
                    .foregroundStyle(DSColors.inkSecondary)
                    .opacity(showCustomSlider ? 1 : 0)
            }

            LazyVGrid(columns: gridColumns, spacing: DSSpacing.xs) {
                ForEach(minutePresets, id: \.self) { min in
                    Button {
                        DSHaptics.selection()
                        startMinutes(min)
                        banner.show("已设定 \(min) 分钟后暂停", tone: .success)
                        onDismiss()
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(min) 分钟")
                                .font(DSTypography.subheadline.weight(.medium))
                                .foregroundStyle(DSColors.inkPrimary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(tileBackground(isSelected: false))
                    }
                    .buttonStyle(.dsCard)
                }

                Button {
                    DSHaptics.selection()
                    DSMotion.withResolved(DSMotion.snappy, reduceMotion: reduceMotion) {
                        showCustomSlider.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(DSTypography.caption2)
                        Text("自定义")
                            .font(DSTypography.subheadline.weight(.medium))
                    }
                    .foregroundStyle(showCustomSlider ? DSColors.accent : DSColors.inkPrimary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(tileBackground(isSelected: showCustomSlider))
                }
                .buttonStyle(.dsCard)
            }

            if showCustomSlider {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    HStack {
                        Text("自定义时长")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.inkSecondary)
                        Spacer()
                        Text("\(customMinutes) 分钟")
                            .font(DSTypography.numericCaption.weight(.semibold))
                            .foregroundStyle(DSColors.accent)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(customMinutes) },
                            set: { customMinutes = Int(($0 / 5.0).rounded()) * 5 }
                        ),
                        in: 5...180,
                        step: 5
                    )
                    .tint(DSColors.accent)

                    Button {
                        DSHaptics.selection()
                        playback.sleepTimer.lastCustomMinutes = customMinutes
                        startMinutes(customMinutes)
                        banner.show("已设定 \(customMinutes) 分钟后暂停", tone: .success)
                        onDismiss()
                    } label: {
                        Text("启动 \(customMinutes) 分钟定时")
                            .font(DSTypography.subheadline.weight(.semibold))
                            .foregroundStyle(DSColors.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Capsule().fill(DSColors.accent))
                    }
                    .buttonStyle(.dsCard)
                }
                .padding(.top, DSSpacing.xxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
    }

    private var chapterPillsCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Label("按章节暂停", systemImage: "book.closed")
                    .font(DSTypography.cardTitle)
                Spacer()
                Text("播完停在下一章开头")
                    .font(DSTypography.caption2)
                    .foregroundStyle(DSColors.inkSecondary)
            }

            HStack(spacing: DSSpacing.xs) {
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
                        banner.show(count == 1 ? "已设定播完本章后暂停" : "已设定播完 \(count) 章后暂停", tone: .success)
                        onDismiss()
                    } label: {
                        Text(count == 1 ? "播完本章" : "\(count) 章")
                            .font(DSTypography.caption.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? DSColors.accent : DSColors.inkPrimary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(tileBackground(isSelected: isSelected))
                    }
                    .buttonStyle(.dsCard)
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
    }

    private var sleepOptionsCard: some View {
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
        }
        .padding(DSSpacing.sm)
        .background(cardBackground)
    }

    private func quickExtendButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSTypography.caption.weight(.semibold))
                .foregroundStyle(DSColors.accent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule().fill(DSColors.accent.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
            .fill(DSColors.surfaceCard)
            .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
            .fill(isSelected ? DSColors.accent.opacity(0.16) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .strokeBorder(isSelected ? DSColors.accent.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 0.8)
            )
    }

    private func startMinutes(_ minutes: Int) {
        playback.sleepTimer.startCountdown(
            minutes: minutes,
            onFadeFactor: { playback.applySleepFade(factor: $0) },
            onFire: { playback.handleSleepTimerFired() }
        )
    }

    private func extendBy(minutes: Int) {
        DSHaptics.selection()
        playback.sleepTimer.extendMinutes(
            by: minutes,
            onFadeFactor: { playback.applySleepFade(factor: $0) },
            onFire: { playback.handleSleepTimerFired() }
        )
        banner.show("睡眠定时已延长 \(minutes) 分钟", tone: .info)
    }

    private static func formatClockTime(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
}
