import SwiftUI

struct PlayerHeader: View {
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    private let onDismiss: () -> Void
    private let onOpenSleepSheet: () -> Void
    private let onOpenMoreSheet: () -> Void

    init(
        sleepOption: SleepTimerOption,
        sleepRemainingSec: Int,
        onDismiss: @escaping () -> Void,
        onOpenSleepSheet: @escaping () -> Void,
        onOpenMoreSheet: @escaping () -> Void
    ) {
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.onDismiss = onDismiss
        self.onOpenSleepSheet = onOpenSleepSheet
        self.onOpenMoreSheet = onOpenMoreSheet
    }

    var body: some View {
        VStack(spacing: Spacing.s2) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, Spacing.s2)

            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起播放器")

                Spacer()

                if sleepOption != .off {
                    Button(action: onOpenSleepSheet) {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.fill")
                            Text(sleepRemainingSec > 0 ? PlaybackClock.formatSeconds(Double(sleepRemainingSec)) : sleepOption.label)
                                .monospacedDigit()
                        }
                        .font(DSTypography.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(action: onOpenMoreSheet) {
                    Image(systemName: "ellipsis")
                        .font(DSTypography.rowTitle)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多选项")
            }
            .padding(.horizontal, Spacing.pageHorizontal)
        }
    }
}
