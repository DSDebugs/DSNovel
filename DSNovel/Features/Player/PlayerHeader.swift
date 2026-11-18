import SwiftUI

enum PlayerCenterPageMode: Int, CaseIterable {
    case cover = 0
    case subtitle = 1

    var title: String {
        switch self {
        case .cover: return "封面"
        case .subtitle: return "文稿"
        }
    }
}

struct PlayerHeader: View {
    @Binding var pageMode: PlayerCenterPageMode
    let sleepOption: SleepTimerOption
    let sleepRemainingSec: Int
    private let onDismiss: () -> Void
    private let onOpenSleepSheet: () -> Void
    private let onShare: () -> Void
    private let onOpenMoreSheet: () -> Void

    init(
        pageMode: Binding<PlayerCenterPageMode> = .constant(.subtitle),
        sleepOption: SleepTimerOption,
        sleepRemainingSec: Int,
        onDismiss: @escaping () -> Void,
        onOpenSleepSheet: @escaping () -> Void,
        onShare: @escaping () -> Void = {},
        onOpenMoreSheet: @escaping () -> Void
    ) {
        self._pageMode = pageMode
        self.sleepOption = sleepOption
        self.sleepRemainingSec = sleepRemainingSec
        self.onDismiss = onDismiss
        self.onOpenSleepSheet = onOpenSleepSheet
        self.onShare = onShare
        self.onOpenMoreSheet = onOpenMoreSheet
    }

    var body: some View {
        VStack(spacing: Spacing.s1) {
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

                HStack(spacing: Spacing.s3) {
                    ForEach(PlayerCenterPageMode.allCases, id: \.rawValue) { mode in
                        let isSelected = (pageMode == mode)
                        Button {
                            DSHapticPolicy.fire(.selection)
                            withAnimation(Motion.snappy) {
                                pageMode = mode
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.white.opacity(0.35))
                                    .frame(width: 6, height: 6)
                                Text(mode.title)
                                    .font(DSTypography.cardTitle.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    if sleepOption != .off {
                        Button(action: onOpenSleepSheet) {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.fill")
                                Text(sleepRemainingSec > 0 ? PlaybackClock.formatSeconds(Double(sleepRemainingSec)) : sleepOption.label)
                                    .monospacedDigit()
                            }
                            .font(DSTypography.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.s2)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(DSTypography.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分享当前章节")

                    Button(action: onOpenMoreSheet) {
                        Image(systemName: "ellipsis")
                            .font(DSTypography.rowTitle)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多选项")
                }
            }
            .padding(.horizontal, Spacing.pageHorizontal)
        }
    }
}
