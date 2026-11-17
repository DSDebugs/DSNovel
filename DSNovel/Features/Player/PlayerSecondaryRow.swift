import SwiftUI

struct PlayerSecondaryRow: View {
    let speed: Double
    let sleepOption: SleepTimerOption
    private let onOpenSpeed: () -> Void
    private let onOpenSleep: () -> Void
    private let onOpenChapters: () -> Void
    private let onOpenMore: () -> Void

    init(
        speed: Double,
        sleepOption: SleepTimerOption,
        onOpenSpeed: @escaping () -> Void,
        onOpenSleep: @escaping () -> Void,
        onOpenChapters: @escaping () -> Void,
        onOpenMore: @escaping () -> Void
    ) {
        self.speed = speed
        self.sleepOption = sleepOption
        self.onOpenSpeed = onOpenSpeed
        self.onOpenSleep = onOpenSleep
        self.onOpenChapters = onOpenChapters
        self.onOpenMore = onOpenMore
    }

    var body: some View {
        HStack(spacing: Spacing.s3) {
            secondaryButton(
                icon: "speedometer",
                label: String(format: "%.2gx", speed),
                action: onOpenSpeed
            )
            secondaryButton(
                icon: sleepOption == .off ? "moon" : "moon.fill",
                label: sleepOption == .off ? "定时" : sleepOption.label,
                action: onOpenSleep
            )
            secondaryButton(
                icon: "list.bullet",
                label: "目录",
                action: onOpenChapters
            )
            secondaryButton(
                icon: "ellipsis.circle",
                label: "更多",
                action: onOpenMore
            )
        }
        .padding(.horizontal, Spacing.pageHorizontal)
    }

    private func secondaryButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(DSTypography.body.weight(.semibold))
                Text(label)
                    .font(DSTypography.numericCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.s3)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}
